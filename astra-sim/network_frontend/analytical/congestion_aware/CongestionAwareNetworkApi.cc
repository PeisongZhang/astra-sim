/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "congestion_aware/CongestionAwareNetworkApi.hh"
#include <astra-network-analytical/congestion_aware/Chunk.h>
#include <cstdlib>
#include <cassert>
#include <iostream>
#include <sstream>

using namespace AstraSim;
using namespace AstraSimAnalyticalCongestionAware;
using namespace NetworkAnalytical;
using namespace NetworkAnalyticalCongestionAware;

std::shared_ptr<Topology> CongestionAwareNetworkApi::topology;

namespace {

bool should_debug_tag(const int tag) noexcept {
    const char* const raw = std::getenv("ASTRA_ANALYTICAL_DEBUG_TAGS");
    if (raw == nullptr || *raw == '\0') {
        return false;
    }

    std::stringstream ss(raw);
    std::string token;
    while (std::getline(ss, token, ',')) {
        if (!token.empty() && std::stoi(token) == tag) {
            return true;
        }
    }
    return false;
}

}  // namespace

void CongestionAwareNetworkApi::set_topology(
    std::shared_ptr<Topology> topology_ptr) noexcept {
    assert(topology_ptr != nullptr);

    // move topology
    CongestionAwareNetworkApi::topology = std::move(topology_ptr);

    // set topology-related values
    CongestionAwareNetworkApi::dims_count =
        CongestionAwareNetworkApi::topology->get_dims_count();
    CongestionAwareNetworkApi::bandwidth_per_dim =
        CongestionAwareNetworkApi::topology->get_bandwidth_per_dim();
}

CongestionAwareNetworkApi::CongestionAwareNetworkApi(const int rank) noexcept
    : CommonNetworkApi(rank) {
    assert(rank >= 0);
}

int CongestionAwareNetworkApi::sim_send(void* const buffer,
                                        const uint64_t count,
                                        const int type,
                                        const int dst,
                                        const int tag,
                                        sim_request* const request,
                                        void (*msg_handler)(void*),
                                        void* const fun_arg) {
    const auto src = sim_comm_get_rank();
    const auto matched_chunk_id =
        callback_tracker.find_chunk_waiting_for_send(tag, src, dst, count);
    const auto chunk_id =
        matched_chunk_id.has_value()
            ? matched_chunk_id.value()
            : CongestionAwareNetworkApi::chunk_id_generator
                  .create_send_chunk_id(tag, src, dst, count);

    if (should_debug_tag(tag)) {
        std::cerr << "[analytical-debug] send tag=" << tag << " src=" << src
                  << " dst=" << dst << " size=" << count
                  << " chunk_id=" << chunk_id
                  << " matched_existing=" << matched_chunk_id.has_value()
                  << std::endl;
    }

    // search tracker
    const auto entry =
        callback_tracker.search_entry(tag, src, dst, count, chunk_id);
    if (entry.has_value()) {
        // recv operation already issued.
        // register send callback
        entry.value()->register_send_callback(msg_handler, fun_arg);
    } else {
        // recv operation not issued yet
        // create new entry and insert callback
        auto* const new_entry =
            callback_tracker.create_new_entry(tag, src, dst, count, chunk_id);
        new_entry->register_send_callback(msg_handler, fun_arg);
    }

    // create chunk
    auto chunk_arrival_arg = std::tuple(tag, src, dst, count, chunk_id);
    auto arg = std::make_unique<decltype(chunk_arrival_arg)>(chunk_arrival_arg);
    const auto arg_ptr = static_cast<void*>(arg.release());
    const auto route = topology->route(src, dst);
    auto chunk = std::make_unique<Chunk>(
        count, route, CongestionAwareNetworkApi::process_chunk_arrival,
        arg_ptr);

    // initiate transmission from src -> dst.
    topology->send(std::move(chunk));

    // return
    return 0;
}
