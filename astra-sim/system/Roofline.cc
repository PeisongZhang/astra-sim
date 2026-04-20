/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "astra-sim/system/Roofline.hh"

#include <algorithm>

using namespace std;
using namespace AstraSim;

Roofline::Roofline(double peak_perf) : peak_perf(peak_perf) {}

Roofline::Roofline(double bandwidth, double peak_perf)
    : bandwidth(bandwidth),
      peak_perf(peak_perf) {}

void Roofline::set_bandwidth(double bandwidth) {
    this->bandwidth = bandwidth;
}

void Roofline::set_achievable_fraction(double frac) {
    if (frac <= 0.0) {
        this->achievable_fraction = 1.0;
    } else {
        this->achievable_fraction = frac;
    }
}

double Roofline::get_perf(double operational_intensity) {
    const double bw = bandwidth * achievable_fraction;
    const double peak = peak_perf * achievable_fraction;
    return min(bw * operational_intensity, peak);
}
