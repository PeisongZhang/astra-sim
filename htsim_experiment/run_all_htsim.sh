#!/bin/bash
# Run every migrated *_htsim experiment.  Each one writes its own run_htsim.log;
# at the end we print a 3-backend comparison summary (analytical / ns3 / htsim).
set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/.."
REPORT="${SCRIPT_DIR:?}/run_all_report.csv"

EXPS=(
    # 16-NPU experiments (expected to pass §11.6 acceptance in RoCE mode
    # with ASTRASIM_HTSIM_QUEUE_TYPE=lossless).
    "qwen_experiment/ring_ag_htsim"
    "llama_experiment/in_dc"
    "llama_experiment/in_dc_dp"
    "llama_experiment/inter_dc"
    "llama_experiment/inter_dc_dp"
    "llama_experiment/inter_dc_dp_localsgd"
    "llama_experiment/inter_dc_mesh"
    "llama_experiment/inter_dc_ocs_mesh"
    "llama_experiment/inter_dc_ocs_ring"
    # ≥128-NPU experiments — BLOCKED on U2 (sharded parallel runner) due
    # to htsim single-threaded DES throughput wall.  Still launched so
    # the CSV shows the blocker state explicitly rather than being silent.
    "qwen_experiment/in_dc_htsim"
    "megatron_gpt_experiment/gpt_39b_512_htsim"
    "megatron_gpt_experiment/gpt_39b_512_noar_htsim"
    "megatron_gpt_experiment/gpt_76b_1024_htsim"
    "megatron_gpt_experiment/gpt_76b_1024_noar_htsim"
    "llama3_70b_experiment/in_dc"
    "llama3_70b_experiment/inter_dc_dp"
    "llama3_70b_experiment/inter_dc_dp_localsgd"
    "llama3_70b_experiment/inter_dc_pp"
)

# Default to lossless queue type so heterogeneous-fabric experiments
# (llama/qwen/gpt-76b-1024) avoid the RandomQueue drop-and-RTO pathology.
# Individual runners can still override by exporting a different value.
: "${ASTRASIM_HTSIM_QUEUE_TYPE:=lossless}"
: "${ASTRASIM_HTSIM_ENDTIME_SEC:=400}"
export ASTRASIM_HTSIM_QUEUE_TYPE ASTRASIM_HTSIM_ENDTIME_SEC

# Per-experiment wall-time budget (seconds).  Keep short so the full sweep
# terminates even when large experiments are blocked by U2.
: "${ASTRASIM_HTSIM_RUNALL_BUDGET:=300}"

echo "experiment,status,max_cycle_htsim,max_cycle_analytical,ratio,wall_sec" > "${REPORT}"

for exp in "${EXPS[@]}"; do
    # 兼容新旧两种命名：迁移后的目录用 htsim.sh，老目录还是 run_htsim.sh。
    runner=""
    for cand_runner in "${PROJECT_DIR}/${exp}/htsim.sh" "${PROJECT_DIR}/${exp}/run_htsim.sh"; do
        if [ -x "${cand_runner}" ]; then
            runner="${cand_runner}"
            break
        fi
    done
    if [ -z "${runner}" ]; then
        echo "[run_all] skipping ${exp} (no htsim.sh / run_htsim.sh)"
        echo "${exp},missing,,," >> "${REPORT}"
        continue
    fi
    t0=$(date +%s)
    echo "[run_all] running ${exp} via $(basename "${runner}")..."
    timeout "${ASTRASIM_HTSIM_RUNALL_BUDGET}" bash "${runner}" > /dev/null 2>&1
    rc=$?
    t1=$(date +%s)
    dt=$((t1 - t0))
    # spdlog 输出位置依赖于 runner：htsim.sh → log_htsim/log.log；run_htsim.sh → run_htsim.log 或 log/log.log。
    log="${PROJECT_DIR}/${exp}/run_htsim.log"
    log2="${PROJECT_DIR}/${exp}/log/log.log"
    log3="${PROJECT_DIR}/${exp}/log_htsim/log.log"
    htsim_max=""
    analytical_max=""
    ratio=""
    for cand in "${log}" "${log2}" "${log3}"; do
        if [ -f "${cand}" ]; then
            c=$(grep -Po "(?<=finished, )[0-9]+" "${cand}" 2>/dev/null | sort -n | tail -1)
            if [ -n "${c}" ] && { [ -z "${htsim_max}" ] || [ "${c}" -gt "${htsim_max}" ]; }; then
                htsim_max="${c}"
            fi
        fi
    done
    base="${exp%_htsim}"
    for baselog in "${PROJECT_DIR}/${base}/run_analytical.log" "${PROJECT_DIR}/${base}/run.log" "${PROJECT_DIR}/${exp}/log_analytical/log.log"; do
        if [ -f "${baselog}" ]; then
            analytical_max=$(grep -Po "(?<=finished, )[0-9]+" "${baselog}" 2>/dev/null | sort -n | tail -1)
            [ -n "${analytical_max}" ] && break
        fi
    done
    if [ -n "${htsim_max}" ] && [ -n "${analytical_max}" ] && [ "${analytical_max}" != "0" ]; then
        ratio=$(awk -v h="${htsim_max}" -v a="${analytical_max}" 'BEGIN{printf "%.3f", h/a}')
    fi
    if [ ${rc} -eq 0 ] && [ -n "${htsim_max}" ]; then
        status=ok
    else
        status=fail
    fi
    echo "${exp},${status},${htsim_max},${analytical_max},${ratio},${dt}" >> "${REPORT}"
    echo "[run_all] ${exp} → ${status} htsim=${htsim_max} analytical=${analytical_max} ratio=${ratio} wall=${dt}s"
done

echo
echo "[run_all] Report written to ${REPORT}"
column -s, -t "${REPORT}"
