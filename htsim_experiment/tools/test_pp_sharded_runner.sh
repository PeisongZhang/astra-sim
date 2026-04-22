#!/bin/bash
# U2 smoke: build a tiny 8-NPU gpt_39b base experiment, split it PP=2 via
# shard_workload_pp.py, then run_pp_sharded.sh.  Verifies splitter +
# per-shard exp dir + parallel htsim launch + max_cycle aggregation.
#
# Uses the STG micro workload
# dnn_workload/megatron_gpt_39b/fused_standard_4_1_16_2_512_1f1b_v1_sgo1_ar1
# (8 ranks, DP=2 TP=2 PP=2).

set -o pipefail
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
WORKLOAD_DIR="${PROJECT_DIR:?}/../dnn_workload/megatron_gpt_39b/fused_standard_4_1_16_2_512_1f1b_v1_sgo1_ar1"

if [ ! -f "${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[test_pp_sharded] workload not found: ${WORKLOAD_DIR}" >&2
    exit 1
fi

TMP=$(mktemp -d)
# Uncomment for diagnostics — keep the temp dir on failure
# trap 'rm -rf "${TMP}"' EXIT

# Build a minimal 4-host test experiment (each shard has 4 ranks).
BASE="${TMP}/base_exp"
mkdir -p "${BASE}"
cat > "${BASE}/astra_system.json" <<'EOF'
{
    "scheduling-policy": "LIFO",
    "endpoint-delay": 10,
    "active-chunks-per-dimension": 2,
    "preferred-dataset-splits": 4,
    "all-reduce-implementation": ["ring"],
    "all-gather-implementation": ["ring"],
    "reduce-scatter-implementation": ["ring"],
    "all-to-all-implementation": ["direct"],
    "collective-optimization": "localBWAware",
    "local-mem-bw": 1560,
    "boost-mode": 0,
    "roofline-enabled": 1,
    "peak-perf": 312
}
EOF
cat > "${BASE}/no_memory_expansion.json" <<'EOF'
{"memory-type": "NO_MEMORY_EXPANSION"}
EOF
cat > "${BASE}/analytical_network.yml" <<'EOF'
topology: [ Custom ]
topology_file: "topology.txt"
EOF
# 4 hosts + 1 switch. 4 host→switch + 4 switch→host = 8 unidirectional links.
cat > "${BASE}/topology.txt" <<'EOF'
5 1 8
4
0 4 400Gbps 0.0005ms 0
1 4 400Gbps 0.0005ms 0
2 4 400Gbps 0.0005ms 0
3 4 400Gbps 0.0005ms 0
4 0 400Gbps 0.0005ms 0
4 1 400Gbps 0.0005ms 0
4 2 400Gbps 0.0005ms 0
4 3 400Gbps 0.0005ms 0
EOF

OUT="${TMP}/sharded_run"
echo "[test_pp_sharded] running pp_sharded on 8-NPU workload → ${OUT}"
bash "${SCRIPT_DIR}/run_pp_sharded.sh" \
    --base-exp "${BASE}" \
    --workload-dir "${WORKLOAD_DIR}" \
    --pp 2 --dp 2 --tp 2 \
    --out-dir "${OUT}" \
    --endtime 120
rc=$?

echo "---"
if [ ${rc} -ne 0 ]; then
    echo "[test_pp_sharded] FAIL — runner exited rc=${rc}"
    echo "--- shard 0 log tail ---"
    tail -30 "${OUT}/shard_0_exp/runner.log" 2>/dev/null || true
    echo "--- shard 1 log tail ---"
    tail -30 "${OUT}/shard_1_exp/runner.log" 2>/dev/null || true
    exit 1
fi

# Each shard should finish all 4 ranks.
awk -F, 'NR>1 {
    if ($2+0 != 4) { print "shard " $1 " finished " $2 " ranks (want 4)" > "/dev/stderr"; ok=0 }
    else ok=1
    total++; if (ok) good++
}
END {
    if (total != 2 || good != 2) { print "[test_pp_sharded] FAIL — some shard under-finished" > "/dev/stderr"; exit 1 }
}' "${OUT}/run.csv" || exit 1

echo "[test_pp_sharded] PASS — both shards finished 4/4 ranks. CSV:"
cat "${OUT}/run.csv"
