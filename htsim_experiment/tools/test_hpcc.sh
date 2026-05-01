#!/bin/bash
# U4 — HPCC integration test.  Verifies that --htsim-proto=hpcc runs end-to-end
# on llama/in_dc (16 NPU, multi-tier topology) and produces a cycle within
# §11.6 ratio [0.9, 1.5] of the analytical baseline.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
TOP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc"
TMP_LOG=/tmp/test_hpcc.log
BASELINE_CYCLE=136168043798  # analytical llama/in_dc

fail() { echo "[hpcc-test] FAIL: $*" >&2; exit 1; }

rm -rf "${TOP_DIR}/log" "${TOP_DIR}/run_htsim.log"

env HTSIM_PROTO=hpcc \
    ASTRASIM_HTSIM_ENDTIME_SEC=300 \
    timeout 600 \
    bash -c "cd '${TOP_DIR}' && bash run_htsim.sh > '${TMP_LOG}' 2>&1" ; rc=$?

[ "${rc}" -eq 0 ] || fail "run_htsim.sh exited with ${rc} (see ${TMP_LOG})"

grep -qE "\[hpcc\] actual nodes" "${TMP_LOG}" \
    || fail "missing [hpcc] actual nodes log line"
grep -qE "INT via LosslessOutputQueue" "${TMP_LOG}" \
    || fail "missing HPCC INT description log line"

finished=$(grep -hoE "sys\[[0-9]+\] finished" "${TOP_DIR}/log/log.log" 2>/dev/null | sort -u | wc -l)
max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${TOP_DIR}/log/log.log" 2>/dev/null \
    | sort -u \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')

[ "${finished}" -eq 16 ] || fail "only ${finished}/16 ranks finished"
[ "${max_cycle}" -gt 0 ] || fail "no max_cycle extracted"

ratio_x100=$(awk -v a="${max_cycle}" -v b="${BASELINE_CYCLE}" 'BEGIN{printf "%d", 100*a/b}')
if [ "${ratio_x100}" -lt 90 ] || [ "${ratio_x100}" -gt 150 ]; then
    fail "HPCC cycle ${max_cycle} ratio ${ratio_x100}/100 out of [0.9, 1.5] vs baseline ${BASELINE_CYCLE}"
fi

echo "[hpcc-test] PASS — hpcc proto runs 16/16, cycle=${max_cycle}, ratio=${ratio_x100}/100"
