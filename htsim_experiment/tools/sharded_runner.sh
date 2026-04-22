#!/bin/bash
# U2 — Sharded parallel htsim runner SKELETON.
#
# Status: skeleton only.  Spawns N AstraSim_HTSim child processes on
# pre-split sub-workloads and aggregates their max_cycle.  The STG-side
# workload splitter (see sharded_parallel_design.md §"Prerequisites") is
# NOT yet implemented; this runner currently exercises only the
# spawn/collect/aggregate path.  When the splitter lands, the shards will
# point at per-stage sub-workload directories.
#
# Usage:
#   sharded_runner.sh \
#       --shards shard0_dir shard1_dir ... \
#       --system shard0_dir/astra_system.json ... \
#       --network shard0_dir/analytical_network.yml ... \
#       --out    run_sharded.csv
#
# For the trivial case (N=1) this reduces to the normal `run_htsim.sh`
# but emits a combined CSV row.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"

shards=()
systems=()
networks=()
workloads=()
commgroups=()
out_csv=""

usage() {
    cat >&2 <<EOF
usage: sharded_runner.sh --shards <dir1> [dir2 ...] [other args]

required:
  --shards        one or more shard directories (must contain workload.*.et,
                  workload.json, astra_system.json, analytical_network.yml,
                  no_memory_expansion.json)
optional:
  --out <file>    CSV output (default /tmp/sharded_runner_\$(pid).csv)
  --endtime <s>   ASTRASIM_HTSIM_ENDTIME_SEC (default 1000)
  --proto <p>     --htsim-proto value (default roce)
  --queue  <q>    ASTRASIM_HTSIM_QUEUE_TYPE (default lossless)
  --parallel <n>  max concurrent children (default: #shards)
EOF
    exit 2
}

if [ $# -eq 0 ]; then usage; fi

endtime=${ASTRASIM_HTSIM_ENDTIME_SEC:-1000}
proto="roce"
queue="lossless"
parallel=0
while [ $# -gt 0 ]; do
    case "$1" in
        --shards) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do shards+=("$1"); shift; done ;;
        --out)    shift; out_csv="$1"; shift ;;
        --endtime) shift; endtime="$1"; shift ;;
        --proto)  shift; proto="$1"; shift ;;
        --queue)  shift; queue="$1"; shift ;;
        --parallel) shift; parallel="$1"; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

if [ ${#shards[@]} -eq 0 ]; then echo "error: --shards required" >&2; usage; fi
if [ "${parallel}" -le 0 ]; then parallel=${#shards[@]}; fi
if [ -z "${out_csv}" ]; then out_csv="/tmp/sharded_runner_$$.csv"; fi

# Each shard is expected to be a directory holding a `run_htsim.sh` that
# fully describes how to run the sub-workload. This keeps the runner
# topology-agnostic and reuses the same per-experiment entrypoint that
# users already know.  When the STG splitter lands, each PP stage will be
# a separate _htsim directory with its own run_htsim.sh configured for the
# sub-workload in dnn_workload/.../pp_shard_N/.
for s in "${shards[@]}"; do
    [ -x "${s}/run_htsim.sh" ] || { echo "shard ${s} missing executable run_htsim.sh" >&2; exit 1; }
done

if [ ! -x "${ASTRA_SIM}" ]; then
    echo "building AstraSim_HTSim..."
    bash "${PROJECT_DIR}/build/astra_htsim/build.sh" >/dev/null 2>&1 || {
        echo "build failed" >&2; exit 1;
    }
fi

echo "shard,finished,max_cycle,wall_sec,rc" > "${out_csv}"

run_shard() {
    local shard="$1"
    local log="${shard}/sharded_runner.log"
    rm -rf "${shard}/log" "${shard}/sharded_runner.log" "${shard}/run_htsim.log"
    local start_ts=$(date +%s)
    env HTSIM_PROTO="${proto}" \
        ASTRASIM_HTSIM_QUEUE_TYPE="${queue}" \
        ASTRASIM_HTSIM_ENDTIME_SEC="${endtime}" \
        bash -c "cd '${shard}' && bash run_htsim.sh > '${log}' 2>&1"
    local rc=$?
    local end_ts=$(date +%s)
    local wall=$((end_ts - start_ts))

    local finished=$(grep -hoE "sys\[[0-9]+\] finished" "${shard}/log/log.log" 2>/dev/null | sort -u | wc -l)
    local max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${shard}/log/log.log" 2>/dev/null \
        | sort -u | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')

    # Atomic CSV append (single-line writes are atomic on ext4 up to PIPE_BUF).
    printf "%s,%s,%s,%s,%s\n" \
        "$(basename "${shard}")" "${finished}" "${max_cycle}" "${wall}" "${rc}" >> "${out_csv}"
}

export -f run_shard
export ASTRA_SIM proto queue endtime out_csv

echo "running ${#shards[@]} shards with up to ${parallel} concurrent..."
pids=()
for s in "${shards[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "${parallel}" ]; do
        wait -n
    done
    run_shard "$s" &
    pids+=($!)
done
wait

echo "---"
echo "CSV: ${out_csv}"
cat "${out_csv}"

# Combined max_cycle — the slowest shard is the overall runtime.
combined_max=$(tail -n +2 "${out_csv}" | awk -F, '{if ($3+0 > max) max=$3+0} END{print max+0}')
worst_rc=$(tail -n +2 "${out_csv}" | awk -F, '{if ($5+0 > max) max=$5+0} END{print max+0}')

echo "---"
echo "combined_max_cycle=${combined_max}"
echo "worst_rc=${worst_rc}"

# Count of shards where finished == expected (we don't know expected from here
# without probing workload size; use > 0 as "run completed" heuristic).
completed=$(tail -n +2 "${out_csv}" | awk -F, '$2+0 > 0' | wc -l)
echo "completed_shards=${completed}/${#shards[@]}"

# Exit code: 0 only if all shards ran to completion with rc=0.
if [ "${worst_rc}" -ne 0 ] || [ "${completed}" -ne "${#shards[@]}" ]; then
    exit 1
fi
exit 0
