#!/bin/bash
# U2 — PP-sharded runner for a single experiment.
#
# Given a base *_htsim experiment directory and a workload directory, this:
#   1. splits the workload along PP into N shards (shard_workload_pp.py)
#   2. builds per-shard experiment dirs (make_pp_shard_exp.sh)
#   3. launches N AstraSim_HTSim processes in parallel
#   4. waits for all, then reports combined max_cycle = max(shard_cycle)
#
# The approximation: cross-PP COMM_SEND/RECV nodes get rewritten to
# COMP_NODE with ~25us equivalent compute, preserving dependency edges
# but bypassing real cross-shard flow simulation.  Intra-shard flows are
# fully modeled.  This is accurate when cross-PP traffic is a small
# fraction of total iteration time (typical for GPT / Megatron).
#
# Usage:
#   run_pp_sharded.sh \
#       --base-exp <path>       # existing *_htsim dir (topology, system)
#       --workload-dir <path>   # full unsharded STG workload dir
#       --pp <N> --dp <D> --tp <T>   # parallelism dims
#       --out-dir <path>        # where shard exp dirs + csv go
#       [--queue lossless]      # ASTRASIM_HTSIM_QUEUE_TYPE (default lossless)
#       [--proto roce]          # --htsim-proto value (default roce)
#       [--endtime 300]         # ASTRASIM_HTSIM_ENDTIME_SEC (default 300)
#       [--parallel 0]          # max concurrent; 0 = all (default all)

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
PY="${PYTHON:-${PROJECT_DIR:?}/.venv/bin/python}"

base_exp=""
workload_dir=""
pp=""
dp=""
tp=""
out_dir=""
queue="lossless"
proto="roce"
endtime=300
parallel=0
boundary_us="25"

usage() {
    cat >&2 <<EOF
usage: run_pp_sharded.sh --base-exp <dir> --workload-dir <dir> --pp N --dp D --tp T --out-dir <dir> [opts]

required:
  --base-exp <dir>       existing htsim experiment dir (astra_system.json etc)
  --workload-dir <dir>   unsharded STG workload dir (workload.*.et + workload.json)
  --pp <N>               number of pipeline shards (also N htsim processes)
  --dp <D>               data-parallel dim
  --tp <T>               tensor-parallel dim
  --out-dir <dir>        where shard exp dirs + CSV land
optional:
  --queue <t>            lossless|composite|random (default lossless)
  --proto <p>            tcp|roce|dcqcn|hpcc (default roce)
  --endtime <s>          simtime cap in seconds (default 300)
  --parallel <n>         concurrent shard processes (default: pp)
  --boundary-us <f>      cross-shard P2P approximation latency (default 25us)
EOF
    exit 2
}

if [ $# -eq 0 ]; then usage; fi
while [ $# -gt 0 ]; do
    case "$1" in
        --base-exp) shift; base_exp="$1"; shift ;;
        --workload-dir) shift; workload_dir="$1"; shift ;;
        --pp) shift; pp="$1"; shift ;;
        --dp) shift; dp="$1"; shift ;;
        --tp) shift; tp="$1"; shift ;;
        --out-dir) shift; out_dir="$1"; shift ;;
        --queue) shift; queue="$1"; shift ;;
        --proto) shift; proto="$1"; shift ;;
        --endtime) shift; endtime="$1"; shift ;;
        --parallel) shift; parallel="$1"; shift ;;
        --boundary-us) shift; boundary_us="$1"; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

for a in base_exp workload_dir pp dp tp out_dir; do
    if [ -z "${!a}" ]; then echo "--${a//_/-} is required" >&2; usage; fi
done
[ -d "${base_exp}" ] || { echo "base-exp not a dir" >&2; exit 2; }
[ -d "${workload_dir}" ] || { echo "workload-dir not a dir" >&2; exit 2; }

mkdir -p "${out_dir}"

# Step 1: shard the workload.
shard_wkld_root="${out_dir}/workload_shards"
echo "[run_pp_sharded] splitting workload → ${shard_wkld_root}"
"${PY}" "${SCRIPT_DIR}/shard_workload_pp.py" \
    --workload-dir "${workload_dir}" \
    --out-dir "${shard_wkld_root}" \
    --pp "${pp}" --dp "${dp}" --tp "${tp}" \
    --boundary-latency-us "${boundary_us}"

