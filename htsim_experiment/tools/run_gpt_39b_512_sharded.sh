#!/bin/bash
# U2 acceptance harness for megatron_gpt_39b_512 with PP=2 sharding.
#
# Reuses the existing megatron_gpt_experiment/gpt_39b_512_htsim base
# experiment (astra_system.json / analytical_network.yml / topology.txt)
# and the unsharded STG workload, splits both along PP=2, launches 2
# AstraSim_HTSim processes in parallel, and reports combined max_cycle
# vs the analytical baseline for §11.6 acceptance evaluation.
#
# Env vars:
#   SHARD_WKLD_ROOT   where to materialize per-shard workloads
#                     (default /tmp/shard_gpt39b_pp2)
#   OUT_DIR           where shard exp dirs + CSV land
#                     (default astra-sim/htsim_experiment/gpt_39b_512_sharded)
#   ASTRASIM_HTSIM_ENDTIME_SEC   default 300
#   ASTRASIM_HTSIM_QUEUE_TYPE    default lossless

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_DIR=$(realpath "${PROJECT_DIR}")

BASE_EXP="${ASTRA_DIR}/megatron_gpt_experiment/gpt_39b_512_htsim"
WORKLOAD_DIR="${WORKLOAD_DIR:-${ASTRA_DIR}/../dnn_workload/megatron_gpt_39b/fused_standard_48_1_1536_2_2048_1f1b_v1_sgo1_ar1}"
SHARD_WKLD_ROOT="${SHARD_WKLD_ROOT:-/tmp/shard_gpt39b_pp2}"
OUT_DIR="${OUT_DIR:-${ASTRA_DIR}/htsim_experiment/gpt_39b_512_sharded}"
QUEUE="${ASTRASIM_HTSIM_QUEUE_TYPE:-lossless}"
PROTO="${HTSIM_PROTO:-roce}"
ENDTIME="${ASTRASIM_HTSIM_ENDTIME_SEC:-300}"
ANALYTICAL_BASELINE_CYCLES=12382114950  # from megatron_gpt_experiment/gpt_39b_512/run_analytical.log

if [ ! -d "${BASE_EXP}" ]; then
    echo "base exp missing: ${BASE_EXP}" >&2; exit 1
fi
if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "workload missing: ${WORKLOAD_DIR}/workload.0.et" >&2; exit 1
fi

# Shard workload if not already materialised.
if [ ! -f "${SHARD_WKLD_ROOT}/pp_shard_1/workload.255.et" ]; then
    echo "[gpt_39b_512_sharded] splitting workload → ${SHARD_WKLD_ROOT}"
    /bin/rm -r "${SHARD_WKLD_ROOT}" 2>/dev/null
    PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
        "${ASTRA_DIR}/.venv/bin/python" \
        "${SCRIPT_DIR}/shard_workload_pp.py" \
        --workload-dir "${WORKLOAD_DIR}" \
        --out-dir "${SHARD_WKLD_ROOT}" \
        --pp 2 --dp 32 --tp 8 --workers 8 || exit 1
fi

mkdir -p "${OUT_DIR}"

# Build shard exp dirs.
for i in 0 1; do
    EXP="${OUT_DIR}/shard_${i}_exp"
    bash "${SCRIPT_DIR}/make_pp_shard_exp.sh" \
        --base-exp "${BASE_EXP}" \
        --shard-wkld "${SHARD_WKLD_ROOT}/pp_shard_${i}" \
        --shard-size 256 \
        --out "${EXP}"
done

ASTRA_SIM="${ASTRA_DIR}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${ASTRA_SIM}" ]; then
    bash "${ASTRA_DIR}/build/astra_htsim/build.sh" >/dev/null 2>&1 || {
        echo "build failed" >&2; exit 1;
    }
fi

CSV="${OUT_DIR}/run.csv"
echo "shard,finished,max_cycle,wall_sec,rc" > "${CSV}"

run_shard() {
    local sdir="$1"
    local log="${sdir}/runner.log"
    /bin/rm -r "${sdir}/log" 2>/dev/null
    /bin/rm -f "${sdir}/run_htsim.log" "${log}"
    local t0; t0=$(date +%s)
    env HTSIM_PROTO="${PROTO}" \
        ASTRASIM_HTSIM_QUEUE_TYPE="${QUEUE}" \
        ASTRASIM_HTSIM_ENDTIME_SEC="${ENDTIME}" \
        ASTRASIM_LOG_LEVEL="${ASTRASIM_LOG_LEVEL:-info}" \
        bash -c "cd '${sdir}' && bash run_htsim.sh > '${log}' 2>&1"
    local rc=$?
    local t1; t1=$(date +%s)
    local finished max_cyc
    finished=$(grep -hoE "sys\[[0-9]+\] finished" "${sdir}/run_htsim.log" "${sdir}/log/log.log" 2>/dev/null | sort -u | wc -l)
    max_cyc=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${sdir}/run_htsim.log" "${sdir}/log/log.log" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    printf "%s,%s,%s,%s,%s\n" "$(basename "${sdir}")" "${finished}" "${max_cyc}" "$((t1 - t0))" "${rc}" >> "${CSV}"
}

echo "[gpt_39b_512_sharded] launching 2 shards in parallel (QUEUE=${QUEUE}, ENDTIME=${ENDTIME}s simtime)..."
echo "[gpt_39b_512_sharded] start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
overall_t0=$(date +%s)
run_shard "${OUT_DIR}/shard_0_exp" &
pid0=$!
run_shard "${OUT_DIR}/shard_1_exp" &
pid1=$!
wait ${pid0} ${pid1}
overall_t1=$(date +%s)
echo "[gpt_39b_512_sharded] end: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "---"
cat "${CSV}"

MAX_COMBINED=$(tail -n +2 "${CSV}" | awk -F, '{if ($3+0 > max) max=$3+0} END{print max+0}')
ALL_OK=$(tail -n +2 "${CSV}" | awk -F, 'BEGIN{c=0} $2+0 == 256 && $5+0 == 0 {c++} END{print c}')

echo "---"
echo "analytical_baseline_cycles=${ANALYTICAL_BASELINE_CYCLES}"
echo "combined_max_cycle=${MAX_COMBINED}"
if [ "${MAX_COMBINED}" -gt 0 ]; then
    ratio=$(awk "BEGIN{printf \"%.4f\", ${MAX_COMBINED} / ${ANALYTICAL_BASELINE_CYCLES}}")
    echo "cycle_ratio=${ratio}  (§11.6 window [0.9, 1.5])"
fi
echo "shards_fully_finished=${ALL_OK}/2"
echo "wall_total_sec=$((overall_t1 - overall_t0))"

if [ "${ALL_OK}" -ne 2 ]; then
    echo "[gpt_39b_512_sharded] FAIL — not all shards reached 256/256"
    exit 1
fi
pass=$(awk "BEGIN{r=${MAX_COMBINED} / ${ANALYTICAL_BASELINE_CYCLES}; print (r >= 0.9 && r <= 1.5) ? 1 : 0}")
if [ "${pass}" -ne 1 ]; then
    echo "[gpt_39b_512_sharded] FAIL — cycle ratio outside §11.6 window"
    exit 1
fi
echo "[gpt_39b_512_sharded] PASS §11.6 cycle acceptance"
