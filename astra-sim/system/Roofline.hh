/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#ifndef __ROOFLINE_HH__
#define __ROOFLINE_HH__

namespace AstraSim {

class Roofline {
  public:
    Roofline(double peak_perf);
    Roofline(double bandwidth, double peak_perf);
    void set_bandwidth(double bandwidth);
    // P2-B: derate both peak and memory bandwidth by an achievable fraction
    // to model kernel-fusion / kernel-launch-overhead effects. Default is
    // 1.0 (pure peak roofline; legacy behavior).
    void set_achievable_fraction(double frac);
    double get_perf(double operational_intensity);

  private:
    double bandwidth;
    double peak_perf;
    double achievable_fraction = 1.0;
};

}  // namespace AstraSim

#endif /* __ROOFLINE_HH__ */
