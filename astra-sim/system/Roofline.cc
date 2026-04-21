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

void Roofline::set_peak_per_category(int op_category, double peak) {
    if (peak > 0.0) {
        this->peak_per_category[op_category] = peak;
    }
}

bool Roofline::has_per_category_peaks() const {
    return !this->peak_per_category.empty();
}

double Roofline::get_peak_for_category(int op_category) const {
    auto it = this->peak_per_category.find(op_category);
    const double raw =
        (it != this->peak_per_category.end()) ? it->second : this->peak_perf;
    return raw * this->achievable_fraction;
}

double Roofline::get_perf(double operational_intensity) {
    return this->get_perf(operational_intensity, kOpCatUnknown);
}

double Roofline::get_perf(double operational_intensity, int op_category) {
    const double bw = this->bandwidth * this->achievable_fraction;
    // Unknown category OR no per-op-type table → fall back to global peak.
    double peak = this->peak_perf * this->achievable_fraction;
    if (op_category != kOpCatUnknown) {
        auto it = this->peak_per_category.find(op_category);
        if (it != this->peak_per_category.end()) {
            peak = it->second * this->achievable_fraction;
        }
    }
    return min(bw * operational_intensity, peak);
}
