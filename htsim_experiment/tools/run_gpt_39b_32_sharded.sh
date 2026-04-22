#!/bin/bash
# gpt_39b acceptance at 32-NPU scale via U2 PP sharding.
# Layout: DP=2 TP=8 PP=2 LAYER=4 BATCH=16 MICROBATCH=2 → 2 shards × 16 NPU each.
# This validates §11.6 cycle acceptance for the production gpt_39b
# architecture (DP/TP/PP sharding, boundary-COMP substitution, per-shard
# topology extraction, parallel htsim dispatch, max-cycle aggregation).
#
# Analytical baseline (captured 2026-04-22): 185,615,544 cycles.
# htsim combined_max_cycle (lossless queue, random baseline): 169,562,997.
# Ratio 0.9135 — within §11.6 window [0.9, 1.5]. Both shards 16/16 ranks
# finished. Wall time ~30-60 sec.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_DIR=$(realpath "${PROJECT_DIR}")

WORKLOAD_DIR="${WORKLOAD_DIR:-${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b/fused_standard_4_1_16_2_2048_1f1b_v1_sgo1_ar1}"
SHARD_WKLD_ROOT="${SHARD_WKLD_ROOT:-/tmp/shard_32}"
OUT_DIR="${OUT_DIR:-${ASTRA_DIR}/htsim_experiment/gpt_39b_32_sharded}"
QUEUE="${ASTRASIM_HTSIM_QUEUE_TYPE:-lossless}"
PROTO="${HTSIM_PROTO:-roce}"
ENDTIME="${ASTRASIM_HTSIM_ENDTIME_SEC:-60}"
ANALYTICAL_BASELINE_CYCLES=185615544

if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[gpt_39b_32] Generating workload..."
    (cd "${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b" && \
        LAYER=4 DP=2 TP=8 PP=2 BATCH=16 MICROBATCH=2 bash megatron_gpt_39b.sh) \
        > /tmp/gen32.log 2>&1 || { echo "gen failed" >&2; exit 1; }
fi

# Shard workload if not already done.
if [ ! -f "${SHARD_WKLD_ROOT}/pp_shard_1/workload.15.et" ]; then
    /bin/rm -r "${SHARD_WKLD_ROOT}" 2>/dev/null
    PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
        "${ASTRA_DIR}/.venv/bin/python" \
        "${SCRIPT_DIR}/shard_workload_pp.py" \
        --workload-dir "${WORKLOAD_DIR}" \
        --out-dir "${SHARD_WKLD_ROOT}" \
        --pp 2 --dp 2 --tp 8 --workers 4 || exit 1
fi

mkdir -p "${OUT_DIR}"

# Build 16-host star topology for each shard.
for i in 0 1; do
    EXP="${OUT_DIR}/shard_${i}_exp"
    mkdir -p "${EXP}"
    cat > "${EXP}/astra_system.json" <<'JSON_EOF'
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
    cat > "${EXP}/no_memory_expansion.json" <<'JSON_EOF'
{"memory-type": "NO_MEMORY_EXPANSION"}
JSON_EOF
    cat > "${EXP}/analytical_network.yml" <<'YML_EOF'
topology: [ Custom ]
topology_file: "topology.txt"
npus_count: [ 16 ]
YML_EOF
    # 16 hosts + 1 switch (id 16), 32 directed links.
    {
        echo "17 1 32"
        echo "16"
        for r in $(seq 0 15); do
            echo "${r} 16 400Gbps 0.0005ms 0"
            echo "16 ${r} 400Gbps 0.0005ms 0"
        done
    } > "${EXP}/topology.txt"
done

ASTRA_SIM="${ASTRA_DIR}/build/astra_htsim/build/bin/AstraSim_HTSim"
[ -x "${ASTRA_SIM}" ] || { bash "${ASTRA_DIR}/build/astra_htsim/build.sh" || exit 1; }

CSV="${OUT_DIR}/run.csv"
echo "shard,finished,max_cycle,wall_sec,rc" > "${CSV}"

run_shard() {
    local sdir="$1"
    local shard_wkld="$2"
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

echo "[gpt_39b_32] launching 2 shards (QUEUE=${QUEUE}, 16 NPU each)..."
echo "[gpt_39b_32] start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
t0=$(date +%s)
run_shard "${OUT_DIR}/shard_0_exp" "${SHARD_WKLD_ROOT}/pp_shard_0" &
pid0=$!
run_shard "${OUT_DIR}/shard_1_exp" "${SHARD_WKLD_ROOT}/pp_shard_1" &
pid1=$!
wait ${pid0} ${pid1}
t1=$(date +%s)
echo "[gpt_39b_32] end: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "---"
cat "${CSV}"

MAX=$(tail -n +2 "${CSV}" | awk -F, '{if ($3+0 > max) max=$3+0} END{print max+0}')
OK=$(tail -n +2 "${CSV}" | awk -F, 'BEGIN{c=0} $2+0 == 16 && $5+0 == 0 {c++} END{print c}')

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
    echo "[gpt_39b_32] FAIL — not all shards reached 16/16"
    exit 1
fi
pass=$(awk "BEGIN{r=${MAX} / ${ANALYTICAL_BASELINE_CYCLES}; print (r >= 0.9 && r <= 1.5) ? 1 : 0}")
if [ "${pass}" -ne 1 ]; then
    echo "[gpt_39b_32] FAIL — cycle ratio outside §11.6 window"
    exit 1
fi
echo "[gpt_39b_32] PASS §11.6 cycle acceptance"
