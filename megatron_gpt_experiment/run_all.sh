#!/bin/bash
# End-to-end driver: generate workloads, build topologies, run analytical
# (and optionally htsim) simulations for Megatron-LM 39.1B and 76.1B GPT,
# then produce report.
#
# Environment knobs:
#   SKIP_WORKLOAD=1      skip STG workload generation
#   SKIP_SIM=1           skip ASTRA-sim runs
#   RUN_SERIAL=1         run simulations sequentially instead of in parallel
#   ONLY=39b|76b|both    limit to one model size (default: both)
#   RUN_HTSIM=1          also dispatch htsim.sh for *_htsim case dirs
#                        (off by default — htsim runs are expensive at 1024 GPUs)

set -euo pipefail
SCRIPT_DIR=$(dirname "$(realpath "$0")")
WORKSPACE="${SCRIPT_DIR}/../.."
PY=/home/ps/sow/part2/astra-sim/.venv/bin/python

ONLY="${ONLY:-both}"

echo "======================================================================"
echo "[run_all] Megatron-LM 39.1B / 76.1B GPT simulation replication"
echo "[run_all] ONLY=${ONLY} SKIP_WORKLOAD=${SKIP_WORKLOAD:-0} SKIP_SIM=${SKIP_SIM:-0} RUN_HTSIM=${RUN_HTSIM:-0}"
echo "======================================================================"

# 1) Workload generation (STG)
if [ "${SKIP_WORKLOAD:-0}" != "1" ]; then
    if [ "${ONLY}" = "both" ] || [ "${ONLY}" = "39b" ]; then
        echo "[run_all] Generating 39.1B workload..."
        bash "${WORKSPACE}/dnn_workload/megatron_gpt_39b/megatron_gpt_39b.sh"
    fi
    if [ "${ONLY}" = "both" ] || [ "${ONLY}" = "76b" ]; then
        echo "[run_all] Generating 76.1B workload..."
        bash "${WORKSPACE}/dnn_workload/megatron_gpt_76b/megatron_gpt_76b.sh"
    fi
fi

# 2) Topology files (idempotent). 2-level (leaf + single fat spine) — see
#    analysis_report.md §7 for why 3-level slows things in the current
#    analytical backend (deterministic single-path routing).
if [ ! -f "${SCRIPT_DIR}/gpt_39b_512/topology.txt" ]; then
    "${PY}" "${SCRIPT_DIR}/build_selene_topology.py" --num_nodes 64  \
        --spines_per_pod 1 --num_cores 0 --nodes_per_pod 64 \
        --leaf_spine_bw 1600Gbps \
        --out "${SCRIPT_DIR}/gpt_39b_512/topology.txt"
fi
if [ ! -f "${SCRIPT_DIR}/gpt_76b_1024/topology.txt" ]; then
    "${PY}" "${SCRIPT_DIR}/build_selene_topology.py" --num_nodes 128 \
        --spines_per_pod 1 --num_cores 0 --nodes_per_pod 128 \
        --leaf_spine_bw 1600Gbps \
        --out "${SCRIPT_DIR}/gpt_76b_1024/topology.txt"
fi

# 3) Build dispatch list as "case_dir:script_name" pairs. Both 39b and 76b
#    bundle AR-on/AR-off × analytical/htsim into one shared-config dir.
DISPATCH=()
if [ "${ONLY}" = "both" ] || [ "${ONLY}" = "39b" ]; then
    DISPATCH+=("gpt_39b_512:analytical.sh" "gpt_39b_512:analytical_noar.sh")
    if [ "${RUN_HTSIM:-0}" = "1" ]; then
        DISPATCH+=("gpt_39b_512:htsim.sh" "gpt_39b_512:htsim_noar.sh")
    fi
fi
if [ "${ONLY}" = "both" ] || [ "${ONLY}" = "76b" ]; then
    DISPATCH+=("gpt_76b_1024:analytical.sh" "gpt_76b_1024:analytical_noar.sh")
    if [ "${RUN_HTSIM:-0}" = "1" ]; then
        DISPATCH+=("gpt_76b_1024:htsim.sh" "gpt_76b_1024:htsim_noar.sh")
    fi
fi

# 4) Simulations — each entry runs <case_dir>/<script>, redirecting stdout+stderr
#    to <case_dir>/<script_basename>.log so collect_and_compare picks them up.
if [ "${SKIP_SIM:-0}" != "1" ]; then
    PIDS=()
    for entry in "${DISPATCH[@]}"; do
        dir="${entry%%:*}"
        script="${entry#*:}"
        case_dir="${SCRIPT_DIR}/${dir}"
        if [ ! -x "${case_dir}/${script}" ]; then
            echo "[run_all] skip ${dir}/${script} (not found or not executable)"
            continue
        fi
        log="${case_dir}/${script%.sh}.log"
        if [ "${RUN_SERIAL:-0}" = "1" ]; then
            ( cd "${case_dir}" && bash "./${script}" > "${log}" 2>&1 )
            echo "  ${dir}/${script} -> ${log} (rc=$?)"
        else
            ( cd "${case_dir}" && nohup bash "./${script}" > "${log}" 2>&1 ) &
            PIDS+=($!)
            echo "  ${dir}/${script} -> ${log} (pid $!)"
        fi
    done
    if [ "${#PIDS[@]}" -gt 0 ]; then
        FAIL=0
        for P in "${PIDS[@]}"; do
            wait "$P" || FAIL=$((FAIL+1))
        done
        if [ ${FAIL} -ne 0 ]; then
            echo "[run_all] ${FAIL} simulation(s) failed; continuing to report."
        fi
    fi
fi

# 5) Report
"${PY}" "${SCRIPT_DIR}/collect_and_compare.py"
echo "[run_all] done."
