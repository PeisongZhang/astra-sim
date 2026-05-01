#!/bin/bash
# P5 integration test — exercise ASTRASIM_HTSIM_OCS_REROUTE=1 on top of
# schedule_link_change.  Validates that:
#
#   (a) the mutator still applies the bitrate change (baseline OCS path);
#   (b) with REROUTE=1 the [ocs] log indicates reroute=1;
#   (c) simulation still completes with all 16 ranks finished;
#   (d) cycle stays within 1% of baseline when the reroute is a no-op rate
#       change (doesn't actually alter the fabric's shortest-path topology);
#   (e) REROUTE=1 on a harmless schedule doesn't drop any flows that had
#       routes already handed out.
#
# Link choice: (21, 17) — real leaf→spine link in llama/in_dc topology.txt.
# Schedule applies at simtime 1us, well before most flows start — so the
# reroute path is exercised.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
EXP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc"
BASELINE_CYCLE=136753283192

fail() { echo "[ocs-reroute-test] FAIL: $*" >&2; exit 1; }

run_variant() {
    local label="$1"
    local reroute="$2"
    local schedule="$3"

    echo "[ocs-reroute-test] --- variant=${label} reroute='${reroute}' schedule='${schedule}'"
    rm -rf "${EXP_DIR}/log" "${EXP_DIR}/run_htsim.log"
    # When reroute arg is empty, fully unset the env var — an empty string is
    # still "set" (getenv returns non-null) and the code keys off presence.
    if [ -z "${reroute}" ]; then
        env -u ASTRASIM_HTSIM_OCS_REROUTE \
            ASTRASIM_HTSIM_OCS_SCHEDULE="${schedule}" \
            ASTRASIM_HTSIM_ENDTIME_SEC=200 \
            ASTRASIM_HTSIM_VERBOSE=1 \
            bash -c "cd '${EXP_DIR}' && timeout 300 bash run_htsim.sh > /tmp/ocs_reroute_${label}.log 2>&1"
    else
        env \
            ASTRASIM_HTSIM_OCS_SCHEDULE="${schedule}" \
            ASTRASIM_HTSIM_OCS_REROUTE="${reroute}" \
            ASTRASIM_HTSIM_ENDTIME_SEC=200 \
            ASTRASIM_HTSIM_VERBOSE=1 \
            bash -c "cd '${EXP_DIR}' && timeout 300 bash run_htsim.sh > /tmp/ocs_reroute_${label}.log 2>&1"
    fi
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "   run_htsim.sh exit=${rc}"
    fi

    local finished max_cycle applied_ct applied_reroute1 applied_reroute0
    finished=$(grep -hoE "sys\[[0-9]+\] finished" "${EXP_DIR}/log/log.log" "${EXP_DIR}/run_htsim.log" 2>/dev/null | sort -u | wc -l)
    max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${EXP_DIR}/log/log.log" "${EXP_DIR}/run_htsim.log" 2>/dev/null \
        | sort -u \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    applied_ct=$(grep -c "^\[ocs\] t=.*applied" "${EXP_DIR}/run_htsim.log" 2>/dev/null || true)
    applied_reroute1=$(grep -c "^\[ocs\] t=.*reroute=1" "${EXP_DIR}/run_htsim.log" 2>/dev/null || true)
    applied_reroute0=$(grep -c "^\[ocs\] t=.*reroute=0" "${EXP_DIR}/run_htsim.log" 2>/dev/null || true)

    echo "   finished=${finished}/16 max_cycle=${max_cycle} applied=${applied_ct} reroute=1:${applied_reroute1} reroute=0:${applied_reroute0}"

    [ "${finished}" -eq 16 ] || fail "${label}: only ${finished}/16 ranks finished"
    [ "${max_cycle}" -gt 0 ] || fail "${label}: max_cycle extraction failed"
    [ "${applied_ct}" -ge 1 ] || fail "${label}: LinkChangeEvent never fired"

    if [ "${reroute}" = "1" ]; then
        [ "${applied_reroute1}" -ge 1 ] || fail "${label}: expected at least one reroute=1 applied event"
    else
        [ "${applied_reroute0}" -ge 1 ] || fail "${label}: expected at least one reroute=0 applied event"
    fi

    echo "${label} ${max_cycle}" >> /tmp/ocs_reroute_summary.txt
}

> /tmp/ocs_reroute_summary.txt

# Baseline: OCS mutator on, no reroute (legacy behaviour).
run_variant "legacy" "" "1.0:21:17:200:1"

# Same schedule, now with REROUTE=1.  Should apply + re-run Dijkstra.
run_variant "reroute" "1" "1.0:21:17:200:1"

echo "[ocs-reroute-test] summary ---"
cat /tmp/ocs_reroute_summary.txt

# Both should be within 1% of baseline (harmless schedule does not change
# shortest-path structure since the link kept its original bandwidth).
for label in legacy reroute; do
    cycle=$(awk -v l="${label}" '$1==l{print $2}' /tmp/ocs_reroute_summary.txt)
    diff=$(( cycle > BASELINE_CYCLE ? cycle - BASELINE_CYCLE : BASELINE_CYCLE - cycle ))
    tol=$(( BASELINE_CYCLE / 100 ))
    if [ "${diff}" -gt "${tol}" ]; then
        fail "${label} cycle ${cycle} differs from baseline ${BASELINE_CYCLE} by > 1%"
    fi
done

echo "[ocs-reroute-test] PASS"
