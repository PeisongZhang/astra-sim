#!/bin/bash
# gpt_39b @ full 512 NPU — §11.6 golden acceptance via U2 PP sharding.
# Layout: DP=32 TP=8 PP=2 LAYER=4 BATCH=256 MICROBATCH=2.
# Topology: flat 256-host star per shard (simpler than Clos; avoids
# routing-table size overhead, keeps DES event count manageable).
#
# Captured baselines (2026-04-22):
#   analytical (512-host star): 196,101,888 cycles
#   htsim combined_max_cycle:   182,243,326 cycles
#   ratio:                      0.9293    (§11.6 [0.9, 1.5])
#   wall:                       ~5-6 min   (2 shards in parallel)

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_DIR=$(realpath "${PROJECT_DIR}")

WORKLOAD_DIR="${WORKLOAD_DIR:-${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b/fused_standard_4_1_256_2_2048_1f1b_v1_sgo1_ar1}"
SHARD_WKLD_ROOT="${SHARD_WKLD_ROOT:-/tmp/shard_512_star}"
OUT_DIR="${OUT_DIR:-${ASTRA_DIR}/htsim_experiment/gpt_39b_512_star_sharded}"
QUEUE="${ASTRASIM_HTSIM_QUEUE_TYPE:-lossless}"
PROTO="${HTSIM_PROTO:-roce}"
ENDTIME="${ASTRASIM_HTSIM_ENDTIME_SEC:-120}"
ANALYTICAL_BASELINE_CYCLES=196101888

if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[gpt_39b_512_star] Generating workload (LAYER=4 BATCH=256)..."
    (cd "${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b" && \
        LAYER=4 DP=32 TP=8 PP=2 BATCH=256 MICROBATCH=2 bash megatron_gpt_39b.sh) \
        > /tmp/gen512.log 2>&1 || { echo "gen failed" >&2; exit 1; }
fi

# Shard workload if not already done.
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

# Build 256-host flat-star topology for each shard.
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
    local sdir="$1"
    local shard_wkld="$2"
    local log="${sdir}/runner.log"
    /bin/rm -f "${log}"
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

echo "[gpt_39b_512_star] launching 2 shards (QUEUE=${QUEUE}, 256 NPU each, 256-host star)..."
echo "[gpt_39b_512_star] start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
t0=$(date +%s)
run_shard "${OUT_DIR}/shard_0_exp" "${SHARD_WKLD_ROOT}/pp_shard_0" &
pid0=$!
run_shard "${OUT_DIR}/shard_1_exp" "${SHARD_WKLD_ROOT}/pp_shard_1" &
pid1=$!
wait ${pid0} ${pid1}
t1=$(date +%s)
echo "[gpt_39b_512_star] end: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

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
    echo "[gpt_39b_512_star] FAIL — not all shards reached 256/256"
    exit 1
fi
pass=$(awk "BEGIN{r=${MAX} / ${ANALYTICAL_BASELINE_CYCLES}; print (r >= 0.9 && r <= 1.5) ? 1 : 0}")
if [ "${pass}" -ne 1 ]; then
    echo "[gpt_39b_512_star] FAIL — cycle ratio outside §11.6 window"
    exit 1
fi
echo "[gpt_39b_512_star] PASS §11.6 cycle acceptance"
