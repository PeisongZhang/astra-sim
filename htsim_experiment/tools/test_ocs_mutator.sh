#!/bin/bash
# U6 integration test — exercise GenericCustomTopology::schedule_link_change
# via ASTRASIM_HTSIM_OCS_SCHEDULE on the llama/in_dc experiment.
#
# Validates:
#   (a) schedule_link_change accepts the edge (prints "[ocs] scheduled").
#   (b) LinkChangeEvent::doNextEvent fires at the scheduled simtime
#       (prints "[ocs] t=... applied").
#   (c) Simulation still completes with all 16 ranks finished.
#   (d) Harmless schedule (re-set rate to current value) matches baseline
#       cycle count within 1%.
#
# Link choice: (21, 17) — real leaf→spine link in llama/in_dc topology.txt.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
EXP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc_htsim"
BASELINE_CYCLE=136753283192

fail() { echo "[ocs-test] FAIL: $*" >&2; exit 1; }

run_variant() {
    local label="$1"
    local schedule="$2"

    echo "[ocs-test] --- variant=${label} schedule='${schedule}'"
    rm -rf "${EXP_DIR}/log" "${EXP_DIR}/run_htsim.log"
    ASTRASIM_HTSIM_OCS_SCHEDULE="${schedule}" \
    ASTRASIM_HTSIM_ENDTIME_SEC=200 \
    ASTRASIM_HTSIM_VERBOSE=1 \
    bash -c "cd '${EXP_DIR}' && timeout 300 bash run_htsim.sh > /tmp/ocs_test_${label}.log 2>&1"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "   run_htsim.sh exit=${rc}"
    fi

    local finished max_cycle sched_ct applied_ct
    finished=$(grep -hoE "sys\[[0-9]+\] finished" "${EXP_DIR}/log/log.log" "${EXP_DIR}/run_htsim.log" 2>/dev/null | sort -u | wc -l)
    max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${EXP_DIR}/log/log.log" "${EXP_DIR}/run_htsim.log" 2>/dev/null \
        | sort -u \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    sched_ct=$(grep -c "^\[ocs\] scheduled" "${EXP_DIR}/run_htsim.log" 2>/dev/null || true)
    applied_ct=$(grep -c "^\[ocs\] t=.*applied" "${EXP_DIR}/run_htsim.log" 2>/dev/null || true)

    echo "   finished=${finished}/16 max_cycle=${max_cycle} scheduled=${sched_ct} applied=${applied_ct}"

    [ "${finished}" -eq 16 ] || fail "${label}: only ${finished} ranks finished"
    [ "${max_cycle}" -gt 0 ] || fail "${label}: max_cycle extraction failed"
    [ "${sched_ct}" -ge 1 ] || fail "${label}: topology did not accept the mutator schedule"
    [ "${applied_ct}" -ge 1 ] || fail "${label}: LinkChangeEvent never fired"

    # Stash results for caller.
    echo "${label} ${max_cycle} ${applied_ct}" >> /tmp/ocs_test_summary.txt
}

> /tmp/ocs_test_summary.txt

# Harmless — re-set link to its current rate.  Validates that the full
# schedule→LinkChangeEvent→setBitrate path runs and doesn't perturb results.
run_variant "harmless" "1.0:21:17:200:1"

# Two-event schedule — harmless up-then-up (cycles through the queue setBitrate
# path twice, exercising the event ordering in EventList).  Still harmless so
# RandomQueue doesn't fall into a drop/RTO loop; that's U1's territory.
run_variant "double"   "1.0:21:17:200:1,10.0:21:17:200:1"

echo "[ocs-test] summary ---"
cat /tmp/ocs_test_summary.txt

# Harmless must match baseline within 1%.
CYCLE_A=$(awk '$1=="harmless"{print $2}' /tmp/ocs_test_summary.txt)
diff=$(( CYCLE_A > BASELINE_CYCLE ? CYCLE_A - BASELINE_CYCLE : BASELINE_CYCLE - CYCLE_A ))
tol=$(( BASELINE_CYCLE / 100 ))
if [ "${diff}" -gt "${tol}" ]; then
    fail "harmless cycle ${CYCLE_A} differs from baseline ${BASELINE_CYCLE} by > 1%"
fi

APPLIED_B=$(awk '$1=="double"{print $3}' /tmp/ocs_test_summary.txt)
[ "${APPLIED_B}" -ge 2 ] || fail "double variant should have applied 2 events, got ${APPLIED_B}"

echo "[ocs-test] PASS"
echo ""
echo "[ocs-test] NOTE: A more aggressive test variant (e.g. cut50/down_up)"
echo "           exposes RandomQueue's drop-and-RTO pathology (§13.5 P2)."
echo "           Those tests should be re-enabled once U1 (LosslessQueue"
echo "           / PFC backpressure) lands."
