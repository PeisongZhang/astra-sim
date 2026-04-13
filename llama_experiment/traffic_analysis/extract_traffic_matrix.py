import struct
import numpy as np
import sys
import os
import argparse

def extract_traffic_matrix():
    parser = argparse.ArgumentParser(description='Extract traffic matrix from ns-3 trace.')
    parser.add_argument('--bin_us', type=int, default=50, help='Time bin size in microseconds (default: 50)')
    parser.add_argument('--trace', type=str, default="../../../../extern/network_backend/ns-3/scratch/output/mix.tr", help='Path to mix.tr')
    parser.add_argument('--output', type=str, default="traffic_matrix.npy", help='Path to output .npy')
    parser.add_argument('--view', type=str, choices=['sender', 'receiver'], default='sender', 
                        help='Perspective of traffic analysis: "sender" (injection time) or "receiver" (arrival time)')
    args = parser.parse_args()

    # File paths
    trace_file = args.trace
    output_file = args.output

    if not os.path.exists(trace_file):
        print(f"Error: Trace file not found at {trace_file}")
        return

    # Define event and node filtering based on view
    # In ns-3 trace (trace-format.h): 
    # Recv = 0, Enqu = 1, Dequ = 2, Drop = 3
    target_event = 2 if args.view == 'sender' else 0
    
    # Define struct format based on ns3::TraceFormat
    fmt = "=QHBBIIIHBBBB2xHHIQHH4x"
    struct_size = struct.calcsize(fmt)

    if struct_size != 56:
        print(f"Size mismatch: calculated {struct_size}, expected 56.")
        return

    time_bin_ns = args.bin_us * 1000 
    num_nodes = 16
    traffic_matrix = {} # Maps time_bin -> 16x16 np.array

    print(f"Parsing {trace_file} ({args.view} view) with {args.bin_us}us bins...")
    try:
        with open(trace_file, "rb") as f:
            # Parse SimSetting Header
            len_bytes = f.read(4)
            if not len_bytes:
                print("Error: Empty file or no header found.")
                return
            length = struct.unpack("=I", len_bytes)[0]
            for _ in range(length):
                f.read(11) 
            f.read(4) # win
            
            # Start parsing trace entries
            while True:
                data = f.read(struct_size)
                if not data or len(data) < struct_size:
                    break
                
                unpacked = struct.unpack(fmt, data)
                time_ns = unpacked[0]
                node = unpacked[1]
                sip = unpacked[5]
                dip = unpacked[6]
                event = unpacked[9]
                payload = unpacked[17]
                
                if event == target_event and payload > 0:
                    src_node = (sip >> 8) & 0xFF
                    dst_node = (dip >> 8) & 0xFF
                    
                    # Condition: 
                    # sender view: monitor node must be the source
                    # receiver view: monitor node must be the destination
                    is_correct_node = (node == src_node) if args.view == 'sender' else (node == dst_node)
                    
                    if is_correct_node:
                        bin_idx = time_ns // time_bin_ns
                        if bin_idx not in traffic_matrix:
                            traffic_matrix[bin_idx] = np.zeros((num_nodes, num_nodes), dtype=np.int64)
                        traffic_matrix[bin_idx][src_node][dst_node] += payload
    except Exception as e:
        print(f"Parsing error: {e}")
        return
        
    if not traffic_matrix:
        print("No payload data found.")
        return
        
    max_time_bin = max(traffic_matrix.keys())
    num_bins = max_time_bin + 1
    time_series_matrix = np.zeros((num_bins, num_nodes, num_nodes), dtype=np.int64)
    for t_bin, mat in traffic_matrix.items():
        time_series_matrix[t_bin] = mat
        
    np.save(output_file, time_series_matrix)
    print(f"Successfully saved 3D Traffic Matrix to {output_file}")
    print(f"Shape: {time_series_matrix.shape} (Time Bins x 16 x 16)")

if __name__ == "__main__":
    extract_traffic_matrix()
