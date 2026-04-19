#!/bin/bash
#
# 批量跑 qwen/in_dc 的 analytical 仿真，在不同 LAYER 下复用同一份 analytical.sh。
#
# 工作方式：
#   - 对每个 LAYER 计算对应的 workload 目录（默认匹配 dnn_workload/qwen_32b/
#     standard_standard_<LAYER>_1_128_2_4096），通过 WORKLOAD_DIR 环境变量
#     传给 analytical.sh；
#   - analytical.sh 自带以 timestamp 命名的日志，这里在每次运行结束后
#     把最新生成的 analytical_<ts>.log 重命名为
#     analytical_layer<LAYER>_<batch-ts>_<ts>.log，避免和历史日志/其他层混淆；
#   - 所有层跑完后，在 log/ 目录下再写一份 sweep_<batch-ts>_summary.log，
#     汇总每层的状态、wall time、日志路径。
#
# 用法：
#   bash run_all_layers.sh
#       # 默认 LAYERS=(4 8 16 32 64)
#
#   LAYERS="8 32 64" bash run_all_layers.sh
#       # 自定义层数子集（空格分隔）
#
#   WORKLOAD_ROOT=/path/to/workloads \
#   WORKLOAD_TEMPLATE="standard_standard_%LAYER%_1_128_2_4096" \
#       bash run_all_layers.sh
#       # 换一批 workload 目录（%LAYER% 会被替换）
#
#   STOP_ON_FAIL=1 bash run_all_layers.sh
#       # 遇到失败立即中止；默认是继续跑下一个 LAYER
#

set -u
set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
ANALYTICAL_SH="${SCRIPT_DIR:?}/analytical.sh"
LOG_DIR="${SCRIPT_DIR:?}/log"
mkdir -p "${LOG_DIR:?}"

if [ ! -x "${ANALYTICAL_SH}" ]; then
    echo "[sweep] ERROR: analytical.sh not found or not executable at ${ANALYTICAL_SH}" >&2
    exit 1
fi

# --- 参数 ---
if [ -n "${LAYERS:-}" ]; then
    # shellcheck disable=SC2206
    LAYERS_ARR=(${LAYERS})
else
    LAYERS_ARR=(4 8 16 32 64) ##################################################################################################################layer
fi
WORKLOAD_ROOT="${WORKLOAD_ROOT:-/home/ps/sow/part2/dnn_workload/qwen_32b}"
WORKLOAD_TEMPLATE="${WORKLOAD_TEMPLATE:-standard_standard_%LAYER%_1_128_2_4096}"
STOP_ON_FAIL="${STOP_ON_FAIL:-0}"

BATCH_TS=$(date +%Y%m%d_%H%M%S)
SUMMARY="${LOG_DIR}/sweep_${BATCH_TS}_summary.log"

log_summary() {
    printf '%s\n' "$*" | tee -a "${SUMMARY}"
}

log_summary "[sweep] batch timestamp : ${BATCH_TS}"
log_summary "[sweep] layers          : ${LAYERS_ARR[*]}"
log_summary "[sweep] workload root   : ${WORKLOAD_ROOT}"
log_summary "[sweep] workload tmpl   : ${WORKLOAD_TEMPLATE}"
log_summary "[sweep] analytical.sh   : ${ANALYTICAL_SH}"
log_summary "[sweep] stop_on_fail    : ${STOP_ON_FAIL}"
log_summary "[sweep] summary file    : ${SUMMARY}"

declare -A LAYER_STATUS
declare -A LAYER_WALL
declare -A LAYER_LOG
declare -A LAYER_ELAPSED

