#!/bin/bash
set -o pipefail
set -x
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${ASTRA_SIM}" ]; then
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || exit 1
fi
WORKLOAD_DIR="${WORKLOAD_DIR:-${PROJECT_DIR:?}/qwen_experiment/in_dc/workload}"
WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/network.yml"
LOG_FILE="${SCRIPT_DIR:?}/run_htsim.log"
PROTO="${HTSIM_PROTO:-roce}"
export ASTRASIM_HTSIM_ENDTIME_SEC="${ASTRASIM_HTSIM_ENDTIME_SEC:-1000}"
if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[htsim] workload.0.et not found under ${WORKLOAD_DIR}" >&2
    exit 1
fi
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --htsim-proto="${PROTO}" \
    2>&1 | tee "${LOG_FILE}"
exit ${PIPESTATUS[0]}
