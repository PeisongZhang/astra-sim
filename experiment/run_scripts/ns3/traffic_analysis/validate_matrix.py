import numpy as np
import sys
import os
import argparse

def validate():
    parser = argparse.ArgumentParser(description='Validate traffic matrix total sum.')
    parser.add_argument('--input', type=str, default="traffic_matrix.npy", help='Path to traffic_matrix.npy')
    args = parser.parse_args()

    npy_path = args.input
    if not os.path.exists(npy_path):
        print(f"Error: {npy_path} not found.")
        return

    try:
        data = np.load(npy_path)
        total_bytes = np.sum(data)
        expected_bytes = 31457280
        
        print(f"File: {npy_path}")
        print(f"Loaded matrix shape: {data.shape}")
        print(f"Total Traffic (Calculated): {total_bytes:,} Bytes")
        print(f"Total Traffic (Expected)  : {expected_bytes:,} Bytes")
        
        if total_bytes == expected_bytes:
            print("\n✅ Verification PASSED: The total traffic matches the theoretical Ring All-Reduce value!")
        else:
            print("\n❌ Verification FAILED: Total traffic mismatch.")
            print(f"Difference: {total_bytes - expected_bytes:,} Bytes")
            
    except Exception as e:
        print(f"Error loading matrix: {e}")

if __name__ == "__main__":
    validate()
