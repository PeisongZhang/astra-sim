#!/bin/bash
# Minimal CI smoke test for the htsim backend.
# Runs 16-NPU ring all-gather and checks:
#   (1) binary exits 0
#   (2) all ranks reach sys[N] finished
#   (3) no assertion / abort / "Cannot find send_event"
# Intended to run in <30s on a laptop.
set -o pipefail
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/.."
BIN="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
LOG=/tmp/htsim_smoke.$$.log

if [ ! -x "${BIN}" ]; then
    echo "[htsim-smoke] Building..."
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || { echo "[htsim-smoke] build failed"; exit 1; }
fi

WORKLOAD_DIR="${PROJECT_DIR:?}/qwen_experiment/ring_ag"
timeout 300 "${BIN}" \
    --workload-configuration="${WORKLOAD_DIR}/all_gather/all_gather" \
    --system-configuration="${WORKLOAD_DIR}/astra_system.json" \
    --remote-memory-configuration="${WORKLOAD_DIR}/no_memory_expansion.json" \
    --network-configuration="${WORKLOAD_DIR}/analytical.yml" \
    --htsim-proto=roce \
    > "${LOG}" 2>&1
rc=$?

finished=$(grep -cE "sys\[[0-9]+\] finished" "${LOG}" || true)
if [ ${rc} -ne 0 ] || [ "${finished}" -ne 16 ]; then
    echo "[htsim-smoke] FAIL — rc=${rc} finished=${finished}/16"
    tail -20 "${LOG}"
    rm -f "${LOG}"
    exit 1
fi

if grep -qiE "assertion.*failed|Aborted|Cannot find send_event|Segmentation" "${LOG}"; then
    echo "[htsim-smoke] FAIL — fatal error detected"
    grep -iE "assertion|Aborted|Cannot find|Segmentation" "${LOG}" | head -3
    rm -f "${LOG}"
    exit 1
fi

max_cycle=$(grep -Po "(?<=finished, )[0-9]+" "${LOG}" | sort -n | tail -1)
echo "[htsim-smoke] PASS — 16/16 ranks finished, max cycle ${max_cycle}."
rm -f "${LOG}"
