#!/usr/bin/env python3
from itertools import combinations
from math import asin, cos, radians, sin, sqrt

DATACENTERS = {
    "杭州滨江": (30.2109815, 120.2072296),
    "宁波杭州湾": (30.3229199, 121.1972183),
    "上海临港": (30.9093062, 121.9257641),
    "苏州常熟": (31.6543, 120.7528),
    "嘉兴南湖": (30.7530, 120.7630),
    "上海松江": (31.0364, 121.2281),
}

LATENCY_NS_PER_M = 5.0
EARTH_RADIUS_M = 6_371_000.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    lat1_r, lon1_r = radians(lat1), radians(lon1)
    lat2_r, lon2_r = radians(lat2), radians(lon2)
    dlat = lat2_r - lat1_r
    dlon = lon2_r - lon1_r
    a = sin(dlat / 2) ** 2 + cos(lat1_r) * cos(lat2_r) * sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * asin(sqrt(a))


def main() -> None:
    print("数据中心A,数据中心B,距离(km),时延(ms)")
    for (name_a, (lat_a, lon_a)), (name_b, (lat_b, lon_b)) in combinations(
        DATACENTERS.items(), 2
    ):
        distance_m = haversine_m(lat_a, lon_a, lat_b, lon_b)
        latency_ms = (distance_m * LATENCY_NS_PER_M) / 1_000_000
        print(f"{name_a},{name_b},{distance_m / 1000:.3f},{latency_ms:.6f}")


if __name__ == "__main__":
    main()
