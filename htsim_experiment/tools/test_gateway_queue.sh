#!/bin/bash
# U8 integration test — GatewayQueue per-region.
#
# Uses llama/in_dc_htsim as base and adds a synthetic #REGIONS block that
# splits the topology into two regions.  Verifies:
#   1. The [generic] GatewayQueue stdout line is emitted and reports > 0
#      inter-region links when a #REGIONS block is present.
#   2. A run with the regions-split topology still produces 16/16 ranks
#      finished and a max-cycle within [0.9, 1.5] of the baseline
#      (llama/in_dc_htsim with lossless mode, no regions).
#   3. ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES env override takes effect (buffer
#      KB reported in the stdout line changes).

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
TOP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc"
TMP_BASE=/tmp/gateway_queue_test
BASELINE_CYCLE=136719260632  # observed llama/in_dc_htsim with lossless mode

fail() { echo "[gw-test] FAIL: $*" >&2; exit 1; }

# Build a topology.txt that is identical to the source but inserts a
# #REGIONS block splitting hosts 0..7 into region 0 and 8..15 into region 1.
# Switches 16..40 stay in region 0 by default (no annotation needed —
# switches don't emit "inter-region" detection by themselves; link endpoints
# are what matter, and we only check host endpoints).
build_split() {
    local src="$1" out="$2"
    awk 'BEGIN { done_regions=0 }
         NR==1 { print; next }
         NR==2 {
             print
             print "#REGIONS 2"
             # Split hosts: 0-7 region 0, 8-15 region 1.  Switches: all in 0.
             s=""
             for (i=0; i<8; i++) s = s i " 0 "
             for (i=8; i<16; i++) s = s i " 1 "
             print s
             next
         }
         { print }' "$src" > "$out"
}

run_variant() {
    local label="$1" topo="$2" gw_kb="${3:-}" log="${TMP_BASE}.${label}.log"
    rm -rf "${TOP_DIR}/log" "${TOP_DIR}/run_htsim.log"
    cp "${TOP_DIR}/topology.txt" "${TOP_DIR}/topology.txt.orig"
    cp "$topo" "${TOP_DIR}/topology.txt"

    local gw_env=""
    [ -n "${gw_kb}" ] && gw_env="ASTRASIM_HTSIM_GATEWAY_QUEUE_BYTES=$((gw_kb * 1024))"

    env ASTRASIM_HTSIM_ENDTIME_SEC=400 \
        ASTRASIM_HTSIM_QUEUE_TYPE=lossless \
        ${gw_env} \
        timeout 600 \
        bash -c "cd '${TOP_DIR}' && bash run_htsim.sh > '${log}' 2>&1" ; local rc=$?

    mv "${TOP_DIR}/topology.txt.orig" "${TOP_DIR}/topology.txt"

    local gw_line gw_count gw_kb_reported
    gw_line=$(grep -E "^\[generic\] GatewayQueue" "${log}" | head -1)
    gw_count=$(echo "${gw_line}" | awk '{print $3}')
    gw_kb_reported=$(echo "${gw_line}" | awk '{for(i=1;i<=NF;i++)if($i=="KB"){print prev;break} else prev=$i}')

    local finished max_cycle
    finished=$(grep -hoE "sys\[[0-9]+\] finished" "${TOP_DIR}/log/log.log" 2>/dev/null | sort -u | wc -l)
    max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${TOP_DIR}/log/log.log" 2>/dev/null \
        | sort -u \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    echo "   ${label}: rc=${rc} finished=${finished}/16 max_cycle=${max_cycle} gw=${gw_count:-none} gw_kb=${gw_kb_reported:-n/a}"
    if [ "${finished}" -ne 16 ]; then
        fail "${label}: only ${finished} ranks finished (log=${log})"
    fi
    echo "${label} ${max_cycle} ${gw_count:-0} ${gw_kb_reported:-0}" >> "${TMP_BASE}.summary"
}

> "${TMP_BASE}.summary"

ORIG_TOP="${TOP_DIR}/topology.txt"
SPLIT_TOP="${TMP_BASE}.split.topo"
build_split "${ORIG_TOP}" "${SPLIT_TOP}"

echo "[gw-test] 1) baseline: original topology (no #REGIONS → no gateway queues)"
run_variant "baseline" "${ORIG_TOP}"

echo "[gw-test] 2) split topology (#REGIONS 2; default GatewayQueue size)"
run_variant "split_default" "${SPLIT_TOP}"

echo "[gw-test] 3) split topology with GATEWAY_QUEUE_BYTES=8MB override"
run_variant "split_big" "${SPLIT_TOP}" 8192

echo "[gw-test] ---- summary ----"
cat "${TMP_BASE}.summary"

# Baseline: no regions → no gateway links → no stdout line → gw=0 captured.
BASE_GW=$(awk '$1=="baseline"{print $3}' "${TMP_BASE}.summary")
# Split default: must have > 0 inter-region links detected.
SPLIT_GW=$(awk '$1=="split_default"{print $3}' "${TMP_BASE}.summary")
SPLIT_KB=$(awk '$1=="split_default"{print $4}' "${TMP_BASE}.summary")
BIG_KB=$(awk '$1=="split_big"{print $4}' "${TMP_BASE}.summary")

if [ "${BASE_GW}" -ne 0 ]; then
    fail "baseline should report 0 gateway links, got ${BASE_GW}"
fi
if [ "${SPLIT_GW}" -eq 0 ]; then
    fail "split topology should report > 0 gateway links, got ${SPLIT_GW}"
fi
if [ "${SPLIT_KB}" -le 0 ]; then
    fail "split topology missing KB size report"
fi
if [ "${BIG_KB}" -le "${SPLIT_KB}" ]; then
    fail "big override (${BIG_KB} KB) should exceed default (${SPLIT_KB} KB)"
fi

# Acceptance cycle on split topology must still be within [0.9, 1.5] of baseline —
# gateway queue is strictly a larger buffer than default, so the cycle should
# be ~identical (or slightly better under congestion).
SPLIT_CYCLE=$(awk '$1=="split_default"{print $2}' "${TMP_BASE}.summary")
ratio_x100=$(awk -v a="${SPLIT_CYCLE}" -v b="${BASELINE_CYCLE}" 'BEGIN{printf "%d", 100*a/b}')
if [ "${ratio_x100}" -lt 90 ] || [ "${ratio_x100}" -gt 150 ]; then
    fail "split topology cycle ${SPLIT_CYCLE} ratio ${ratio_x100}/100 out of [0.9, 1.5] vs baseline ${BASELINE_CYCLE}"
fi

echo "[gw-test] PASS — split topo reports ${SPLIT_GW} gateway links, cycle ratio ${ratio_x100}/100 in [0.9, 1.5]"
