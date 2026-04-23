#!/bin/bash
# gpt_39b @ 512 NPU L48 B1536 (arxiv Table 1 row 5, §22 O1).
# Layout: DP=32 TP=8 PP=2 LAYER=48 BATCH=1536 MICROBATCH=2 (24 microbatches/iter).
# Topology: 256-host flat star per shard.
#
# Previously in §22 this was listed as O1 (OOM-blocked on 30 GiB machine).
# §23 memory optimizations reduce per-shard RSS from ~10 GB to ~1 GB, so
# it now fits comfortably on 30 GiB (both shards parallel ~2 GB total).
# Wall time is still dominated by single-threaded DES (estimated ~12 hours
# for the full B1536 pipeline); use Monitor or run in background.
#
# Reference analytical baseline (from §22 ran by user, not re-computed):
#   analytical: 8,309,162,520 cycles (B1536 single iteration)
# htsim cycle target: ratio in [0.9, 1.5] of that.

set -o pipefail
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_DIR=$(realpath "${PROJECT_DIR}")

WORKLOAD_DIR="${WORKLOAD_DIR:-${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b/fused_standard_48_1_1536_2_2048_1f1b_v1_sgo1_ar1}"
SHARD_WKLD_ROOT="${SHARD_WKLD_ROOT:-/tmp/shard_512_L48B1536}"
OUT_DIR="${OUT_DIR:-${ASTRA_DIR}/htsim_experiment/gpt_39b_512_L48B1536_sharded}"
QUEUE="${ASTRASIM_HTSIM_QUEUE_TYPE:-lossless}"
PROTO="${HTSIM_PROTO:-roce}"
ENDTIME="${ASTRASIM_HTSIM_ENDTIME_SEC:-3000}"
ANALYTICAL_BASELINE_CYCLES=8309162520

if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[gpt_39b_512_L48B1536] Generating workload (LAYER=48 BATCH=1536)..."
    (cd "${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b" && \
        LAYER=48 DP=32 TP=8 PP=2 BATCH=1536 MICROBATCH=2 bash megatron_gpt_39b.sh) \
        > /tmp/gen512_L48B1536.log 2>&1 || { echo "gen failed — see /tmp/gen512_L48B1536.log" >&2; exit 1; }
fi

if [ ! -f "${SHARD_WKLD_ROOT}/pp_shard_1/workload.255.et" ]; then
    /bin/rm -r "${SHARD_WKLD_ROOT}" 2>/dev/null
    PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
        "${ASTRA_DIR}/.venv/bin/python" \
        "${SCRIPT_DIR}/shard_workload_pp.py" \
        --workload-dir "${WORKLOAD_DIR}" \
        --out-dir "${SHARD_WKLD_ROOT}" \
        --pp 2 --dp 32 --tp 8 --workers 6 || exit 1
fi

mkdir -p "${OUT_DIR}"
build_star_exp() {
    local d="$1"
    mkdir -p "${d}"
    cat > "${d}/astra_system.json" <<'JSON_EOF'
{
    "scheduling-policy": "LIFO",
    "endpoint-delay": 10,
    "active-chunks-per-dimension": 2,
    "preferred-dataset-splits": 4,
    "all-reduce-implementation": ["ring"],
    "all-gather-implementation": ["ring"],
    "reduce-scatter-implementation": ["ring"],
    "all-to-all-implementation": ["direct"],
    "collective-optimization": "localBWAware",
    "local-mem-bw": 1560,
    "boost-mode": 0,
    "roofline-enabled": 1,
    "peak-perf": 312
}
JSON_EOF
    cat > "${d}/no_memory_expansion.json" <<'JSON_EOF'
{"memory-type": "NO_MEMORY_EXPANSION"}
JSON_EOF
    cat > "${d}/analytical_network.yml" <<'YML_EOF'
topology: [ Custom ]
topology_file: "topology.txt"
npus_count: [ 256 ]
YML_EOF
    {
        echo "257 1 512"
        echo "256"
        for r in $(seq 0 255); do
            echo "${r} 256 400Gbps 0.0005ms 0"
            echo "256 ${r} 400Gbps 0.0005ms 0"
        done
    } > "${d}/topology.txt"
}
build_star_exp "${OUT_DIR}/shard_0_exp"
build_star_exp "${OUT_DIR}/shard_1_exp"

