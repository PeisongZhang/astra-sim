#!/bin/bash
# Summarize the §11.6 acceptance result for gpt_39b_512_sharded.
# Writes a 1-page markdown to htsim_experiment/docs/acceptance_*.md and
# prints the ratio to stdout. Safe to re-run.
set -o pipefail
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
OUT_DIR="${OUT_DIR:-${PROJECT_DIR:?}/htsim_experiment/gpt_39b_512_sharded}"
CSV="${OUT_DIR}/run.csv"
ANALYTICAL=12382114950
if [ ! -f "${CSV}" ]; then
    echo "[summarize] no run.csv at ${CSV}" >&2
    exit 1
fi

max=$(tail -n +2 "${CSV}" | awk -F, '{if ($3+0 > max) max=$3+0} END{print max+0}')
all_finished=$(tail -n +2 "${CSV}" | awk -F, 'BEGIN{c=0} $2+0 == 256 && $5+0 == 0 {c++} END{print c}')
walls=$(tail -n +2 "${CSV}" | awk -F, 'NR==1{mx=$4+0} {if ($4+0 > mx) mx=$4+0} END{print mx+0}')

ratio="n/a"
pass_cycle="—"
pass_wall="—"
if [ "${max}" -gt 0 ]; then
    ratio=$(awk "BEGIN{printf \"%.4f\", ${max} / ${ANALYTICAL}}")
    pass_cycle=$(awk "BEGIN{r=${max} / ${ANALYTICAL}; print (r >= 0.9 && r <= 1.5) ? \"PASS\" : \"FAIL\"}")
    wall_ratio=$(awk "BEGIN{printf \"%.2f\", ${walls} * 1e9 / ${ANALYTICAL}}")
    pass_wall=$(awk "BEGIN{print (${walls} * 1e9 / ${ANALYTICAL} <= 3.0) ? \"PASS\" : \"FAIL\"}")
fi

echo "gpt_39b_512 sharded acceptance"
echo "  combined_max_cycle = ${max}"
echo "  analytical_baseline = ${ANALYTICAL}"
echo "  ratio = ${ratio}"
echo "  all_shards_finished_256 = ${all_finished}/2"
echo "  longest_shard_wall_sec = ${walls}"
echo "  §11.6 cycle [0.9, 1.5]: ${pass_cycle}"
echo "  §11.6 wall ≤ 3×: ${pass_wall}"
echo
echo "=== CSV ==="
cat "${CSV}"
