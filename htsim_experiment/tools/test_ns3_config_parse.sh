#!/bin/bash
# U9 — unit test for ns3_config_to_htsim.py parser.
set -o pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
PARSER="${SCRIPT_DIR}/ns3_config_to_htsim.py"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "[ns3cfg-test] FAIL: $*" >&2; exit 1; }

# Fabricate a minimal ns3_config that exercises every mapping.
cat > "${TMP}/cfg.txt" <<'EOF'
ENABLE_QCN 1
USE_DYNAMIC_PFC_THRESHOLD 1
PACKET_PAYLOAD_SIZE 4096
CC_MODE 3
ENABLE_INT 1
BUFFER_SIZE 32
KMAX_MAP 2 200000000000 600 400000000000 1200
KMIN_MAP 2 200000000000 200 400000000000 400
PMAX_MAP 2 200000000000 0.2 400000000000 0.2
LINK_DOWN 0 0 0
LINK_DOWN 5000000 3 7
LINK_DOWN 10000000 4 8
ENABLE_TRACE 1
ACK_HIGH_PRIO 1
EOF

OUT=$(python3 "${PARSER}" "${TMP}/cfg.txt")
echo "--- parser output ---"
echo "${OUT}"
echo "--- assertions ---"

expect_line() {
    local pat="$1"
    echo "${OUT}" | grep -qE "${pat}" || fail "missing: ${pat}"
    echo "  ok: ${pat}"
}

expect_line "^export HTSIM_PROTO='hpcc'"
expect_line "^export ASTRASIM_HTSIM_QUEUE_TYPE='lossless'"
expect_line "^export ASTRASIM_HTSIM_PACKET_BYTES='4096'"
# 32 MB total / 16 ports = 2 MB per port
expect_line "^export ASTRASIM_HTSIM_QUEUE_BYTES='2097152'"
expect_line "^export ASTRASIM_HTSIM_KMAX_MAP='2 200000000000 600"
expect_line "^export ASTRASIM_HTSIM_KMIN_MAP='2 200000000000 200"
expect_line "^export ASTRASIM_HTSIM_PMAX_MAP='2 200000000000 0.2"
expect_line "^export ASTRASIM_HTSIM_LOGGERS='1'"
expect_line "^export ASTRASIM_HTSIM_ACK_HIGH_PRIO='1'"
# LINK_DOWN 5000000 → 5000 us; 10000000 → 10000 us.  Ignore the 0 0 0 placeholder.
expect_line "^export ASTRASIM_HTSIM_OCS_SCHEDULE='5000:3:7:0:0,10000:4:8:0:0'"

# CC_MODE=1 → dcqcn
cat > "${TMP}/cfg.txt" <<'EOF'
CC_MODE 1
EOF
OUT=$(python3 "${PARSER}" "${TMP}/cfg.txt")
echo "${OUT}" | grep -qE "^export HTSIM_PROTO='dcqcn'" \
    || fail "CC_MODE 1 should map to dcqcn"
echo "  ok: CC_MODE 1 -> dcqcn"

# CC_MODE=8 → tcp (DCTCP fallback)
cat > "${TMP}/cfg.txt" <<'EOF'
CC_MODE 8
EOF
OUT=$(python3 "${PARSER}" "${TMP}/cfg.txt")
echo "${OUT}" | grep -qE "^export HTSIM_PROTO='tcp'" \
    || fail "CC_MODE 8 should map to tcp"
echo "  ok: CC_MODE 8 -> tcp"

echo "[ns3cfg-test] PASS"
