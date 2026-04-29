#!/bin/bash
DIR_LIST=(
    "in_dc"
    "in_dc_dp"
    "inter_dc"
    "inter_dc_dp"
    "inter_dc_dp_localsgd"
)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for dir in "${DIR_LIST[@]}"; do
    cd "$ROOT_DIR/$dir" || { echo "skip $dir (not found)"; continue; }
    echo "== launching $dir =="
    # for script in ns3.sh htsim.sh analytical.sh; do
    for script in htsim.sh analytical.sh; do
    # for script in analytical.sh; do
        if [[ -x "./$script" ]]; then
            log="${script%.sh}.log"
            nohup "./$script" > "$log" 2>&1 &
            # ./$script
            echo "  $dir/$script -> $log (pid $!)"
        fi
    done
    cd - > /dev/null
done

wait
echo "all done"
