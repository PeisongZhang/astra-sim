import struct
import numpy as np
import sys
import os

def extract_traffic_matrix():
    # File paths
    trace_file = "extern/network_backend/ns-3/scratch/output/mix.tr"
    output_file = "experiment/run_scripts/ns3/traffic_matrix.npy"

    if not os.path.exists(trace_file):
        print(f"Error: Trace file not found at {trace_file}")
        return

    # Define struct format based on ns3::TraceFormat
    # uint64_t time(8), uint16_t node(2), uint8_t intf(1), uint8_t qidx(1)
    # uint32_t qlen(4), uint32_t sip(4), uint32_t dip(4), uint16_t size(2)
    # uint8_t l3Prot(1), uint8_t event(1), uint8_t ecn(1), uint8_t nodeType(1)
    # 2-byte padding
    # union { struct data { uint16_t sport(2), dport(2), uint32_t seq(4), uint64_t ts(8), uint16_t pg(2), payload(2) } }
    # 4-byte padding
    fmt = "=QHBBIIIHBBBB2xHHIQHH4x"
    struct_size = struct.calcsize(fmt)

    if struct_size != 56:
        print(f"Size mismatch: calculated {struct_size}, expected 56.")
        return

    time_bin_ns = 1000 # 1 microsecond time bins
    num_nodes = 16
    traffic_matrix = {} # Maps time_bin -> 16x16 np.array

    print(f"Parsing {trace_file}...")
    try:
        with open(trace_file, "rb") as f:
            # Parse SimSetting Header (Written by ns-3 script before TraceFormat starts)
            len_bytes = f.read(4)
            if not len_bytes:
                print("Error: Empty file or no header found.")
                return
            length = struct.unpack("=I", len_bytes)[0]
            
            # Skip port_speed maps in header (11 bytes per entry)
            for _ in range(length):
                f.read(11) 
            
            # Skip window bound in header (4 bytes)
            f.read(4) 
            
            # Start parsing trace event entries
            parsed_count = 0
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
                
                # event == 2 is Dequeue
                # payload > 0 ensures we capture actual data transfers
                if event == 2 and payload > 0:
                    src_node = (sip >> 8) & 0xFF
                    dst_node = (dip >> 8) & 0xFF
                    
                    # Ensure node == src_node to only capture payload leaving the sender's host NIC
                    if node == src_node:
                        bin_idx = time_ns // time_bin_ns
                        
                        if bin_idx not in traffic_matrix:
                            traffic_matrix[bin_idx] = np.zeros((num_nodes, num_nodes), dtype=np.int64)
                        
                        traffic_matrix[bin_idx][src_node][dst_node] += payload
                        
                parsed_count += 1
                if parsed_count % 1_000_000 == 0:
                    print(f"Parsed {parsed_count} packets...")

    except Exception as e:
        print(f"Parsing error: {e}")
        return
        
    print(f"Finished parsing. Found {len(traffic_matrix)} valid time bins.")

    # Convert the dictionary to a 3D tensor M(t)_{16 x 16}
    if not traffic_matrix:
        print("No payload data found.")
        return
        
    max_time_bin = max(traffic_matrix.keys())
    num_bins = max_time_bin + 1
    
    # Preallocate 3D array: [Time Bins, Src Node, Dst Node]
    time_series_matrix = np.zeros((num_bins, num_nodes, num_nodes), dtype=np.int64)
    
    for t_bin, mat in traffic_matrix.items():
        time_series_matrix[t_bin] = mat
        
    # Save as .npy
    np.save(output_file, time_series_matrix)
    print(f"Successfully saved 3D Traffic Matrix tensor to {output_file}")
    print(f"Shape: {time_series_matrix.shape} (Time x Src x Dst)")

    # Provide a simple summary of aggregate data
    total_data_mb = time_series_matrix.sum() / 1e6
    print(f"Total payload transferred: {total_data_mb:.2f} MB")

if __name__ == "__main__":
    extract_traffic_matrix()
