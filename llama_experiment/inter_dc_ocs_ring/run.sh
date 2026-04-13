#!/bin/bash
set -e
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

${BIN:?} \
    --remote-memory-configuration=${MEMORY} \
    --logical-topology-configuration=${LOGICAL_TOPOLOGY} \
    --system-configuration=${SYSTEM} \
    --network-configuration=${NETWORK} \
    --workload-configuration=${WORKLOAD} \
    --comm-group-configuration=${COMM_GROUP_CONFIGURATION}
