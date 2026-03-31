import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import os
import argparse

def visualize_traffic():
    parser = argparse.ArgumentParser(description='Visualize traffic matrix.')
    parser.add_argument('--bin_us', type=int, default=50, help='Time bin size used during extraction (default: 50)')
    parser.add_argument('--input', type=str, default="traffic_matrix.npy", help='Path to input .npy')
    args = parser.parse_args()

    npy_path = args.input
    if not os.path.exists(npy_path):
        print(f"Error: {npy_path} not found.")
        return

    print(f"Loading {npy_path}...")
    data = np.load(npy_path)
    
    # --- 1. Line plot: Total traffic over time ---
    traffic_per_bin_mb = np.sum(data, axis=(1, 2)) / 1e6
    time_us = np.arange(len(traffic_per_bin_mb)) * args.bin_us
    
    plt.figure(figsize=(10, 6))
    plt.plot(time_us, traffic_per_bin_mb, marker='o', linestyle='-', color='b')
    plt.title(f'Total Network Traffic Over Time ({args.bin_us}μs Bins)')
    plt.xlabel('Time (μs)')
    plt.ylabel('Traffic Volume (MB)')
    plt.grid(True, linestyle='--', alpha=0.7)
    
    out_line = os.path.join(os.path.dirname(npy_path), 'traffic_over_time.png')
    plt.savefig(out_line, dpi=300, bbox_inches='tight')
    plt.close()
    print(f"Saved time-series plot to {out_line}")

    # --- 2. Heatmap: Total traffic between specific nodes ---
    total_traffic_matrix_mb = np.sum(data, axis=0) / 1e6
    plt.figure(figsize=(12, 10))
    sns.heatmap(total_traffic_matrix_mb, annot=True, fmt=".2f", cmap='viridis', cbar_kws={'label': 'Traffic Volume (MB)'})
    plt.title('Total Traffic Matrix Heatmap (All Time Bins Summed)')
    plt.xlabel('Destination Node (Dst)')
    plt.ylabel('Source Node (Src)')
    
    out_heatmap = os.path.join(os.path.dirname(npy_path), 'total_traffic_heatmap.png')
    plt.savefig(out_heatmap, dpi=300, bbox_inches='tight')
    plt.close()
    print(f"Saved total traffic heatmap to {out_heatmap}")

if __name__ == "__main__":
    visualize_traffic()