ASTRA_SIM="${ASTRA_DIR}/build/astra_htsim/build/bin/AstraSim_HTSim"
[ -x "${ASTRA_SIM}" ] || { bash "${ASTRA_DIR}/build/astra_htsim/build.sh" || exit 1; }

CSV="${OUT_DIR}/run.csv"
echo "shard,finished,max_cycle,wall_sec,rc" > "${CSV}"

run_shard() {
    local sdir="$1" shard_wkld="$2"
    local log="${sdir}/runner.log"
    local t0; t0=$(date +%s)
    env ASTRASIM_HTSIM_QUEUE_TYPE="${QUEUE}" \
        ASTRASIM_HTSIM_ENDTIME_SEC="${ENDTIME}" \
        ASTRASIM_LOG_LEVEL="${ASTRASIM_LOG_LEVEL:-info}" \
        ASTRASIM_FLUSH_ON="${ASTRASIM_FLUSH_ON:-info}" \
        "${ASTRA_SIM}" \
        --workload-configuration="${shard_wkld}/workload" \
        --comm-group-configuration="${shard_wkld}/workload.json" \
        --system-configuration="${sdir}/astra_system.json" \
        --remote-memory-configuration="${sdir}/no_memory_expansion.json" \
        --network-configuration="${sdir}/analytical_network.yml" \
        --htsim-proto="${PROTO}" > "${log}" 2>&1
    local rc=$?
    local t1; t1=$(date +%s)
    local n max_cyc
    n=$(grep -hoE "sys\[[0-9]+\] finished" "${log}" 2>/dev/null | sort -u | wc -l)
    max_cyc=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${log}" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    printf "%s,%s,%s,%s,%s\n" "$(basename "${sdir}")" "${n}" "${max_cyc}" "$((t1 - t0))" "${rc}" >> "${CSV}"
}

echo "[gpt_39b_512_L48B1536] launching 2 shards (LAYER=48, BATCH=1536)..."
echo "[gpt_39b_512_L48B1536] NOTE: long wall expected (~12h est); monitor shards/runner.log."
echo "[gpt_39b_512_L48B1536] start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
t0=$(date +%s)
run_shard "${OUT_DIR}/shard_0_exp" "${SHARD_WKLD_ROOT}/pp_shard_0" &
pid0=$!
run_shard "${OUT_DIR}/shard_1_exp" "${SHARD_WKLD_ROOT}/pp_shard_1" &
pid1=$!
wait ${pid0} ${pid1}
t1=$(date +%s)
echo "[gpt_39b_512_L48B1536] end: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "---"
cat "${CSV}"
MAX=$(tail -n +2 "${CSV}" | awk -F, '{if ($3+0 > max) max=$3+0} END{print max+0}')
OK=$(tail -n +2 "${CSV}" | awk -F, 'BEGIN{c=0} $2+0 == 256 && $5+0 == 0 {c++} END{print c}')
echo "---"
echo "analytical_baseline_cycles=${ANALYTICAL_BASELINE_CYCLES}"
echo "combined_max_cycle=${MAX}"
if [ "${MAX}" -gt 0 ]; then
    ratio=$(awk "BEGIN{printf \"%.4f\", ${MAX} / ${ANALYTICAL_BASELINE_CYCLES}}")
    echo "cycle_ratio=${ratio}  (§11.6 window [0.9, 1.5])"
fi
echo "shards_fully_finished=${OK}/2"
echo "wall_total_sec=$((t1 - t0))"
if [ "${OK}" -ne 2 ]; then
    echo "[gpt_39b_512_L48B1536] FAIL — not all shards reached 256/256"
    exit 1
fi
pass=$(awk "BEGIN{r=${MAX} / ${ANALYTICAL_BASELINE_CYCLES}; print (r >= 0.9 && r <= 1.5) ? 1 : 0}")
if [ "${pass}" -ne 1 ]; then
    echo "[gpt_39b_512_L48B1536] FAIL — cycle ratio outside §11.6 window"
    exit 1
fi
echo "[gpt_39b_512_L48B1536] PASS §11.6 cycle acceptance (arxiv-exact B1536) — §22 O1 cleared"
