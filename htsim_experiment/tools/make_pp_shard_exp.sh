#!/bin/bash
# Build a per-shard experiment directory from a base experiment + a shard's
# workload directory. Used by sharded_runner.sh for gpt_39b_512 and similar.
#
# Inputs:
#   --base-exp    path to an existing *_htsim experiment dir (source of
#                 astra_system.json, analytical_network.yml, topology.txt,
#                 no_memory_expansion.json). logical_topo.json will be
#                 regenerated from --shard-size.
#   --shard-wkld  path to a single shard's workload directory
#                 (produced by shard_workload_pp.py)
#   --shard-size  total ranks in this shard (e.g. 256 for pp=2 of a 512 exp)
#   --out         output experiment dir (will be created/overwritten)
#
# Produces <out>/{run_htsim.sh, astra_system.json, analytical_network.yml,
# topology.txt, no_memory_expansion.json, logical_topo.json}.

set -euo pipefail

base_exp=""
shard_wkld=""
shard_size=""
out_dir=""

while [ $# -gt 0 ]; do
    case "$1" in
        --base-exp) shift; base_exp="$1"; shift ;;
        --shard-wkld) shift; shard_wkld="$1"; shift ;;
        --shard-size) shift; shard_size="$1"; shift ;;
        --out) shift; out_dir="$1"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

for arg in base_exp shard_wkld shard_size out_dir; do
    if [ -z "${!arg}" ]; then echo "--${arg//_/-} is required" >&2; exit 2; fi
done
if [ ! -d "${base_exp}" ]; then echo "base-exp not a dir: ${base_exp}" >&2; exit 2; fi
if [ ! -d "${shard_wkld}" ]; then echo "shard-wkld not a dir: ${shard_wkld}" >&2; exit 2; fi

mkdir -p "${out_dir}"

cp "${base_exp}/astra_system.json" "${out_dir}/astra_system.json"
cp "${base_exp}/no_memory_expansion.json" "${out_dir}/no_memory_expansion.json"

# Extract a sub-topology with exactly `shard_size` hosts. The HTSim
# frontend asserts npus_count == topology.host_count, so we must build
# a matching smaller Clos (reachability-BFS keeps leaf/spine structure
# intact). Script lives alongside this one.
MKSCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
PROJECT_ROOT_ABS_EARLY=$(realpath "${MKSCRIPT_DIR}/../..")
PY_EARLY="${PROJECT_ROOT_ABS_EARLY}/.venv/bin/python"
"${PY_EARLY}" "${MKSCRIPT_DIR}/extract_sub_topology.py" \
    --in "${base_exp}/topology.txt" \
    --out "${out_dir}/topology.txt" \
    --keep-hosts "${shard_size}"
# Rewrite analytical_network.yml so npus_count matches the shard size.
# HTSim frontend uses YAML's npus_count (or topology-derived host count if
# the YAML lacks it) to decide how many Sys objects to instantiate. Base
# experiment's YAML is typically "Custom + topology_file" with no explicit
# npus_count, so the default would pick up the topology.txt's host count
# (e.g. 512). For a pp-shard we only want `shard_size` ranks.
src_yml="${base_exp}/analytical_network.yml"
dst_yml="${out_dir}/analytical_network.yml"
# Drop any pre-existing npus_count line, then append the shard-size one.
grep -vE '^[[:space:]]*npus_count:' "${src_yml}" > "${dst_yml}"
printf "npus_count: [ %s ]\n" "${shard_size}" >> "${dst_yml}"

# Regenerate logical_topo.json with shard-size as the single logical dim.
# Multi-dim experiments are rare in htsim runs (frontend reads dims from
# NetworkParser); flatten to 1D with the shard rank count.
cat > "${out_dir}/logical_topo.json" <<EOF
{
    "logical-dims": ["${shard_size}"]
}
EOF

# Materialize workload file references as a file beside the experiment so
# run_htsim.sh below stays short and env-override-friendly.
shard_wkld_abs=$(realpath "${shard_wkld}")
# Resolve astra-sim project root from THIS script's path (it lives under
# astra-sim/htsim_experiment/tools/). Bake the absolute ASTRA_SIM path
# into the generated run_htsim.sh so the shard exp dir can live anywhere.
MKSCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
PROJECT_ROOT_ABS=$(realpath "${MKSCRIPT_DIR}/../..")
ASTRA_SIM_ABS="${PROJECT_ROOT_ABS}/build/astra_htsim/build/bin/AstraSim_HTSim"

cat > "${out_dir}/run_htsim.sh" <<EOF
#!/bin/bash
set -o pipefail
SCRIPT_DIR=\$(dirname "\$(realpath "\$0")")
PROJECT_DIR="${PROJECT_ROOT_ABS}"
ASTRA_SIM="${ASTRA_SIM_ABS}"
WORKLOAD_DIR="\${WORKLOAD_DIR:-${shard_wkld_abs}}"
WORKLOAD="\${WORKLOAD_DIR}/workload"
COMM_GROUP="\${WORKLOAD_DIR}/workload.json"
SYSTEM="\${SCRIPT_DIR:?}/astra_system.json"
REMOTE_MEMORY="\${SCRIPT_DIR:?}/no_memory_expansion.json"
NETWORK="\${SCRIPT_DIR:?}/analytical_network.yml"
LOG_FILE="\${SCRIPT_DIR:?}/run_htsim.log"
PROTO="\${HTSIM_PROTO:-roce}"
export ASTRASIM_HTSIM_ENDTIME_SEC="\${ASTRASIM_HTSIM_ENDTIME_SEC:-1000}"
if [ ! -f "\${WORKLOAD_DIR}/workload.0.et" ]; then
    echo "[htsim] ERROR: workload.0.et not found in \${WORKLOAD_DIR}." >&2
    exit 1
fi
# Redirect stdout+stderr directly to the log; skipping tee avoids a
# shell-pipe buffer on the hot path (htsim emits per-flow diagnostics
# that otherwise slow down large-scale shards noticeably).
"\${ASTRA_SIM:?}" \\
    --workload-configuration="\${WORKLOAD}" \\
    --comm-group-configuration="\${COMM_GROUP}" \\
    --system-configuration="\${SYSTEM}" \\
    --remote-memory-configuration="\${REMOTE_MEMORY}" \\
    --network-configuration="\${NETWORK}" \\
    --htsim-proto="\${PROTO}" \\
    > "\${LOG_FILE}" 2>&1
exit \$?
EOF
chmod +x "${out_dir}/run_htsim.sh"

echo "[make_pp_shard_exp] wrote ${out_dir}"