stage_size=$((dp * tp))

# Step 2: build per-shard experiment dirs.
shard_exp_dirs=()
for i in $(seq 0 $((pp - 1))); do
    exp_dir="${out_dir}/shard_${i}_exp"
    "${SCRIPT_DIR}/make_pp_shard_exp.sh" \
        --base-exp "${base_exp}" \
        --shard-wkld "${shard_wkld_root}/pp_shard_${i}" \
        --shard-size "${stage_size}" \
        --out "${exp_dir}"
    shard_exp_dirs+=("${exp_dir}")
done

# Step 3: ensure binary exists.
if [ ! -x "${ASTRA_SIM}" ]; then
    echo "[run_pp_sharded] building AstraSim_HTSim..."
    bash "${PROJECT_DIR}/build/astra_htsim/build.sh" >/dev/null 2>&1 || {
        echo "build failed" >&2; exit 1;
    }
fi

# Step 4: launch in parallel.
if [ "${parallel}" -le 0 ]; then parallel="${pp}"; fi
out_csv="${out_dir}/run.csv"
echo "shard,finished,max_cycle,wall_sec,rc" > "${out_csv}"

run_one_shard() {
    local sdir="$1"
    local sname
    sname=$(basename "${sdir}")
    local log="${sdir}/runner.log"
    rm -rf "${sdir}/log" "${sdir}/run_htsim.log" "${log}"
    local start_ts
    start_ts=$(date +%s)
    # ASTRASIM_LOG_LEVEL defaults to `info` here (cuts the per-node
    # debug log lines that otherwise throttle the DES loop on large
    # shards). Override by exporting ASTRASIM_LOG_LEVEL in the caller.
    env HTSIM_PROTO="${proto}" \
        ASTRASIM_HTSIM_QUEUE_TYPE="${queue}" \
        ASTRASIM_HTSIM_ENDTIME_SEC="${endtime}" \
        ASTRASIM_LOG_LEVEL="${ASTRASIM_LOG_LEVEL:-info}" \
        bash -c "cd '${sdir}' && bash run_htsim.sh > '${log}' 2>&1"
    local rc=$?
    local end_ts
    end_ts=$(date +%s)
    local wall=$((end_ts - start_ts))

    # Discover the finished-line pattern in both run_htsim.log and log/log.log
    local finished max_cycle
    finished=$(grep -hoE "sys\[[0-9]+\] finished" \
                "${sdir}/run_htsim.log" "${sdir}/log/log.log" 2>/dev/null \
                | sort -u | wc -l)
    max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" \
                "${sdir}/run_htsim.log" "${sdir}/log/log.log" 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    printf "%s,%s,%s,%s,%s\n" "${sname}" "${finished}" "${max_cycle}" "${wall}" "${rc}" >> "${out_csv}"
}

export -f run_one_shard
export proto queue endtime out_csv

echo "[run_pp_sharded] launching ${pp} shards (up to ${parallel} concurrent)..."
start_wall=$(date +%s)
for sdir in "${shard_exp_dirs[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "${parallel}" ]; do
        wait -n
    done
    run_one_shard "${sdir}" &
done
wait
end_wall=$(date +%s)

echo "---"
cat "${out_csv}"

combined_max=$(tail -n +2 "${out_csv}" | awk -F, '{if ($3+0 > max) max=$3+0} END{print max+0}')
worst_rc=$(tail -n +2 "${out_csv}" | awk -F, '{if ($5+0 > max) max=$5+0} END{print max+0}')
all_finished=$(tail -n +2 "${out_csv}" | awk -F, '$2+0 > 0 {c++} END{print c+0}')

echo "---"
echo "combined_max_cycle=${combined_max}"
echo "shards_with_finishers=${all_finished}/${pp}"
echo "wall_total_sec=$((end_wall - start_wall))"
echo "worst_rc=${worst_rc}"

if [ "${worst_rc}" -ne 0 ] || [ "${all_finished}" -ne "${pp}" ]; then
    exit 1
fi
exit 0
