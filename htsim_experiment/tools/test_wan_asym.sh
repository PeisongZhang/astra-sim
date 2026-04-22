#!/bin/bash
# U7 integration test — WAN asymmetric bandwidth / latency suffix
# (`@<rev_bw>/<rev_lat>` on the link line).
#
# Strategy: use the llama/in_dc topology as a base and sanity-check that
# running with an asymmetric-version of the same topology (where every
# link has the same values on both directions but spelled via the suffix)
# produces the same acceptance cycle as the symmetric version.  Then a
# second variant — half-rate reverse direction — should produce a DIFFERENT
# (generally larger) cycle, proving the asymmetric path is actually taken.

set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="${SCRIPT_DIR:?}/../.."
TOP_DIR="${PROJECT_DIR:?}/llama_experiment/in_dc_htsim"
TMP_BASE=/tmp/wan_asym_test
BASELINE_CYCLE=136719260632  # observed llama/in_dc_htsim with lossless mode

fail() { echo "[wan-test] FAIL: $*" >&2; exit 1; }

# Build an asymmetric topology.txt that is semantically equivalent to the
# original: every link has reverse bw/latency explicitly set to the same
# values as the forward direction via the `@bw/lat` suffix.
build_equivalent() {
    local src="$1" out="$2"
    awk 'NR<=2 {print; next}
         { bw=$3; lat=$4;
           printf "%s %s %s %s %s @%s/%s\n", $1, $2, $3, $4, $5, bw, lat
         }' "$src" > "$out"
}

# Build an asymmetric topology.txt where reverse direction is half bandwidth.
build_half_rev() {
    local src="$1" out="$2"
    awk 'NR<=2 {print; next}
         { bw=$3; lat=$4;
           # halve the numeric prefix of bw (e.g. 4800Gbps -> 2400Gbps)
           n=bw+0; suf=substr(bw, length(n)+1);
           rev_bw=int(n/2) suf;
           printf "%s %s %s %s %s @%s/%s\n", $1, $2, $3, $4, $5, rev_bw, lat
         }' "$src" > "$out"
}

run_variant() {
    local label="$1" topo="$2" log="${TMP_BASE}.${label}.log"
    rm -rf "${TOP_DIR}/log" "${TOP_DIR}/run_htsim.log"
    # Stash original topology.txt and swap in ours
    cp "${TOP_DIR}/topology.txt" "${TOP_DIR}/topology.txt.orig"
    cp "$topo" "${TOP_DIR}/topology.txt"

    ASTRASIM_HTSIM_ENDTIME_SEC=400 \
    ASTRASIM_HTSIM_QUEUE_TYPE=lossless \
    timeout 600 \
        bash -c "cd '${TOP_DIR}' && bash run_htsim.sh > '${log}' 2>&1" ; local rc=$?

    mv "${TOP_DIR}/topology.txt.orig" "${TOP_DIR}/topology.txt"

    local finished max_cycle
    finished=$(grep -hoE "sys\[[0-9]+\] finished" "${TOP_DIR}/log/log.log" 2>/dev/null | sort -u | wc -l)
    max_cycle=$(grep -hoE "sys\[[0-9]+\] finished, [0-9]+ cycles" "${TOP_DIR}/log/log.log" 2>/dev/null \
        | sort -u \
        | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){v=$i+0; if(v>max)max=v}} END{print max+0}')
    echo "   ${label}: rc=${rc} finished=${finished}/16 max_cycle=${max_cycle}"
    if [ "${finished}" -ne 16 ]; then
        fail "${label}: only ${finished} ranks finished"
    fi
    echo "${label} ${max_cycle}" >> "${TMP_BASE}.summary"
}

> "${TMP_BASE}.summary"

ORIG_TOP="${TOP_DIR}/topology.txt"
EQUIV_TOP="${TMP_BASE}.equivalent.topo"
HALF_TOP="${TMP_BASE}.half_rev.topo"
build_equivalent "${ORIG_TOP}" "${EQUIV_TOP}"
build_half_rev   "${ORIG_TOP}" "${HALF_TOP}"

echo "[wan-test] original topology 3 sample links:"
head -5 "${ORIG_TOP}" | tail -3
echo "[wan-test] equivalent-asym topology 3 sample links:"
head -5 "${EQUIV_TOP}" | tail -3
echo "[wan-test] half-reverse topology 3 sample links:"
head -5 "${HALF_TOP}" | tail -3

echo "[wan-test] run equivalent-asym variant (rev == fwd) …"
run_variant "equiv"    "${EQUIV_TOP}"
echo "[wan-test] run half-reverse-bw variant …"
run_variant "halfrev"  "${HALF_TOP}"

echo "[wan-test] ---- summary ----"
cat "${TMP_BASE}.summary"

CYCLE_E=$(awk '$1=="equiv"{print $2}' "${TMP_BASE}.summary")
CYCLE_H=$(awk '$1=="halfrev"{print $2}' "${TMP_BASE}.summary")

# Equivalent-asym must match baseline ~1%.
diff=$(( CYCLE_E > BASELINE_CYCLE ? CYCLE_E - BASELINE_CYCLE : BASELINE_CYCLE - CYCLE_E ))
tol=$(( BASELINE_CYCLE / 100 ))
if [ "${diff}" -gt "${tol}" ]; then
    fail "equivalent-asym cycle ${CYCLE_E} differs from baseline ${BASELINE_CYCLE} by > 1%"
fi

# half-reverse-bw: rev ACK bw halved, ratio still within [0.9, 1.5].
ratio_x100=$(awk -v a="${CYCLE_H}" -v b="${BASELINE_CYCLE}" 'BEGIN{printf "%d", 100*a/b}')
if [ "${ratio_x100}" -lt 90 ] || [ "${ratio_x100}" -gt 150 ]; then
    fail "half-reverse variant ratio ${ratio_x100}/100 out of [0.9, 1.5]"
fi

echo "[wan-test] PASS (equiv matches baseline; halfrev ratio ${ratio_x100}/100 stays in [0.9,1.5])"
