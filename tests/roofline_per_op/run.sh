#!/bin/bash
#
# correctness_todo.md §4 validation (Python-driven, since there's no C++
# gtest infra): synthesise a 2-rank workload where rank 0 is pure-GEMM and
# rank 1 is pure-SOFTMAX with *identical* num_ops/tensor_size on every comp
# node, run the analytical simulator with peak-perf-per-op-category set so
# GEMM peak = 4x SOFTMAX peak, and assert rank-1 wall ≈ 4x rank-0 wall.
#
# If the Roofline per-op-type plumbing is broken (e.g. op_category attr
# ignored, or JSON not parsed), rank 0 and rank 1 will finish in the same
# time — the assertion catches this.
set -e
set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "${SCRIPT_DIR}"

/home/ps/sow/part2/astra-sim/.venv/bin/python ./gen_workload.py

ASTRA_SIM=/home/ps/sow/part2/astra-sim/build/astra_analytical/build/bin/AstraSim_Analytical_Congestion_Aware
if [ ! -x "${ASTRA_SIM}" ]; then
    /home/ps/sow/part2/astra-sim/build/astra_analytical/build.sh -t congestion_aware
fi

"${ASTRA_SIM}" \
    --workload-configuration="${SCRIPT_DIR}/workload/workload" \
    --comm-group-configuration="${SCRIPT_DIR}/workload/workload.json" \
    --system-configuration="${SCRIPT_DIR}/astra_system.json" \
    --remote-memory-configuration="${SCRIPT_DIR}/no_memory_expansion.json" \
    --network-configuration="${SCRIPT_DIR}/network.yml" \
    --num-queues-per-dim=1 \
    2>&1 | tee "${SCRIPT_DIR}/run.log"

/home/ps/sow/part2/astra-sim/.venv/bin/python ./assert_scaling.py
