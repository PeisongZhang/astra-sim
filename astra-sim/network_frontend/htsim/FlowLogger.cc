#include "FlowLogger.hh"

#include <cstdlib>
#include <cstring>
#include <iostream>

namespace HTSim {

namespace {
constexpr char   kMagic[8]    = {'H', 'T', 'S', 'M', 'F', 'L', 'O', 'G'};
constexpr uint32_t kVersion   = 1;
constexpr uint32_t kRecordSz  = 32;
constexpr uint64_t kDefaultCapGB = 300;
constexpr size_t   kBufferSz  = 1u << 20;  // 1 MiB FILE* buffer
}  // namespace

FlowLogger& FlowLogger::instance() {
    static FlowLogger inst;
    return inst;
}

FlowLogger::FlowLogger() {
    const char* env_path = std::getenv("ASTRASIM_HTSIM_FLOW_LOG");
    if (env_path != nullptr && env_path[0] != '\0') {
        path_ = env_path;
    }
    const char* cap_env = std::getenv("ASTRASIM_HTSIM_FLOW_LOG_MAX_GB");
    uint64_t cap_gb = kDefaultCapGB;
    if (cap_env != nullptr && cap_env[0] != '\0') {
        char* endp = nullptr;
        unsigned long long v = std::strtoull(cap_env, &endp, 10);
        if (endp != cap_env && v > 0) {
            cap_gb = static_cast<uint64_t>(v);
        }
    }
    cap_bytes_ = cap_gb * (1024ull * 1024ull * 1024ull);
}

FlowLogger::~FlowLogger() {
    close();
}

void FlowLogger::open_if_needed() {
    if (attempted_open_ || path_.empty()) {
        return;
    }
    attempted_open_ = true;
    file_ = std::fopen(path_.c_str(), "wb");
    if (file_ == nullptr) {
        std::cerr << "[flow-logger] failed to open " << path_
                  << " — logging disabled\n";
        return;
    }
    std::setvbuf(file_, nullptr, _IOFBF, kBufferSz);
    // Header: 8B magic + 4B version + 4B record size = 16B.
    std::fwrite(kMagic, 1, sizeof(kMagic), file_);
    std::fwrite(&kVersion, sizeof(kVersion), 1, file_);
    std::fwrite(&kRecordSz, sizeof(kRecordSz), 1, file_);
    bytes_written_ = 16;
    std::cerr << "[flow-logger] writing " << path_
              << " (cap " << (cap_bytes_ >> 30) << " GiB)\n";
}

void FlowLogger::record_start(uint32_t flow_id, uint64_t t_start_ns) {
    if (!attempted_open_) {
        open_if_needed();
    }
    if (file_ == nullptr) {
        return;
    }
    pending_starts_[flow_id] = t_start_ns;
}

void FlowLogger::record_finish(uint32_t flow_id, int src, int dst,
                               uint32_t size_bytes, uint64_t t_end_ns) {
    if (!attempted_open_) {
        open_if_needed();
    }
    if (file_ == nullptr) {
        return;
    }
    auto it = pending_starts_.find(flow_id);
    uint64_t t_start_ns = 0;
    if (it != pending_starts_.end()) {
        t_start_ns = it->second;
        pending_starts_.erase(it);
    } else {
        // Unknown flow — fall back to t_end == t_start so the collector can
        // still bucket it at the completion timestamp.
        t_start_ns = t_end_ns;
    }
    if (bytes_written_ + kRecordSz > cap_bytes_) {
        if (!cap_warned_) {
            std::cerr << "[flow-logger] 300 GB cap reached at "
                      << records_written_ << " records; dropping the rest\n";
            cap_warned_ = true;
            std::fflush(file_);
        }
        ++records_dropped_cap_;
        return;
    }
    // Pack a 32-byte record.
    char buf[kRecordSz];
    std::memcpy(buf +  0, &t_start_ns, 8);
    std::memcpy(buf +  8, &t_end_ns,   8);
    std::memcpy(buf + 16, &flow_id,    4);
    uint32_t src_u = static_cast<uint32_t>(src);
    uint32_t dst_u = static_cast<uint32_t>(dst);
    std::memcpy(buf + 20, &src_u,      4);
    std::memcpy(buf + 24, &dst_u,      4);
    std::memcpy(buf + 28, &size_bytes, 4);
    if (std::fwrite(buf, 1, kRecordSz, file_) != kRecordSz) {
        std::cerr << "[flow-logger] short write — disabling logger\n";
        std::fclose(file_);
        file_ = nullptr;
        return;
    }
    bytes_written_ += kRecordSz;
    ++records_written_;
}

void FlowLogger::close() {
    if (file_ == nullptr) {
        return;
    }
    std::fflush(file_);
    std::fclose(file_);
    file_ = nullptr;
    std::cerr << "[flow-logger] closed " << path_
              << " records=" << records_written_
              << " bytes=" << bytes_written_
              << " dropped_cap=" << records_dropped_cap_
              << " pending_unmatched=" << pending_starts_.size() << "\n";
    pending_starts_.clear();
}

}  // namespace HTSim
