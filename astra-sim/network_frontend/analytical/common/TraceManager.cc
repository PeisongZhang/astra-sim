/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "common/TraceManager.hh"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

using namespace AstraSimAnalytical;

FILE* TraceManager::chunk_file = nullptr;
bool TraceManager::initialized = false;

namespace {

bool env_flag_enabled(const char* const name) noexcept {
    const char* const raw = std::getenv(name);
    if (raw == nullptr || *raw == '\0') {
        return false;
    }
    return std::string(raw) != "0";
}

}  // namespace

void TraceManager::init() noexcept {
    if (initialized) {
        return;
    }
    initialized = true;

    if (!env_flag_enabled("ASTRA_ANALYTICAL_ENABLE_TRACE")) {
        return;
    }

    const char* const raw_path =
        std::getenv("ASTRA_ANALYTICAL_TRACE_FILE");
    const std::string path = (raw_path != nullptr && *raw_path != '\0')
                                 ? std::string(raw_path)
                                 : std::string("analytical_trace.txt");

    chunk_file = std::fopen(path.c_str(), "w");
    if (chunk_file == nullptr) {
        std::cerr << "[analytical-trace] failed to open trace file '" << path
                  << "': " << std::strerror(errno) << std::endl;
        return;
    }

    // Use a 4 MB buffer so that tens of thousands of short writes per
    // simulation iteration don't turn into tens of thousands of syscalls.
    static constexpr std::size_t kBufSize = 4 * 1024 * 1024;
    std::setvbuf(chunk_file, nullptr, _IOFBF, kBufSize);

    std::fprintf(chunk_file,
                 "# src dst size send_time_ns finish_time_ns chunk_id tag\n");
    std::cerr << "[analytical-trace] writing chunk-level trace to " << path
              << std::endl;
}

void TraceManager::finalize() noexcept {
    if (chunk_file != nullptr) {
        std::fflush(chunk_file);
        std::fclose(chunk_file);
        chunk_file = nullptr;
    }
    initialized = false;
}

bool TraceManager::enabled() noexcept {
    return chunk_file != nullptr;
}

void TraceManager::write_chunk(const int src,
                               const int dst,
                               const uint64_t size,
                               const EventTime send_time_ns,
                               const EventTime finish_time_ns,
                               const int chunk_id,
                               const int tag) noexcept {
    if (chunk_file == nullptr) {
        return;
    }
    std::fprintf(chunk_file,
                 "%d %d %llu %llu %llu %d %d\n",
                 src,
                 dst,
                 static_cast<unsigned long long>(size),
                 static_cast<unsigned long long>(send_time_ns),
                 static_cast<unsigned long long>(finish_time_ns),
                 chunk_id,
                 tag);
}
