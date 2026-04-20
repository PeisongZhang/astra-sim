#!/bin/bash
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

ASTRA_SIM="${PROJECT_DIR:?}/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware"

WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/megatron_gpt_76b/fused_standard_60_1_1792_2_2048_1f1b_v1_sgo1_ar0"
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

"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --num-queues-per-dim="${NUM_QUEUES_PER_DIM}" \
    2>&1 | tee "${LOG_FILE}"
exit ${PIPESTATUS[0]}
