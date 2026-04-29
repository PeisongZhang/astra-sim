#!/bin/bash
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

# --- Build ---
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware"

#echo "[ASTRA-sim] Building analytical congestion-aware backend..."
#"${PROJECT_DIR:?}/build/astra_analytical/build.sh" -t congestion_aware || exit 1
#echo "[ASTRA-sim] Build finished."

# --- Configuration files ---
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_8b/attstandard_sgdlocal_layer32_iter8_batch128_micro2_seq8192_dp4_tp1_pp4_sp1_ep1"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"
WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/../config/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
NUM_QUEUES_PER_DIM="${ANALYTICAL_NUM_QUEUES_PER_DIM:-1}"

# --- Run ---
echo "[ASTRA-sim] Running with analytical congestion-aware backend (custom topology)..."
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --num-queues-per-dim="${NUM_QUEUES_PER_DIM}"
SIM_EXIT=${PIPESTATUS[0]}

if [ ${SIM_EXIT} -ne 0 ]; then
    echo "[ASTRA-sim] Warning: Simulator exited with code ${SIM_EXIT}."
fi

echo "[ASTRA-sim] Finished."
exit ${SIM_EXIT}
