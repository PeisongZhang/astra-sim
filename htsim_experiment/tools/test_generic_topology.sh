#!/bin/bash
# Minimal Phase 1 integration test for GenericCustomTopology.
# Runs the qwen ring_ag smoke end-to-end; checks that:
#   (a) binary exits 0,
#   (b) all 16 ranks reached sys[N] finished,
#   (c) the flow-finish callback count matches what the Sys layer expected
#       (notify_sender_sending_finished never asserts).
set -o pipefail
set -e

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
LOG=/tmp/generic_topology_test.log

BIN="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
WL="${PROJECT_DIR:?}/qwen_experiment/ring_ag/all_gather/all_gather"
SYS="${PROJECT_DIR:?}/qwen_experiment/ring_ag/astra_system.json"
MEM="${PROJECT_DIR:?}/qwen_experiment/ring_ag/no_memory_expansion.json"
NET="${PROJECT_DIR:?}/qwen_experiment/ring_ag/analytical.yml"

echo "[test_generic] running ring_ag..."
timeout 600 "${BIN}" \
    --workload-configuration="${WL}" \
    --system-configuration="${SYS}" \
    --remote-memory-configuration="${MEM}" \
    --network-configuration="${NET}" \
    > "${LOG}" 2>&1

finished=$(grep -c "finished," "${LOG}" || true)
if [ "${finished}" -ne 16 ]; then
    echo "[test_generic] FAIL: expected 16 ranks finished, got ${finished}"
    tail -40 "${LOG}"
    exit 1
fi

if grep -q "Cannot find send_event" "${LOG}"; then
    echo "[test_generic] FAIL: send-event mismatch detected"
    grep "Cannot find" "${LOG}" | head -3
    exit 1
fi

if grep -qi "assertion.*failed\|Aborted" "${LOG}"; then
    echo "[test_generic] FAIL: assertion or abort"
    grep -i "assertion\|Aborted" "${LOG}" | head -3
    exit 1
fi

max_cycle=$(grep -Po "(?<=finished, )[0-9]+" "${LOG}" | sort -n | tail -1)
echo "[test_generic] PASS — 16 ranks finished; max cycle ${max_cycle}."
