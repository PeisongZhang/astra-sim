#!/bin/bash
set -o pipefail
set -x
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
ASTRA_SIM="${PROJECT_DIR:?}/build/astra_htsim/build/bin/AstraSim_HTSim"
if [ ! -x "${ASTRA_SIM}" ]; then
    bash "${PROJECT_DIR:?}/build/astra_htsim/build.sh" || exit 1
fi
WORKLOAD_DIR_DEFAULT="${PROJECT_DIR}/../dnn_workload/llama3_8b/attstandard_sgdlocal_layer32_iter8_batch128_micro2_seq8192_dp4_tp1_pp4_sp1_ep1"
WORKLOAD_DIR="${WORKLOAD_DIR:-${WORKLOAD_DIR_DEFAULT}}"
WORKLOAD="${WORKLOAD_DIR}/workload"
COMM_GROUP="${WORKLOAD_DIR}/workload.json"
SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/../config/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/analytical_network.yml"
PROTO="${HTSIM_PROTO:-roce}"
export ASTRASIM_HTSIM_ENDTIME_SEC="${ASTRASIM_HTSIM_ENDTIME_SEC:-0}"
# inter-DC LocalSGD 必须用 lossless (PFC) 队列：当前 csg-htsim 的 RoCE 实现没有 RTO timer，
# 完全靠 NACK 触发重传；如果反向路径上某个 NACK 自身被 drop，sender 永远不重传，
# 那条 flow 就 forever stuck，整个 rank 永远完不成 (hang 在最后几个 collective hop)。
# 跨 DC 1.1 ms RTT 下尤其容易触发。lossless 模式靠 PFC 反压消除 drop，根除该死锁。
export ASTRASIM_HTSIM_QUEUE_TYPE="${ASTRASIM_HTSIM_QUEUE_TYPE:-lossless}"
# WAN BDP ≈ 800Gbps × 1.1ms ≈ 110 MB；GatewayQueue 顶到 128 MB 容纳 BDP，
# 同时 topology.txt 里 4 条 WAN 链路必须带 'wan' link-type token，不然
# GenericCustomTopology 不会把它们识别为 inter-region link，这里的设置就不生效。
export ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES="${ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES:-$((128 * 1024 * 1024))}"
if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[htsim] ERROR: workload.0.et not found in ${WORKLOAD_DIR}." >&2
    exit 1
fi
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --htsim-proto="${PROTO}"
exit ${PIPESTATUS[0]}
