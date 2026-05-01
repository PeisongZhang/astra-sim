#!/bin/bash
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

# --- Build ---
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware"

if [ ! -x "${ASTRA_SIM}" ]; then
    echo "[ASTRA-sim] Binary missing, building congestion-aware backend..."
    "${PROJECT_DIR:?}/build/astra_analytical/build.sh" -t congestion_aware || exit 1
fi

# --- Configuration files ---
# E4 Llama3-70B inter-DC DP + LocalSGD (1024 GPUs, ITERATION=4 LocalSGD interval, DP=32 TP=8 PP=4).
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_70b/attfused_sgdlocal_layer80_iter4_batch1792_micro2_seq2048_dp32_tp8_pp4_sp1_ep1_ar1"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"
WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/../config/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
NUM_QUEUES_PER_DIM="${ANALYTICAL_NUM_QUEUES_PER_DIM:-1}"

export ASTRA_EVENT_PARALLEL_THREADS="${ASTRA_EVENT_PARALLEL_THREADS:-8}"
export ASTRA_EVENT_PARALLEL_MIN_EVENTS="${ASTRA_EVENT_PARALLEL_MIN_EVENTS:-4}"

# --- Run ---
echo "[ASTRA-sim] Running with analytical congestion-aware backend (custom topology)..."
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --num-queues-per-dim="${NUM_QUEUES_PER_DIM}" \
    --logging-folder="${SCRIPT_DIR}/log_analytical"
SIM_EXIT=${PIPESTATUS[0]}

if [ ${SIM_EXIT} -ne 0 ]; then
    echo "[ASTRA-sim] Warning: Simulator exited with code ${SIM_EXIT}."
fi

echo "[ASTRA-sim] Finished."
exit ${SIM_EXIT}
