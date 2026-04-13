import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import seaborn as sns
import argparse
import os

def animate_traffic():
    parser = argparse.ArgumentParser(description='Animate traffic matrix over time.')
    parser.add_argument('--bin_us', type=int, default=50, help='Time bin size used during extraction (default: 50)')
    parser.add_argument('--input', type=str, default="traffic_matrix.npy", help='Path to input .npy')
    parser.add_argument('--output', type=str, default="traffic_animation.gif", help='Path to output .gif')
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"Error: {args.input} not found.")
        return

    # Load the traffic matrix
    data = np.load(args.input)
    num_steps = data.shape[0]

    fig, ax = plt.subplots(figsize=(8, 6))

    # Get global max for consistent colorbar, converted to Megabytes
    vmin = 0
    vmax = np.max(data) / (1024 * 1024)
    if vmax == 0: vmax = 1 # avoid colorbar issues

    # Create a separate axis for the colorbar
    cbar_ax = fig.add_axes([0.92, 0.15, 0.02, 0.7])
    sns.heatmap(np.zeros((data.shape[1], data.shape[2])), ax=ax, vmin=vmin, vmax=vmax, cmap='viridis', cbar_ax=cbar_ax)

    def animate(i):
        ax.clear()
        sns.heatmap(data[i] / (1024 * 1024), ax=ax, vmin=vmin, vmax=vmax, cmap='viridis', cbar=False)
        start_t = i * args.bin_us
        end_t = (i + 1) * args.bin_us
        ax.set_title(f'Traffic Matrix at Time Bin {i}\n({start_t} - {end_t} µs)')
        ax.set_xlabel('Destination Node')
        ax.set_ylabel('Source Node')
        plt.subplots_adjust(right=0.9)
        return ax,

    print(f"Generating animation with {num_steps} frames...")
    anim = animation.FuncAnimation(fig, animate, frames=num_steps, repeat=True)

    # Save as GIF
    anim.save(args.output, writer='pillow', fps=5)
    print(f"Animation saved as {args.output}")

if __name__ == "__main__":
    animate_traffic()
