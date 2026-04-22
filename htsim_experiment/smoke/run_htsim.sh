#!/bin/bash
# Phase 0 smoke: run 16-NPU ring all-gather on the htsim backend.
# The htsim FatTree is substituted for the ring topology here just to prove
# flow-finish + the end-to-end pipeline work; not a cycle-equivalent run.
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

BIN="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${BIN}" ]; then
    echo "[smoke] building htsim backend..."
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || exit 1
fi

WORKLOAD_DIR="${PROJECT_DIR:?}/qwen_experiment/ring_ag"
WL="${WORKLOAD_DIR}/all_gather/all_gather"
SYS="${WORKLOAD_DIR}/astra_system.json"
MEM="${WORKLOAD_DIR}/no_memory_expansion.json"
NET="${WORKLOAD_DIR}/analytical.yml"
LOG="${SCRIPT_DIR}/run_htsim.log"

timeout 600 "${BIN}" \
    --workload-configuration="${WL}" \
    --system-configuration="${SYS}" \
    --remote-memory-configuration="${MEM}" \
    --network-configuration="${NET}" \
    2>&1 | tee "${LOG}"
