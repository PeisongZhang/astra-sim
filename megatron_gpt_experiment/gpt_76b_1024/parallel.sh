#!/bin/bash
# 并行跑 4 个 launcher (analytical / analytical_noar / htsim / htsim_noar)，
# 各自的 stdout/stderr 走独立的 .log，spdlog 输出到独立的 log_<variant>/。
# 等所有 sim 自然结束后才退出。
set -u
SCRIPT_DIR=$(cd "$(dirname "$(realpath "$0")")" && pwd)
cd "${SCRIPT_DIR}"

TS=$(date +%Y%m%d_%H%M%S)

# 备份现有输出，避免覆盖之前成功的 run
for f in analytical.log analytical_noar.log htsim.log htsim_noar.log; do
    [ -e "$f" ] && mv "$f" "${f%.log}.${TS}.bak.log"
done
for d in log log_analytical log_analytical_noar log_htsim log_htsim_noar; do
    [ -d "$d" ] && mv "$d" "${d}.${TS}.bak"
done

# 并行启动
echo "[parallel] launching 4 sims..."
./analytical.sh      > analytical.log      2>&1 &
PID_AN=$!
./analytical_noar.sh > analytical_noar.log 2>&1 &
PID_AN_NOAR=$!
./htsim.sh           > htsim.log           2>&1 &
PID_HT=$!
./htsim_noar.sh      > htsim_noar.log      2>&1 &
PID_HT_NOAR=$!

echo "[parallel] PIDs: analytical=$PID_AN  analytical_noar=$PID_AN_NOAR  htsim=$PID_HT  htsim_noar=$PID_HT_NOAR"
echo "[parallel] waiting for all 4 to finish..."

declare -A RC
wait $PID_AN;       RC[analytical]=$?
wait $PID_AN_NOAR;  RC[analytical_noar]=$?
wait $PID_HT;       RC[htsim]=$?
wait $PID_HT_NOAR;  RC[htsim_noar]=$?

echo
echo "[parallel] === Exit codes ==="
for k in analytical analytical_noar htsim htsim_noar; do
    echo "  $k: ${RC[$k]}"
done

# 整体 status：任一非零即非零
overall=0
for v in "${RC[@]}"; do [ "$v" -ne 0 ] && overall=1; done
exit $overall
