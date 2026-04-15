#!/bin/bash
set -x

SCRIPT_DIR=$(dirname "$(realpath $0)")
BIN="${SCRIPT_DIR:?}"/ns3

MEMORY="${SCRIPT_DIR:?}"/no_memory_expansion.json
LOGICAL_TOPOLOGY="${SCRIPT_DIR:?}"/logical_topo.json
SYSTEM="${SCRIPT_DIR:?}"/astra_system.json
WORKLOAD_DIR="${SCRIPT_DIR:?}"/workload
COMM_GROUP_CONFIGURATION="${WORKLOAD_DIR:?}"/workload.json
WORKLOAD="${WORKLOAD_DIR:?}/workload"
NETWORK="${SCRIPT_DIR:?}"/ns3_config.txt

# Enable core dumps in current directory
ulimit -c unlimited
export ASAN_OPTIONS=abort_on_error=1  # if binary was built with ASan

# Trap signals and log what killed us
CRASH_LOG="${SCRIPT_DIR}/crash.log"
_on_exit() {
    local exit_code=$?
    local signal=$1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXIT: code=${exit_code} signal=${signal}" | tee -a "${CRASH_LOG}"
    if [ "${exit_code}" -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] CRASH DETECTED. Checking for core dump..." | tee -a "${CRASH_LOG}"
        ls -lh "${SCRIPT_DIR}"/core* 2>/dev/null | tee -a "${CRASH_LOG}" || true
        journalctl -k --since "5 minutes ago" 2>/dev/null | grep -i "oom\|out of memory\|killed process" | tail -5 | tee -a "${CRASH_LOG}" || true
    fi
}
trap '_on_exit SIGTERM' TERM
trap '_on_exit SIGINT'  INT
trap '_on_exit SIGHUP'  HUP
trap '_on_exit EXIT'    EXIT

# Background memory monitor: log RSS every 30s to mem.log
MEM_LOG="${SCRIPT_DIR}/mem.log"
_mem_monitor() {
    local pid=$1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] START monitoring PID=$pid" >> "${MEM_LOG}"
    while kill -0 "$pid" 2>/dev/null; do
        local rss
        rss=$(awk '/VmRSS/{print $2}' /proc/"$pid"/status 2>/dev/null || echo "gone")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ns3 PID=$pid RSS=${rss}kB" >> "${MEM_LOG}"
        sleep 30
    done
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] STOP monitoring PID=$pid" >> "${MEM_LOG}"
}

${BIN:?} \
    --remote-memory-configuration=${MEMORY} \
    --logical-topology-configuration=${LOGICAL_TOPOLOGY} \
    --system-configuration=${SYSTEM} \
    --network-configuration=${NETWORK} \
    --workload-configuration=${WORKLOAD} \
    --comm-group-configuration=${COMM_GROUP_CONFIGURATION} &

NS3_PID=$!
_mem_monitor ${NS3_PID} &
MEM_MON_PID=$!

wait ${NS3_PID}
NS3_EXIT=$?
wait ${MEM_MON_PID} 2>/dev/null || true
exit ${NS3_EXIT}
