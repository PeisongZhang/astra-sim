#!/bin/bash
# 并行跑 analytical / htsim 两个 launcher，
# 各自的 stdout/stderr 走独立的 .log，spdlog 输出到独立的 log_<variant>/。
# 等所有 sim 自然结束后才退出。
set -u
SCRIPT_DIR=$(cd "$(dirname "$(realpath "$0")")" && pwd)
cd "${SCRIPT_DIR}"

TS=$(date +%Y%m%d_%H%M%S)

# 备份现有输出，避免覆盖之前成功的 run
for f in analytical.log htsim.log; do
    [ -e "$f" ] && mv "$f" "${f%.log}.${TS}.bak.log"
done
for d in log log_analytical log_htsim; do
    [ -d "$d" ] && mv "$d" "${d}.${TS}.bak"
done

# 并行启动
echo "[parallel] launching 2 sims..."
./analytical.sh > analytical.log 2>&1 &
PID_AN=$!
./htsim.sh      > htsim.log      2>&1 &
PID_HT=$!

echo "[parallel] PIDs: analytical=$PID_AN  htsim=$PID_HT"
echo "[parallel] waiting for all 2 to finish..."

declare -A RC
wait $PID_AN; RC[analytical]=$?
wait $PID_HT; RC[htsim]=$?

echo
echo "[parallel] === Exit codes ==="
for k in analytical htsim; do
    echo "  $k: ${RC[$k]}"
done

# 整体 status：任一非零即非零
overall=0
for v in "${RC[@]}"; do [ "$v" -ne 0 ] && overall=1; done
exit $overall
