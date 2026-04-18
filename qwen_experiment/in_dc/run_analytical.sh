#!/bin/bash
set -o pipefail
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

# --- Build ---
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware"

if [ -x "${ASTRA_SIM}" ] && [ "${ANALYTICAL_SKIP_BUILD:-1}" = "1" ]; then
    echo "[ASTRA-sim] Reusing existing analytical binary (set ANALYTICAL_SKIP_BUILD=0 to rebuild)."
else
    echo "[ASTRA-sim] Building analytical congestion-aware backend..."
    "${PROJECT_DIR:?}/build/astra_analytical/build.sh" -t congestion_aware || exit 1
    echo "[ASTRA-sim] Build finished."
fi

# --- Configuration files ---
WORKLOAD="${SCRIPT_DIR:?}/workload/workload"
COMM_GROUP="${SCRIPT_DIR:?}/workload/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
LOG_FILE="${SCRIPT_DIR:?}/run_analytical.log"
NUM_QUEUES_PER_DIM="${ANALYTICAL_NUM_QUEUES_PER_DIM:-1}"

# --- Plan C tuning knobs (same-timestamp batch parallelism) ---
#   ASTRA_EVENT_PARALLEL_THREADS   : max threads for parallel-safe event runs
#                                    (default: hardware_concurrency; set to 1 to disable).
#   ASTRA_EVENT_PARALLEL_MIN_EVENTS: minimum contiguous parallel-safe events
#                                    before a run is dispatched to the pool
#                                    (default: 8).
#   ASTRA_EVENT_QUEUE_STATS        : if 1, dump per-run event-queue statistics
#                                    on exit.
#   ASTRA_ANALYTICAL_TIMING        : if 1, dump wall-clock breakdown of the
#                                    main simulation loop on exit.
DEFAULT_PARALLEL_THREADS="$(nproc 2>/dev/null || echo 1)"
if [ "${DEFAULT_PARALLEL_THREADS}" -gt 4 ]; then
    DEFAULT_PARALLEL_THREADS=4
fi
export ASTRA_EVENT_PARALLEL_THREADS="${ASTRA_EVENT_PARALLEL_THREADS:-${DEFAULT_PARALLEL_THREADS}}"
export ASTRA_EVENT_PARALLEL_MIN_EVENTS="${ASTRA_EVENT_PARALLEL_MIN_EVENTS:-8}"
export ASTRA_EVENT_QUEUE_STATS="${ASTRA_EVENT_QUEUE_STATS:-0}"
export ASTRA_ANALYTICAL_TIMING="${ASTRA_ANALYTICAL_TIMING:-0}"

# --- Run ---
echo "[ASTRA-sim] Running with analytical congestion-aware backend (custom topology)..."
echo "[ASTRA-sim] ASTRA_EVENT_PARALLEL_THREADS=${ASTRA_EVENT_PARALLEL_THREADS}" \
     "ASTRA_EVENT_PARALLEL_MIN_EVENTS=${ASTRA_EVENT_PARALLEL_MIN_EVENTS}" \
     "ASTRA_EVENT_QUEUE_STATS=${ASTRA_EVENT_QUEUE_STATS}" \
     "ASTRA_ANALYTICAL_TIMING=${ASTRA_ANALYTICAL_TIMING}"
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
echo "[ASTRA-sim] Finished."
exit ${SIM_EXIT}
