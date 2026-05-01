#!/bin/bash
# U2 skeleton — validate sharded_runner.sh spawn / collect / aggregate path
# on the N=1 trivial case (single shard = full unsharded workload).
# Must produce the same cycle as running run_htsim.sh directly.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
RUNNER="${SCRIPT_DIR:?}/sharded_runner.sh"
TOP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc"
OUT_CSV=/tmp/sharded_test_$$.csv
BASELINE_CYCLE=136168043798  # analytical llama/in_dc

fail() { echo "[sharded-test] FAIL: $*" >&2; exit 1; }

rm -rf "${TOP_DIR}/log" "${TOP_DIR}/sharded_runner.log"

timeout 300 "${RUNNER}" \
    --shards "${TOP_DIR}" \
    --out "${OUT_CSV}" \
    --endtime 300 \
    --proto roce \
    --queue lossless \
    > /tmp/sharded_test_$$.log 2>&1

rc=$?
[ "${rc}" -eq 0 ] || fail "sharded_runner.sh exited rc=${rc} (see /tmp/sharded_test_$$.log)"

echo "--- CSV ---"
cat "${OUT_CSV}"

finished=$(tail -n +2 "${OUT_CSV}" | awk -F, '{print $2}')
max_cycle=$(tail -n +2 "${OUT_CSV}" | awk -F, '{print $3}')

[ "${finished}" -eq 16 ] || fail "expected 16 finished, got ${finished}"
[ "${max_cycle}" -gt 0 ] || fail "max_cycle not populated"

ratio_x100=$(awk -v a="${max_cycle}" -v b="${BASELINE_CYCLE}" 'BEGIN{printf "%d", 100*a/b}')
if [ "${ratio_x100}" -lt 90 ] || [ "${ratio_x100}" -gt 150 ]; then
    fail "cycle ${max_cycle} ratio ${ratio_x100}/100 out of [0.9, 1.5]"
fi

echo "[sharded-test] PASS — N=1 shard runs 16/16, cycle=${max_cycle}, ratio=${ratio_x100}/100"
rm -f "${OUT_CSV}" "/tmp/sharded_test_$$.log"
