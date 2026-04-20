#!/bin/bash
# End-to-end driver: generate workloads, build topologies, run analytical
# simulations for Megatron-LM 39.1B and 76.1B GPT, then produce report.
#
# Environment knobs:
#   SKIP_WORKLOAD=1      skip STG workload generation
#   SKIP_SIM=1           skip ASTRA-sim analytical runs
#   RUN_SERIAL=1         run the two simulations sequentially instead of in parallel
#   ONLY=39b|76b         run only one of the two

set -euo pipefail
SCRIPT_DIR=$(dirname "$(realpath "$0")")
WORKSPACE="${SCRIPT_DIR}/../.."
PY=/home/ps/sow/part2/astra-sim/.venv/bin/python

ONLY="${ONLY:-both}"

echo "======================================================================"
echo "[run_all] Megatron-LM 39.1B / 76.1B GPT simulation replication"
echo "[run_all] ONLY=${ONLY} SKIP_WORKLOAD=${SKIP_WORKLOAD:-0} SKIP_SIM=${SKIP_SIM:-0}"
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

# 2) Topology files (idempotent). We use 2-level (leaf + single fat spine)
#    rather than 3-level fat-tree — see analysis_report.md §7 for the measurement
#    showing 3-level slows things in the current analytical backend because of
#    deterministic single-path routing. The 3-level params are kept on the
#    builder for future work.
if [ ! -f "${SCRIPT_DIR}/gpt_39b_512/topology.txt" ]; then
    "${PY}" "${SCRIPT_DIR}/build_selene_topology.py" --num_nodes 64  \
        --spines_per_pod 1 --num_cores 0 --nodes_per_pod 64 \
        --leaf_spine_bw 1600Gbps \
        --out "${SCRIPT_DIR}/gpt_39b_512/topology.txt"
    cp "${SCRIPT_DIR}/gpt_39b_512/topology.txt" "${SCRIPT_DIR}/gpt_39b_512_noar/topology.txt"
fi
if [ ! -f "${SCRIPT_DIR}/gpt_76b_1024/topology.txt" ]; then
    "${PY}" "${SCRIPT_DIR}/build_selene_topology.py" --num_nodes 128 \
        --spines_per_pod 1 --num_cores 0 --nodes_per_pod 128 \
        --leaf_spine_bw 1600Gbps \
        --out "${SCRIPT_DIR}/gpt_76b_1024/topology.txt"
    cp "${SCRIPT_DIR}/gpt_76b_1024/topology.txt" "${SCRIPT_DIR}/gpt_76b_1024_noar/topology.txt"
fi

# 3) Analytical simulations
if [ "${SKIP_SIM:-0}" != "1" ]; then
    if [ "${RUN_SERIAL:-0}" = "1" ]; then
        [ "${ONLY}" = "both" -o "${ONLY}" = "39b" ] && bash "${SCRIPT_DIR}/gpt_39b_512/run_analytical.sh"
        [ "${ONLY}" = "both" -o "${ONLY}" = "76b" ] && bash "${SCRIPT_DIR}/gpt_76b_1024/run_analytical.sh"
    else
        PIDS=()
        if [ "${ONLY}" = "both" ] || [ "${ONLY}" = "39b" ]; then
            bash "${SCRIPT_DIR}/gpt_39b_512/run_analytical.sh"  & PIDS+=($!)
        fi
        if [ "${ONLY}" = "both" ] || [ "${ONLY}" = "76b" ]; then
            bash "${SCRIPT_DIR}/gpt_76b_1024/run_analytical.sh" & PIDS+=($!)
        fi
        FAIL=0
        for P in "${PIDS[@]}"; do
            wait "$P" || FAIL=$((FAIL+1))
        done
        if [ ${FAIL} -ne 0 ]; then
            echo "[run_all] ${FAIL} simulation(s) failed; continuing to report."
        fi
    fi
fi

# 4) Report
"${PY}" "${SCRIPT_DIR}/collect_and_compare.py"
echo "[run_all] done."
