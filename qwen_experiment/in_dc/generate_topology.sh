#!/bin/bash
python3 generate_topology.py \
  --gpus-per-nvlink-node 8 \
  --nvlink-node-count 16 \
  --nvlink-nodes-per-leaf 4 \
  --spine-count 1 \
  --gpu-nvswitch-bandwidth 4800Gbps \
  --gpu-nvswitch-latency 0.00015ms \
  --gpu-nicswitch-bandwidth 200Gbps \
  --gpu-nicswitch-latency 0.000001ms \
  --nicswitch-leaf-bandwidth 200Gbps \
  --nicswitch-leaf-latency 0.0005ms \
  --leaf-spine-bandwidth 6400Gbps \
  --leaf-spine-latency 0.0006ms \
  --output ./topology.txt