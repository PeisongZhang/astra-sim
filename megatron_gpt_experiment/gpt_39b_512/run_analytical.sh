#!/bin/bash
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

ASTRA_SIM="${PROJECT_DIR:?}/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware"

# Build only if the binary is missing — avoids rebuilding between PPR tries.
if [ ! -x "${ASTRA_SIM}" ]; then
    echo "[ASTRA-sim] Binary missing, building congestion-aware backend..."
    "${PROJECT_DIR:?}/build/astra_analytical/build.sh" -t congestion_aware || exit 1
fi

# Workload directory produced by dnn_workload/megatron_gpt_39b/megatron_gpt_39b.sh.
# Override via WORKLOAD_DIR env var if a different invocation set was used.
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/megatron_gpt_39b/fused_standard_48_1_1536_2_2048_1f1b_v1_sgo1_ar1"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"

WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
LOG_FILE="${SCRIPT_DIR:?}/run_analytical.log"
NUM_QUEUES_PER_DIM="${ANALYTICAL_NUM_QUEUES_PER_DIM:-1}"

# Parallel event processing speeds up analytical sim real-time substantially
# (roughly N× for TP-heavy workloads when many same-timestamp events are
# parallel-safe). See extern/network_backend/analytical/common/event-queue/
# EventQueue.cpp and qwen_experiment/in_dc/analytical.sh for the knobs.
export ASTRA_EVENT_PARALLEL_THREADS="${ASTRA_EVENT_PARALLEL_THREADS:-8}"
export ASTRA_EVENT_PARALLEL_MIN_EVENTS="${ASTRA_EVENT_PARALLEL_MIN_EVENTS:-4}"

# Sanity checks
if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[ASTRA-sim] ERROR: workload.0.et not found in ${WORKLOAD_DIR}. Run dnn_workload/megatron_gpt_39b/megatron_gpt_39b.sh first." >&2
    exit 1
fi
if [ ! -f "${COMM_GROUP}" ]; then
    echo "[ASTRA-sim] ERROR: comm-group json not found: ${COMM_GROUP}" >&2
    exit 1
fi

echo "[ASTRA-sim] Running 39.1B GPT (512 GPUs) with analytical congestion-aware backend..."
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
