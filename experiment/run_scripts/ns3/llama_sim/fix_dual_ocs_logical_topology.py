#!/usr/bin/env python3
"""
修复双OCS逻辑拓扑图的脚本
主要修复问题：
1. 链路时延标注和链路对应关系不清楚  
2. 连线交叉导致混乱
3. 时延标注太近，分不清对应哪条连线
"""

import matplotlib.pyplot as plt
import matplotlib.patches as patches
import numpy as np

# 设置字体以支持中文
plt.rcParams['font.sans-serif'] = ['SimHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

def create_fixed_dual_ocs_logical_topology():
    fig, ax = plt.subplots(1, 1, figsize=(14, 10))
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 10)
    ax.set_aspect('equal')
    ax.axis('off')
    
    # DC位置 - 重新布局避免交叉
    dc_positions = {
        'DC0': (2, 8),   # 上海临港 - 左上
        'DC1': (12, 8),  # 苏州常熟 - 右上  
        'DC2': (12, 2),  # 杭州滨江 - 右下
        'DC3': (2, 2)    # 宁波杭州湾 - 左下
    }
    
    # DC标签 - 英文简化版
    dc_labels = {
        'DC0': 'DC 0\nShanghai',
        'DC1': 'DC 1\nSuzhou', 
        'DC2': 'DC 2\nHangzhou',
        'DC3': 'DC 3\nNingbo'
    }
    
    # 绘制DC节点
    dc_circles = {}
    for dc_id, pos in dc_positions.items():
        circle = patches.Circle(pos, 0.8, facecolor='lightgreen', 
                               edgecolor='darkgreen', linewidth=2)
        ax.add_patch(circle)
        dc_circles[dc_id] = circle
        
        # DC标签
        ax.text(pos[0], pos[1], dc_labels[dc_id], 
                ha='center', va='center', fontsize=10, fontweight='bold')
    
    # 连接配置 - 每对DC的两条路径
    connections = [
        # DC0 ↔ DC1
        {
            'start': 'DC0', 'end': 'DC1',
            'path1': {'delay': '1.063ms', 'color': 'blue', 'style': '-'},
            'path2': {'delay': '0.751ms', 'color': 'red', 'style': '--'}
        },
        # DC0 ↔ DC2  
        {
            'start': 'DC0', 'end': 'DC2',
            'path1': {'delay': '0.964ms', 'color': 'blue', 'style': '-'},
            'path2': {'delay': '1.010ms', 'color': 'red', 'style': '--'}
        },
        # DC0 ↔ DC3
        {
            'start': 'DC0', 'end': 'DC3', 
            'path1': {'delay': '0.879ms', 'color': 'blue', 'style': '-'},
            'path2': {'delay': '0.737ms', 'color': 'red', 'style': '--'}
        },
        # DC1 ↔ DC2
        {
            'start': 'DC1', 'end': 'DC2',
            'path1': {'delay': '0.903ms', 'color': 'blue', 'style': '-'}, 
            'path2': {'delay': '1.081ms', 'color': 'red', 'style': '--'}
        },
        # DC1 ↔ DC3
        {
            'start': 'DC1', 'end': 'DC3',
            'path1': {'delay': '0.818ms', 'color': 'blue', 'style': '-'},
            'path2': {'delay': '0.808ms', 'color': 'red', 'style': '--'}
        },
        # DC2 ↔ DC3
        {
            'start': 'DC2', 'end': 'DC3',
            'path1': {'delay': '0.719ms', 'color': 'blue', 'style': '-'},
            'path2': {'delay': '1.067ms', 'color': 'red', 'style': '--'}
        }
    ]
    
    def get_connection_points(start_pos, end_pos, offset1, offset2):
        """计算连线的起点和终点，避开圆形节点"""
        dx = end_pos[0] - start_pos[0]
        dy = end_pos[1] - start_pos[1] 
        length = np.sqrt(dx**2 + dy**2)
        
        # 单位向量
        unit_x = dx / length
        unit_y = dy / length
        
        # 垂直方向的单位向量
        perp_x = -unit_y
        perp_y = unit_x
        
        # 从圆边缘开始和结束
        start1 = (start_pos[0] + 0.8 * unit_x + offset1 * perp_x,
                  start_pos[1] + 0.8 * unit_y + offset1 * perp_y)
        end1 = (end_pos[0] - 0.8 * unit_x + offset1 * perp_x, 
                end_pos[1] - 0.8 * unit_y + offset1 * perp_y)
                
        start2 = (start_pos[0] + 0.8 * unit_x + offset2 * perp_x,
                  start_pos[1] + 0.8 * unit_y + offset2 * perp_y)
        end2 = (end_pos[0] - 0.8 * unit_x + offset2 * perp_x,
                end_pos[1] - 0.8 * unit_y + offset2 * perp_y)
        
        return start1, end1, start2, end2
    
    # 绘制连线和标注
    for conn in connections:
        start_pos = dc_positions[conn['start']]
        end_pos = dc_positions[conn['end']]
        
        # 计算偏移量，使两条路径分开
        offset = 0.15
        start1, end1, start2, end2 = get_connection_points(
            start_pos, end_pos, -offset, offset)
        
        # 路径1 (蓝色实线 - via OCS1)
        ax.plot([start1[0], end1[0]], [start1[1], end1[1]], 
                color=conn['path1']['color'], linestyle=conn['path1']['style'],
                linewidth=2, label='Via OCS 1' if conn == connections[0] else "")
        
        # 路径2 (红色虚线 - via OCS2) 
        ax.plot([start2[0], end2[0]], [start2[1], end2[1]],
                color=conn['path2']['color'], linestyle=conn['path2']['style'], 
                linewidth=2, label='Via OCS 2' if conn == connections[0] else "")
        
        # 时延标注 - 根据连接类型智能调整位置避免重叠
        mid1_x = (start1[0] + end1[0]) / 2
        mid1_y = (start1[1] + end1[1]) / 2
        mid2_x = (start2[0] + end2[0]) / 2  
        mid2_y = (start2[1] + end2[1]) / 2
        
        # 计算基础偏移方向
        dx = end_pos[0] - start_pos[0]
        dy = end_pos[1] - start_pos[1]
        length = np.sqrt(dx**2 + dy**2)
        perp_x = -dy / length  # 垂直方向单位向量
        perp_y = dx / length
        
        # 根据具体连接调整偏移量和位置，避免重叠
        connection_key = f"{conn['start']}-{conn['end']}"
        
        if connection_key == "DC0-DC1":  # 水平连接，上下分离
            offset1, offset2 = 0.4, -0.4
            # 沿连线方向稍微偏移避免完全居中重叠
            mid1_x -= 0.8
            mid2_x += 0.8
            
        elif connection_key == "DC0-DC2":  # 对角连接（交叉线），移到靠近DC0的位置
            offset1, offset2 = 0.5, -0.5
            # 将标注移到连线的1/4位置（靠近DC0），远离交叉点
            mid1_x = start_pos[0] + (end_pos[0] - start_pos[0]) * 0.25
            mid1_y = start_pos[1] + (end_pos[1] - start_pos[1]) * 0.25
            mid2_x = start_pos[0] + (end_pos[0] - start_pos[0]) * 0.35  
            mid2_y = start_pos[1] + (end_pos[1] - start_pos[1]) * 0.35
            
        elif connection_key == "DC0-DC3":  # 垂直连接，左右分离
            offset1, offset2 = 0.6, -0.6
            mid1_y += 0.3
            mid2_y -= 0.3
            
        elif connection_key == "DC1-DC2":  # 垂直连接，左右分离
            offset1, offset2 = -0.6, 0.6
            mid1_y += 0.4
            mid2_y -= 0.4
            
        elif connection_key == "DC1-DC3":  # 对角连接（交叉线），移到靠近DC1的位置  
            offset1, offset2 = 0.7, -0.7
            # 将标注移到连线的1/4位置（靠近DC1），远离交叉点
            mid1_x = start_pos[0] + (end_pos[0] - start_pos[0]) * 0.25
            mid1_y = start_pos[1] + (end_pos[1] - start_pos[1]) * 0.25
            mid2_x = start_pos[0] + (end_pos[0] - start_pos[0]) * 0.35
            mid2_y = start_pos[1] + (end_pos[1] - start_pos[1]) * 0.35
            
        elif connection_key == "DC2-DC3":  # 水平连接，上下分离
            offset1, offset2 = -0.5, 0.5
            mid1_x += 0.7
            mid2_x -= 0.7
            
        elif connection_key == "DC2-DC3":  # 水平连接，上下分离
            offset1, offset2 = -0.5, 0.5
            mid1_x -= 0.6
            mid2_x += 0.6
            
        # 应用偏移
        label1_x = mid1_x + offset1 * perp_x
        label1_y = mid1_y + offset1 * perp_y
        label2_x = mid2_x + offset2 * perp_x  
        label2_y = mid2_y + offset2 * perp_y
        
        # 路径1标注 (蓝色) - 交换到第二条线位置以匹配线条颜色
        ax.text(label2_x, label2_y, conn['path1']['delay'],
                ha='center', va='center', fontsize=9, 
                bbox=dict(boxstyle='round,pad=0.3', facecolor='lightblue', alpha=0.9),
                color='darkblue', fontweight='bold')
                
        # 路径2标注 (红色) - 交换到第一条线位置以匹配线条颜色
        ax.text(label1_x, label1_y, conn['path2']['delay'],
                ha='center', va='center', fontsize=9,
                bbox=dict(boxstyle='round,pad=0.3', facecolor='lightcoral', alpha=0.9), 
                color='darkred', fontweight='bold')
    
    # 标题 - 避免中文字体问题
    ax.text(7, 9.5, 'Dual OCS Logical Topology', 
            ha='center', va='center', fontsize=16, fontweight='bold')
    
    # 说明文字 - 英文版
    explanation = """Network Properties:
• Blue solid lines: Path via OCS 1 (Jiaxing)
• Red dashed lines: Path via OCS 2 (Shanghai Songjiang)  
• Each DC pair has two redundant paths with different delays
• Link bandwidth: 400Gbps per physical link"""
    
    ax.text(7, 0.8, explanation, ha='center', va='center', fontsize=10,
            bbox=dict(boxstyle='round,pad=0.5', facecolor='lightyellow', alpha=0.8))
    
    # 图例
    ax.legend(loc='upper right', bbox_to_anchor=(0.98, 0.95))
    
    plt.tight_layout()
    return fig

if __name__ == "__main__":
    fig = create_fixed_dual_ocs_logical_topology()
    
    # 保存为SVG
    output_file = "dual_ocs_logical_topology_fixed.svg"
    plt.savefig(output_file, format='svg', dpi=300, bbox_inches='tight')
    
    # 也保存为PNG用于预览
    plt.savefig("dual_ocs_logical_topology_fixed.png", format='png', 
                dpi=300, bbox_inches='tight')
    
    print(f"修复后的图片已保存为: {output_file}")
    print("主要修复：")
    print("1. 重新布局DC位置，避免连线交叉")
    print("2. 每条连线的时延标注用不同颜色的背景框标出")
    print("3. 时延标注位置分离，清楚对应各自的连线")
    print("4. 添加了图例和说明文字")
    
    plt.show()