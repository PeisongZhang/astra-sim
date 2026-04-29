#!/bin/bash
set -e
set -x

SCRIPT_DIR=$(dirname "$(realpath $0)")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
BIN="${SCRIPT_DIR:?}"/ns3

MEMORY="${SCRIPT_DIR:?}"/../config/no_memory_expansion.json
LOGICAL_TOPOLOGY="${SCRIPT_DIR:?}"/logical_topo.json
SYSTEM="${SCRIPT_DIR:?}"/astra_system.json
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_8b/attstandard_sgdlocal_layer32_iter8_batch128_micro2_seq8192_dp4_tp1_pp4_sp1_ep1"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"
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
