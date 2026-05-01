#!/bin/bash
# U3 — DCQCN ECN marking test.
#
# Verifies:
#   1. --htsim-proto=dcqcn runs end-to-end on llama/in_dc (16 NPU);
#   2. [dcqcn] Note / [generic] DCQCN ECN marking log lines appear;
#   3. ASTRASIM_HTSIM_DCQCN_KMIN_KB / KMAX_KB are honored and reported;
#   4. cycle-accuracy is still within [0.9, 1.5] of analytical baseline.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
TOP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc"
TMP_LOG=/tmp/test_dcqcn.log
BASELINE_CYCLE=136168043798  # analytical llama/in_dc

fail() { echo "[dcqcn-test] FAIL: $*" >&2; exit 1; }

rm -rf "${TOP_DIR}/log" "${TOP_DIR}/run_htsim.log"

env HTSIM_PROTO=dcqcn \
    ASTRASIM_HTSIM_DCQCN_KMIN_KB=50 \
    ASTRASIM_HTSIM_DCQCN_KMAX_KB=500 \
    ASTRASIM_HTSIM_ENDTIME_SEC=200 \
    timeout 600 \
    bash -c "cd '${TOP_DIR}' && bash run_htsim.sh > '${TMP_LOG}' 2>&1" ; rc=$?

[ "${rc}" -eq 0 ] || fail "run_htsim.sh exited with ${rc} (see ${TMP_LOG})"

grep -qE "\[dcqcn\] Note:" "${TMP_LOG}" \
    || fail "missing [dcqcn] Note log line"
grep -qE "\[generic\] DCQCN ECN marking kmin=50KB kmax=500KB" "${TMP_LOG}" \
    || fail "missing [generic] DCQCN ECN marking log line with kmin=50KB kmax=500KB"

finished=$(grep -hoE "sys\[[0-9]+\] finished" "${TOP_DIR}/log/log.log" 2>/dev/null | sort -u | wc -l)
max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${TOP_DIR}/log/log.log" 2>/dev/null \
    | sort -u \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')

[ "${finished}" -eq 16 ] || fail "only ${finished}/16 ranks finished"
[ "${max_cycle}" -gt 0 ] || fail "no max_cycle extracted"

ratio_x100=$(awk -v a="${max_cycle}" -v b="${BASELINE_CYCLE}" 'BEGIN{printf "%d", 100*a/b}')
if [ "${ratio_x100}" -lt 90 ] || [ "${ratio_x100}" -gt 150 ]; then
    fail "DCQCN cycle ${max_cycle} ratio ${ratio_x100}/100 out of [0.9, 1.5] vs baseline ${BASELINE_CYCLE}"
fi

echo "[dcqcn-test] PASS — dcqcn proto runs 16/16, cycle=${max_cycle}, ratio=${ratio_x100}/100"
