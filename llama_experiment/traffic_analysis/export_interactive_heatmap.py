import argparse
import json
import math
import os

import numpy as np


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Traffic Matrix Explorer</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #101418;
      --panel: #171d24;
      --panel-2: #1f2833;
      --text: #eef2f7;
      --muted: #a7b1bd;
      --accent: #4fc3f7;
      --border: #2c3845;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }

    .wrap {
      max-width: 1320px;
      margin: 0 auto;
      padding: 24px;
    }

    .toolbar {
      display: grid;
      grid-template-columns: auto auto 1fr auto auto auto;
      gap: 12px;
      align-items: center;
      margin-bottom: 18px;
    }

    button, input[type="range"], select {
      accent-color: var(--accent);
    }

    button {
      background: var(--panel-2);
      color: var(--text);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px 12px;
      cursor: pointer;
    }

    .stat {
      color: var(--muted);
      font-size: 14px;
      white-space: nowrap;
    }

    .frame {
      display: grid;
      grid-template-columns: minmax(720px, 1fr) 260px;
      gap: 18px;
      align-items: start;
    }

    .panel {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 14px;
    }

    canvas {
      width: 100%;
      height: auto;
      display: block;
      border-radius: 6px;
      background: #0d1117;
    }

    .legend {
      width: 100%;
      height: 18px;
      border-radius: 6px;
      margin: 8px 0 4px;
      background: linear-gradient(90deg, #440154 0%, #414487 20%, #2a788e 40%, #22a884 60%, #7ad151 80%, #fde725 100%);
    }

    .legend-labels {
      display: flex;
      justify-content: space-between;
      color: var(--muted);
      font-size: 12px;
    }

    .table {
      display: grid;
      grid-template-columns: auto auto;
      gap: 8px 12px;
      font-size: 14px;
    }

    .table .key {
      color: var(--muted);
    }

    .top-list {
      margin: 0;
      padding-left: 18px;
      color: var(--text);
      font-size: 14px;
    }

    .hint {
      color: var(--muted);
      font-size: 13px;
      margin-top: 10px;
    }

    @media (max-width: 1100px) {
      .toolbar {
        grid-template-columns: 1fr;
      }

      .frame {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="toolbar">
      <button id="playBtn">Play</button>
      <select id="speedSelect">
        <option value="900">0.5x</option>
        <option value="450" selected>1x</option>
        <option value="225">2x</option>
        <option value="120">4x</option>
      </select>
      <input id="slider" type="range" min="0" max="0" value="0" />
      <div id="frameLabel" class="stat"></div>
      <div id="binLabel" class="stat"></div>
      <div id="activityLabel" class="stat"></div>
    </div>

    <div class="frame">
      <div class="panel">
        <canvas id="heatmap" width="900" height="900"></canvas>
        <div class="legend"></div>
        <div class="legend-labels">
          <span>0 MB</span>
          <span id="legendMax"></span>
        </div>
      </div>

      <div class="panel">
        <div class="table">
          <div class="key">Source File</div><div id="sourceFile"></div>
          <div class="key">Input Bin</div><div id="inputBin"></div>
          <div class="key">Display Bin</div><div id="displayBin"></div>
          <div class="key">Frames</div><div id="frameCount"></div>
          <div class="key">Nodes</div><div id="nodeCount"></div>
          <div class="key">Peak Bin</div><div id="peakBin"></div>
          <div class="key">Total Volume</div><div id="totalVolume"></div>
        </div>
        <h3>Top Flows In Current Bin</h3>
        <ol id="topFlows" class="top-list"></ol>
        <div class="hint">Slider position maps to a display time bin. Values are aggregated traffic volume for that bin.</div>
      </div>
    </div>
  </div>

  <script>
    const DATA = __DATA__;

    const slider = document.getElementById('slider');
    const playBtn = document.getElementById('playBtn');
    const speedSelect = document.getElementById('speedSelect');
    const frameLabel = document.getElementById('frameLabel');
    const binLabel = document.getElementById('binLabel');
    const activityLabel = document.getElementById('activityLabel');
    const sourceFile = document.getElementById('sourceFile');
    const inputBin = document.getElementById('inputBin');
    const displayBin = document.getElementById('displayBin');
    const frameCount = document.getElementById('frameCount');
    const nodeCount = document.getElementById('nodeCount');
    const peakBin = document.getElementById('peakBin');
    const totalVolume = document.getElementById('totalVolume');
    const legendMax = document.getElementById('legendMax');
    const topFlows = document.getElementById('topFlows');

    const canvas = document.getElementById('heatmap');
    const ctx = canvas.getContext('2d');

    const nodeN = DATA.num_nodes;
    const marginLeft = 80;
    const marginTop = 50;
    const gridSize = 760;
    const cellSize = gridSize / nodeN;
    const maxMB = DATA.max_frame_value_mb || 1;

    slider.max = String(DATA.frames.length - 1);
    sourceFile.textContent = DATA.source_file;
    inputBin.textContent = DATA.input_bin_us.toLocaleString() + ' us';
    displayBin.textContent = DATA.display_bin_us.toLocaleString() + ' us';
    frameCount.textContent = DATA.frames.length.toLocaleString();
    nodeCount.textContent = String(DATA.num_nodes);
    peakBin.textContent = DATA.peak_bin_mb.toFixed(2) + ' MB';
    totalVolume.textContent = DATA.total_volume_mb.toFixed(2) + ' MB';
    legendMax.textContent = maxMB.toFixed(2) + ' MB';

    let playing = false;
    let timerId = null;

    function lerp(a, b, t) {
      return a + (b - a) * t;
    }

    function colorForValue(valueMB) {
      const stops = [
        [68, 1, 84],
        [65, 68, 135],
        [42, 120, 142],
        [34, 168, 132],
        [122, 209, 81],
        [253, 231, 37]
      ];
      const t = Math.max(0, Math.min(1, valueMB / maxMB));
      const scaled = t * (stops.length - 1);
      const idx = Math.min(stops.length - 2, Math.floor(scaled));
      const localT = scaled - idx;
      const c0 = stops[idx];
      const c1 = stops[idx + 1];
      const r = Math.round(lerp(c0[0], c1[0], localT));
      const g = Math.round(lerp(c0[1], c1[1], localT));
      const b = Math.round(lerp(c0[2], c1[2], localT));
      return `rgb(${r}, ${g}, ${b})`;
    }

    function buildMatrix(frame) {
      const matrix = Array.from({ length: nodeN }, () => Array(nodeN).fill(0));
      for (const entry of frame.cells) {
        const idx = entry[0];
        const value = entry[1];
        const src = Math.floor(idx / nodeN);
        const dst = idx % nodeN;
        matrix[src][dst] = value / 1000000;
      }
      return matrix;
    }

    function drawAxes() {
      ctx.fillStyle = '#eef2f7';
      ctx.font = '14px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';

      for (let i = 0; i < nodeN; i++) {
        const x = marginLeft + i * cellSize + cellSize / 2;
        const y = marginTop + i * cellSize + cellSize / 2;
        ctx.fillText(String(i), x, marginTop - 18);
        ctx.fillText(String(i), marginLeft - 24, y);
      }

      ctx.save();
      ctx.translate(26, marginTop + gridSize / 2);
      ctx.rotate(-Math.PI / 2);
      ctx.fillText('Source Node', 0, 0);
      ctx.restore();

      ctx.fillText('Destination Node', marginLeft + gridSize / 2, 20);
    }

    function renderFrame(index) {
      const frame = DATA.frames[index];
      const matrix = buildMatrix(frame);

      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = '#0d1117';
      ctx.fillRect(0, 0, canvas.width, canvas.height);

      drawAxes();

      for (let src = 0; src < nodeN; src++) {
        for (let dst = 0; dst < nodeN; dst++) {
          const value = matrix[src][dst];
          const x = marginLeft + dst * cellSize;
          const y = marginTop + src * cellSize;
          ctx.fillStyle = colorForValue(value);
          ctx.fillRect(x, y, cellSize - 1, cellSize - 1);

          if (cellSize >= 24 && value > 0) {
            ctx.fillStyle = value > maxMB * 0.45 ? '#ffffff' : '#111111';
            ctx.font = '10px sans-serif';
            ctx.fillText(value.toFixed(0), x + cellSize / 2, y + cellSize / 2);
          }
        }
      }

      frameLabel.textContent = `Frame ${index + 1} / ${DATA.frames.length}`;
      binLabel.textContent = `${(frame.start_us / 1000).toFixed(1)} ms - ${(frame.end_us / 1000).toFixed(1)} ms`;
      activityLabel.textContent = `Bin Volume ${frame.total_bytes_mb.toFixed(2)} MB`;

      topFlows.innerHTML = '';
      const flows = frame.top_flows.length ? frame.top_flows : [['No active flows', '', 0]];
      for (const item of flows) {
        const li = document.createElement('li');
        if (Array.isArray(item)) {
          li.textContent = `${item[0]} -> ${item[1]}: ${item[2].toFixed(2)} MB`;
        } else {
          li.textContent = item;
        }
        topFlows.appendChild(li);
      }
    }

    function stopPlayback() {
      playing = false;
      playBtn.textContent = 'Play';
      if (timerId !== null) {
        clearInterval(timerId);
        timerId = null;
      }
    }

    function startPlayback() {
      stopPlayback();
      playing = true;
      playBtn.textContent = 'Pause';
      timerId = setInterval(() => {
        let next = Number(slider.value) + 1;
        if (next >= DATA.frames.length) {
          next = 0;
        }
        slider.value = String(next);
        renderFrame(next);
      }, Number(speedSelect.value));
    }

    slider.addEventListener('input', () => {
      renderFrame(Number(slider.value));
    });

    playBtn.addEventListener('click', () => {
      if (playing) {
        stopPlayback();
      } else {
        startPlayback();
      }
    });

    speedSelect.addEventListener('change', () => {
      if (playing) {
        startPlayback();
      }
    });

    renderFrame(0);
  </script>
</body>
</html>
"""


def build_sparse_frames(data: np.ndarray, input_bin_us: int, aggregate: int) -> tuple[list[dict], float, float]:
    num_frames = math.ceil(data.shape[0] / aggregate)
    frames = []
    peak_bin_mb = 0.0
    max_cell_mb = 0.0

    for frame_idx in range(num_frames):
        start = frame_idx * aggregate
        end = min((frame_idx + 1) * aggregate, data.shape[0])
        frame = data[start:end].sum(axis=0)
        nonzero = np.argwhere(frame > 0)
        cells = []
        top = []

        if nonzero.size:
            values = []
            for src, dst in nonzero:
                value = int(frame[src, dst])
                cells.append([int(src) * frame.shape[0] + int(dst), value])
                values.append((value, int(src), int(dst)))
            values.sort(reverse=True)
            top = [[src, dst, value / 1e6] for value, src, dst in values[:8]]
            max_cell_mb = max(max_cell_mb, values[0][0] / 1e6)

        total_bytes = int(frame.sum())
        peak_bin_mb = max(peak_bin_mb, total_bytes / 1e6)
        frames.append(
            {
                "start_us": start * input_bin_us,
                "end_us": end * input_bin_us,
                "total_bytes_mb": total_bytes / 1e6,
                "cells": cells,
                "top_flows": top,
            }
        )

    return frames, peak_bin_mb, max_cell_mb


def export_html() -> None:
    parser = argparse.ArgumentParser(description="Export interactive traffic matrix heatmap HTML.")
    parser.add_argument("--input", type=str, required=True, help="Path to input .npy matrix")
    parser.add_argument("--output", type=str, required=True, help="Path to output .html")
    parser.add_argument("--input_bin_us", type=int, required=True, help="Time bin used by the input .npy")
    parser.add_argument("--aggregate", type=int, default=10, help="Number of input bins to aggregate per display frame")
    args = parser.parse_args()

    if not os.path.exists(args.input):
        raise FileNotFoundError(f"Input matrix not found: {args.input}")

    data = np.load(args.input, mmap_mode="r")
    frames, peak_bin_mb, max_cell_mb = build_sparse_frames(data, args.input_bin_us, args.aggregate)

    payload = {
        "source_file": os.path.basename(args.input),
        "input_bin_us": args.input_bin_us,
        "display_bin_us": args.input_bin_us * args.aggregate,
        "num_nodes": int(data.shape[1]),
        "frames": frames,
        "peak_bin_mb": peak_bin_mb,
        "max_frame_value_mb": max_cell_mb,
        "total_volume_mb": float(np.sum(data) / 1e6),
    }

    html = HTML_TEMPLATE.replace("__DATA__", json.dumps(payload, separators=(",", ":")))
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"Saved interactive heatmap HTML to {args.output}")
    print(f"Frames: {len(frames)}")
    print(f"Display bin: {payload['display_bin_us']} us")


if __name__ == "__main__":
    export_html()
