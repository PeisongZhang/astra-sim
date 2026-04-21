"""Generate a hand-crafted 2-rank Chakra v0.0.4 workload used by
`run.sh` to validate Roofline per-op-type scaling (correctness_todo.md §4).

Rank 0: single COMP_NODE with op_category=GEMM (0).
Rank 1: single COMP_NODE with op_category=SOFTMAX (2).
Both nodes have identical num_ops & tensor_size so the elapsed-time ratio
directly reflects the peak-perf ratio configured in astra_system.json.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(
    0, os.path.abspath(os.path.join(_HERE, "../../../dnn_workload/symbolic_tensor_graph"))
)

from symbolic_tensor_graph.chakra.backends.chakra_00_4_backend.et_def.et_def_pb2 import (
    Node,
    AttributeProto,
    NodeType,
    GlobalMetadata,
)
from symbolic_tensor_graph.chakra.backends.chakra_00_4_backend.protolib import (
    encodeMessage,
)


def _make_gm():
    gm = GlobalMetadata()
    gm.attr.append(AttributeProto(name="schema", string_val="symbolic_tensor_network"))
    return gm


def _write_et(path, op_category, num_ops=int(1e12), tensor_size=int(1e6)):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        encodeMessage(f, _make_gm())
        n = Node()
        n.id = 1
        n.name = f"comp_cat{op_category}"
        n.type = NodeType.COMP_NODE
        n.attr.append(AttributeProto(name="num_ops", int64_val=num_ops))
        n.attr.append(AttributeProto(name="tensor_size", uint64_val=tensor_size))
        n.attr.append(AttributeProto(name="op_type", string_val="synthetic"))
        n.attr.append(AttributeProto(name="op_category", int32_val=op_category))
        n.attr.append(AttributeProto(name="is_cpu_op", int32_val=0))
        encodeMessage(f, n)


def main():
    out_dir = os.path.join(_HERE, "workload")
    os.makedirs(out_dir, exist_ok=True)
    # rank 0 → GEMM (cat 0), rank 1 → SOFTMAX (cat 2)
    _write_et(os.path.join(out_dir, "workload.0.et"), op_category=0)
    _write_et(os.path.join(out_dir, "workload.1.et"), op_category=2)
    # No collective ops → empty comm group file still required by CLI.
    with open(os.path.join(out_dir, "workload.json"), "w") as f:
        f.write("{}\n")
    print(f"wrote: {out_dir}")


if __name__ == "__main__":
    main()
