/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#pragma once

#include <astra-network-analytical/common/Type.h>
#include <cstdint>
#include <cstdio>

using namespace NetworkAnalytical;

namespace AstraSimAnalytical {

/**
 * TraceManager writes per-chunk network events to a text trace so that
 * time-windowed traffic matrices can be extracted offline.
 *
 * Controlled by env vars:
 *   - ASTRA_ANALYTICAL_ENABLE_TRACE=1 turns it on
 *   - ASTRA_ANALYTICAL_TRACE_FILE=<path> sets the output file
 *     (defaults to "analytical_trace.txt" in the current working dir)
 *
 * Output format (space-separated, one line per chunk arrival, with header):
 *   src dst size send_time_ns finish_time_ns chunk_id tag
 */
class TraceManager {
  public:
    /** Open the trace file if enabled via env vars. Safe to call twice. */
    static void init() noexcept;

    /** Close the trace file and flush buffers. */
    static void finalize() noexcept;

    /** True iff the chunk-level trace is enabled and open. */
    [[nodiscard]] static bool enabled() noexcept;

    /** Write one chunk-level trace line. Cheap no-op when disabled. */
    static void write_chunk(int src,
                            int dst,
                            uint64_t size,
                            EventTime send_time_ns,
                            EventTime finish_time_ns,
                            int chunk_id,
                            int tag) noexcept;

  private:
    static FILE* chunk_file;
    static bool initialized;
};

}  // namespace AstraSimAnalytical
