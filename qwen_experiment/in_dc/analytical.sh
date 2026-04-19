#!/bin/bash
set -e
set -x

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."

# --- Log file (set up first so all output can be redirected) ---
timestamp=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${SCRIPT_DIR:?}/log"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR:?}/analytical_${timestamp}.log"

# Redirect all stdout/stderr (including `set -x` trace) to LOG_FILE.
exec > "${LOG_FILE}" 2>&1

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
WORKLOAD_DIR=${WORKLOAD_DIR:-"${SCRIPT_DIR:?}/workload"}
WORKLOAD_DIR=$(realpath "${WORKLOAD_DIR:?}")
WORKLOAD="${WORKLOAD_DIR:?}/workload"
COMM_GROUP="${WORKLOAD_DIR:?}/workload.json"

SYSTEM="${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="${SCRIPT_DIR:?}/network.yml"

# --- 系统层调度队列 ---
# NUM_QUEUES_PER_DIM  (CLI: --num-queues-per-dim, 默认 1)
#   每个网络维度上每个 NPU 的逻辑消息队列数量，控制系统层的调度粒度。
#   例如 2D 拓扑、num-queues-per-dim=2 时，每个 NPU 共有 2×2=4 个队列。
#   解析位置：astra-sim/network_frontend/analytical/common/CmdLineParser.cc。
NUM_QUEUES_PER_DIM="${ANALYTICAL_NUM_QUEUES_PER_DIM:-1}"

# --- Plan C 并行化调优参数（相同时间戳事件批量并行执行）---
# 解析型后端的事件队列实现在
# extern/network_backend/analytical/common/event-queue/EventQueue.cpp。
#
# ASTRA_EVENT_PARALLEL_THREADS
#   同一时间戳内 parallel-safe 事件派发所用的最大线程数；默认为机器的
#   hardware_concurrency，并被物理 CPU 核数截断。设为 1 即禁用并行，
#   回退到串行循环。本脚本额外将默认值限制在不超过 4，避免过度订阅。
#
# ASTRA_EVENT_PARALLEL_MIN_EVENTS
#   触发并行派发所需的最少连续 parallel-safe 事件数（默认 8）。连续
#   事件数小于该阈值时直接串行执行，避免线程池调度开销得不偿失。
#   DP 较重、单 timestamp 事件偏少的场景可将其调低到 4 或 2。
#
# ASTRA_EVENT_QUEUE_STATS
#   置 1 时，仿真结束后往 stderr 输出事件队列的运行统计：
#   schedule_calls / new_event_lists / proceed_calls / drained_batches /
#   drained_events / serial_events / parallel_safe_events / parallel_runs /
#   parallel_events / parallel_groups / max_queue_size / max_batch_size /
#   max_parallel_groups，用于诊断并行化实际收益。
#
# ASTRA_ANALYTICAL_TIMING
#   置 1 时，仿真结束后输出主仿真循环的墙钟耗时分解：construct_topology、
#   construct_systems、workload_fire、simulation_loop，且 simulation_loop
#   进一步拆成 proceed_ms / issue_dep_free_ms / schedule_stranded_ms，
#   同时打印 outer_iterations 与 proceed_calls，便于定位仿真瓶颈。
#   启用位置：network_frontend/analytical/congestion_aware/main.cc。
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
set +e
"${ASTRA_SIM:?}" \
    --workload-configuration="${WORKLOAD}" \
    --comm-group-configuration="${COMM_GROUP}" \
    --system-configuration="${SYSTEM}" \
    --remote-memory-configuration="${REMOTE_MEMORY}" \
    --network-configuration="${NETWORK}" \
    --num-queues-per-dim="${NUM_QUEUES_PER_DIM}"
SIM_EXIT=$?
set -e

if [ ${SIM_EXIT} -ne 0 ]; then
    echo "[ASTRA-sim] Warning: Simulator exited with code ${SIM_EXIT}."
fi

echo "[ASTRA-sim] Log saved to ${LOG_FILE}."
echo "[ASTRA-sim] Finished."
exit ${SIM_EXIT}
