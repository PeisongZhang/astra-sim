#!/bin/bash
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

ASTRA_SIM="${PROJECT_DIR:?}/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware"

if [ ! -x "${ASTRA_SIM}" ]; then
    echo "[ASTRA-sim] Binary missing, building congestion-aware backend..."
    "${PROJECT_DIR:?}/build/astra_analytical/build.sh" -t congestion_aware || exit 1
fi

# W-std: ITERATION=2, standard SGD, Llama3-70B, DP=32 TP=8 PP=4.
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_70b/fused_standard_80_2_512_2_2048_1f1b_v1_sgo1_ar1"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"

WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
LOG_FILE="${SCRIPT_DIR:?}/run_analytical.log"
NUM_QUEUES_PER_DIM="${ANALYTICAL_NUM_QUEUES_PER_DIM:-1}"

export ASTRA_EVENT_PARALLEL_THREADS="${ASTRA_EVENT_PARALLEL_THREADS:-8}"
export ASTRA_EVENT_PARALLEL_MIN_EVENTS="${ASTRA_EVENT_PARALLEL_MIN_EVENTS:-4}"

if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[ASTRA-sim] ERROR: workload.0.et not found in ${WORKLOAD_DIR}." >&2
    echo "[ASTRA-sim] Run dnn_workload/llama3_70b/llama3_70b.sh with ITERATION=2 first." >&2
    exit 1
fi
if [ ! -f "${COMM_GROUP}" ]; then
    echo "[ASTRA-sim] ERROR: comm-group json not found: ${COMM_GROUP}" >&2
    exit 1
fi

echo "[ASTRA-sim] E1 Llama3-70B single-DC (1024 GPUs)..."
echo "[ASTRA-sim] Workload dir: ${WORKLOAD_DIR}"

"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --num-queues-per-dim="${NUM_QUEUES_PER_DIM}" \
    2>&1 | tee "${LOG_FILE}"
SIM_EXIT=${PIPESTATUS[0]}

if [ ${SIM_EXIT} -ne 0 ]; then
    echo "[ASTRA-sim] Warning: Simulator exited with code ${SIM_EXIT}."
fi

echo "[ASTRA-sim] Log saved to ${LOG_FILE}."
exit ${SIM_EXIT}
