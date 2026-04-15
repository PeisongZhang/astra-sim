import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import os
import argparse

def format_traffic_annotation(value_mb):
    if value_mb == 0:
        return "0"
    if value_mb >= 1e3:
        return f"{value_mb / 1e3:.1f}K"
    if value_mb >= 100:
        return f"{value_mb:.0f}"
    if value_mb >= 10:
        return f"{value_mb:.1f}"
    return f"{value_mb:.2f}"

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
    rows, cols = total_traffic_matrix_mb.shape
    cell_size_in = 0.9
    fig_width = min(max(10, cols * cell_size_in), 24)
    fig_height = min(max(8, rows * cell_size_in), 24)
    annot_font_size = max(6, min(10, 14 - max(rows, cols) // 2))
    annot_labels = np.vectorize(format_traffic_annotation)(total_traffic_matrix_mb)

    plt.figure(figsize=(fig_width, fig_height))
    sns.heatmap(
        total_traffic_matrix_mb,
        annot=annot_labels,
        fmt="",
        cmap='viridis',
        square=True,
        linewidths=0.5,
        cbar_kws={'label': 'Traffic Volume (MB)'},
        annot_kws={'size': annot_font_size}
    )
    plt.title('Total Traffic Matrix Heatmap (All Time Bins Summed)')
    plt.xlabel('Destination Node (Dst)')
    plt.ylabel('Source Node (Src)')
    plt.xticks(rotation=45, ha='right')
    plt.yticks(rotation=0)
    plt.tight_layout()
    
    out_heatmap = os.path.join(os.path.dirname(npy_path), 'total_traffic_heatmap.png')
    plt.savefig(out_heatmap, dpi=300, bbox_inches='tight')
    plt.close()
    print(f"Saved total traffic heatmap to {out_heatmap}")

if __name__ == "__main__":
    visualize_traffic()
