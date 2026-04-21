/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#ifndef __ROOFLINE_HH__
#define __ROOFLINE_HH__

#include <unordered_map>

namespace AstraSim {

class Roofline {
  public:
    // correctness_todo.md §4 — op_category ids emitted by STG's
    // chakra_00_4_backend.set_comp_attrs (int32 attr "op_category" on
    // COMP_NODE). Any node without the attr uses the global peak.
    static constexpr int kOpCatGEMM = 0;
    static constexpr int kOpCatElemwise = 1;
    static constexpr int kOpCatSoftmax = 2;
    static constexpr int kOpCatReduce = 3;
    static constexpr int kOpCatOther = 4;
    static constexpr int kOpCatUnknown = -1;  // no per-op-type entry

    Roofline(double peak_perf);
    Roofline(double bandwidth, double peak_perf);
    void set_bandwidth(double bandwidth);
    // P2-B: derate both peak and memory bandwidth by an achievable fraction
    // to model kernel-fusion / kernel-launch-overhead effects. Default is
    // 1.0 (pure peak roofline; legacy behavior).
    void set_achievable_fraction(double frac);

    // correctness_todo.md §4 — per-op-type peak (FLOPs/sec). Missing entries
    // fall back to the global peak_perf. Use kOpCat* ids as keys.
    void set_peak_per_category(int op_category, double peak_perf);
    // Resolve the effective peak for a category (applies achievable_fraction).
    double get_peak_for_category(int op_category) const;
    bool has_per_category_peaks() const;

    // Legacy signature — global peak only.
    double get_perf(double operational_intensity);
    // correctness_todo.md §4 — per-op-type signature. op_category = -1 falls
    // back to the legacy global peak.
    double get_perf(double operational_intensity, int op_category);

  private:
    double bandwidth;
    double peak_perf;
    double achievable_fraction = 1.0;
    std::unordered_map<int, double> peak_per_category;
};

}  // namespace AstraSim

#endif /* __ROOFLINE_HH__ */
