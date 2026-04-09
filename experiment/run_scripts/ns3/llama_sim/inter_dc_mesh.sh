#!/bin/bash
set -e
set -x

SCRIPT_DIR=$(dirname "$(realpath $0)")
ASTRA_SIM_DIR="${SCRIPT_DIR:?}"/../../../..
EXAMPLES_DIR="${ASTRA_SIM_DIR:?}"/experiment
NS3_DIR="${ASTRA_SIM_DIR:?}"/extern/network_backend/ns-3

MEMORY="${EXAMPLES_DIR:?}"/remote_memory/analytical/no_memory_expansion.json
WORKLOAD_DIR="/home/ps/sow/part2/astra-sim_tutorials/micro2024/chakra-demo/demo3/llama"
WORKLOAD="${WORKLOAD_DIR}/llama"
COMM_GROUP_CONFIGURATION="${WORKLOAD_DIR}/llama.json"

LOGICAL_TOPOLOGY="${EXAMPLES_DIR:?}"/network/ns3/sample_16nodes_1D.json
SYSTEM="${EXAMPLES_DIR:?}"/system/native_collectives/Ring_4chunks.json

# NETWORK="${NS3_DIR:?}"/scratch/config/config_clos.txt
NETWORK="${EXAMPLES_DIR:?}/run_scripts/ns3/ns3_config/config/inter_dc_mesh.txt"


cd "${NS3_DIR}/build/scratch"

echo "Running simulation with WORKLOAD: ${WORKLOAD}"

./ns3.42-AstraSimNetwork-optimized \
    --workload-configuration=${WORKLOAD} \
    --system-configuration=${SYSTEM} \
    --network-configuration=${NETWORK} \
    --remote-memory-configuration=${MEMORY} \
    --logical-topology-configuration=${LOGICAL_TOPOLOGY} \
    --comm-group-configuration=${COMM_GROUP_CONFIGURATION}

cd "${SCRIPT_DIR:?}"
