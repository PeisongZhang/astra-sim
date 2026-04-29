#!/bin/bash
set -o pipefail
set -x
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${ASTRA_SIM}" ]; then
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || exit 1
fi
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_8b/attstandard_sgdstandard_layer32_iter8_batch128_micro2_seq8192_dp4_tp1_pp4_sp1_ep1"

WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"
WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/../config/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
PROTO="${HTSIM_PROTO:-roce}"
export ASTRASIM_HTSIM_ENDTIME_SEC="${ASTRASIM_HTSIM_ENDTIME_SEC:-1000}"
export ASTRASIM_HTSIM_QUEUE_TYPE="${ASTRASIM_HTSIM_QUEUE_TYPE:-lossless}"
if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[htsim] ERROR: workload.0.et not found in ${WORKLOAD_DIR}." >&2
    exit 1
fi
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --htsim-proto="${PROTO}"
exit ${PIPESTATUS[0]}
