#pragma once

// Offline per-flow event logger for the htsim backend.
//
// Env vars:
//   ASTRASIM_HTSIM_FLOW_LOG      — output binary path (unset => disabled)
//   ASTRASIM_HTSIM_FLOW_LOG_MAX_GB — size cap (default 300).  Once the cap is
//       hit the logger stops writing new records and prints a one-shot warning;
//       existing records remain valid.
//
// Output format (little-endian):
//   Header (16 B):
//     magic   [8] = "HTSMFLOG"
//     version [4] = 1
//     rec_sz  [4] = 32
//   Records (32 B each):
//     uint64_t t_start_ns
//     uint64_t t_end_ns
//     uint32_t flow_id
//     uint32_t src
//     uint32_t dst
//     uint32_t size_bytes
//
// The Python collector in htsim_experiment/traffic_analysis/ consumes this
// directly.

#include <cstdint>
#include <cstdio>
#include <string>
#include <unordered_map>

namespace HTSim {

class FlowLogger {
  public:
    static FlowLogger& instance();

    // Called when sim_send is invoked (flow enters the network).
    void record_start(uint32_t flow_id, uint64_t t_start_ns);

    // Called when htsim tells us the flow has finished.  Looks up the matching
    // start time and writes a 32-byte record.  Unknown flow ids are silently
    // skipped (this can happen if the logger was enabled mid-run).
    void record_finish(uint32_t flow_id, int src, int dst,
                       uint32_t size_bytes, uint64_t t_end_ns);

    // Flush and close.  Safe to call repeatedly.
    void close();

    bool enabled() const { return file_ != nullptr; }

  private:
    FlowLogger();
    ~FlowLogger();
    FlowLogger(const FlowLogger&) = delete;
    FlowLogger& operator=(const FlowLogger&) = delete;

    void open_if_needed();

    std::FILE* file_ = nullptr;
    std::string path_;
    uint64_t bytes_written_ = 0;
    uint64_t cap_bytes_ = 0;
    uint64_t records_written_ = 0;
    uint64_t records_dropped_cap_ = 0;
    bool cap_warned_ = false;
    bool attempted_open_ = false;
    // flow_id -> t_start_ns.  Single-threaded DES loop, no locking needed.
    std::unordered_map<uint32_t, uint64_t> pending_starts_;
};

}  // namespace HTSim
