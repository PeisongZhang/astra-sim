#!/bin/bash
set -o pipefail
set -x
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${ASTRA_SIM}" ]; then
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || exit 1
fi
WORKLOAD="${PROJECT_DIR:?}/qwen_experiment/ring_ag/all_gather/all_gather"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical.yml"
LOG_FILE="${SCRIPT_DIR:?}/run_htsim.log"
PROTO="${HTSIM_PROTO:-roce}"
if [ ! -f "${NETWORK}" ]; then
    cp "${PROJECT_DIR:?}/qwen_experiment/ring_ag/analytical.yml" "${NETWORK}"
    cp "${PROJECT_DIR:?}/qwen_experiment/ring_ag/topology.txt" "${SCRIPT_DIR:?}/topology.txt" 2>/dev/null
fi
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --htsim-proto="${PROTO}" \
    2>&1 | tee "${LOG_FILE}"
exit ${PIPESTATUS[0]}