for LAYER in "${LAYERS_ARR[@]}"; do
    SUBDIR="${WORKLOAD_TEMPLATE//%LAYER%/${LAYER}}"
    WORKLOAD_DIR="${WORKLOAD_ROOT%/}/${SUBDIR}"
    log_summary ""
    log_summary "============================================================"
    log_summary "[sweep] LAYER=${LAYER}"
    log_summary "[sweep] workload = ${WORKLOAD_DIR}"

    if [ ! -d "${WORKLOAD_DIR}" ]; then
        log_summary "[sweep] SKIP: workload directory does not exist"
        LAYER_STATUS["${LAYER}"]="missing"
        LAYER_WALL["${LAYER}"]="-"
        LAYER_LOG["${LAYER}"]="-"
        LAYER_ELAPSED["${LAYER}"]="0"
        if [ "${STOP_ON_FAIL}" = "1" ]; then
            log_summary "[sweep] STOP_ON_FAIL=1, aborting."
            break
        fi
        continue
    fi

    # 记录调用前 log/ 下已有的 analytical_*.log，跑完后比对取新出现的那份
    PRE_LOGS_FILE="$(mktemp)"
    # shellcheck disable=SC2012
    ls -1 "${LOG_DIR}"/analytical_*.log 2>/dev/null | sort > "${PRE_LOGS_FILE}" || true

    START_TS=$(date +%s)
    set +e
    WORKLOAD_DIR="${WORKLOAD_DIR}" \
        bash "${ANALYTICAL_SH}"
    EC=$?
    set -e
    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    LAYER_ELAPSED["${LAYER}"]="${ELAPSED}"

    # 捕获 analytical.sh 本轮新生成的日志文件并重命名
    POST_LOGS_FILE="$(mktemp)"
    # shellcheck disable=SC2012
    ls -1 "${LOG_DIR}"/analytical_*.log 2>/dev/null | sort > "${POST_LOGS_FILE}" || true
    NEW_LOG="$(comm -13 "${PRE_LOGS_FILE}" "${POST_LOGS_FILE}" | tail -n 1 || true)"
    rm -f "${PRE_LOGS_FILE}" "${POST_LOGS_FILE}"

    if [ -n "${NEW_LOG}" ] && [ -f "${NEW_LOG}" ]; then
        BASENAME="$(basename "${NEW_LOG}")"
        # analytical_<ts>.log -> analytical_layer<LAYER>_<batch-ts>_<ts>.log
        RENAMED="${LOG_DIR}/${BASENAME/analytical_/analytical_layer${LAYER}_${BATCH_TS}_}"
        mv "${NEW_LOG}" "${RENAMED}"
        LAYER_LOG["${LAYER}"]="${RENAMED}"
    else
        LAYER_LOG["${LAYER}"]="<no log captured>"
    fi

    if [ "${EC}" -eq 0 ]; then
        LAYER_STATUS["${LAYER}"]="ok"
        if [ -f "${LAYER_LOG[${LAYER}]}" ]; then
            # 取 sys[0] 的 Wall time 作为代表值；若没有，再取最大 Wall time
            WALL=$(grep -E "sys\[0\], Wall time:" "${LAYER_LOG[${LAYER}]}" \
                   | awk -F'Wall time: *' '{print $NF}' | tr -d '[:space:]' | head -n1)
            if [ -z "${WALL}" ]; then
                WALL=$(grep -E ", Wall time:" "${LAYER_LOG[${LAYER}]}" \
                       | awk -F'Wall time: *' '{print $NF}' | sort -n | tail -n1 \
                       | tr -d '[:space:]')
            fi
            LAYER_WALL["${LAYER}"]="${WALL:--}"
        else
            LAYER_WALL["${LAYER}"]="-"
        fi
        log_summary "[sweep] LAYER=${LAYER} OK   elapsed=${ELAPSED}s  wall=${LAYER_WALL[${LAYER}]}  log=${LAYER_LOG[${LAYER}]}"
    else
        LAYER_STATUS["${LAYER}"]="fail(exit=${EC})"
        LAYER_WALL["${LAYER}"]="-"
        log_summary "[sweep] LAYER=${LAYER} FAIL exit=${EC}  elapsed=${ELAPSED}s  log=${LAYER_LOG[${LAYER}]}"
        if [ "${STOP_ON_FAIL}" = "1" ]; then
            log_summary "[sweep] STOP_ON_FAIL=1, aborting remaining layers."
            break
        fi
    fi
done

log_summary ""
log_summary "============================================================"
log_summary "[sweep] summary"
{
    printf "%-8s %-14s %-10s %-20s %s\n" "LAYER" "status" "elapsed_s" "wall_cycles" "log"
    for LAYER in "${LAYERS_ARR[@]}"; do
        printf "%-8s %-14s %-10s %-20s %s\n" \
            "${LAYER}" \
            "${LAYER_STATUS[${LAYER}]:-skipped}" \
            "${LAYER_ELAPSED[${LAYER}]:--}" \
            "${LAYER_WALL[${LAYER}]:--}" \
            "${LAYER_LOG[${LAYER}]:--}"
    done
} | tee -a "${SUMMARY}"

log_summary ""
log_summary "[sweep] done. summary written to ${SUMMARY}"

# 若任一层失败则整体返回非零，便于 CI 类场景判断
for LAYER in "${LAYERS_ARR[@]}"; do
    case "${LAYER_STATUS[${LAYER}]:-skipped}" in
        ok) ;;
        *) exit 2 ;;
    esac
done
exit 0
