/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "common/CommonNetworkApi.hh"
#include "astra-sim/system/MemEventHandlerData.hh"
#include "astra-sim/system/RecvPacketEventHandlerData.hh"
#include "astra-sim/system/RendezvousRecvData.hh"
#include "astra-sim/system/RendezvousSendData.hh"
#include "astra-sim/system/SendPacketEventHandlerData.hh"
#include "astra-sim/workload/Workload.hh"
#include <cstdlib>
#include <cassert>
#include <sstream>

using namespace AstraSim;
using namespace AstraSimAnalytical;
using namespace NetworkAnalytical;

std::shared_ptr<EventQueue> CommonNetworkApi::event_queue = nullptr;

ChunkIdGenerator CommonNetworkApi::chunk_id_generator = {};

CallbackTracker CommonNetworkApi::callback_tracker = {};

int CommonNetworkApi::dims_count = -1;

std::vector<Bandwidth> CommonNetworkApi::bandwidth_per_dim = {};

void CommonNetworkApi::set_event_queue(
    std::shared_ptr<EventQueue> event_queue_ptr) noexcept {
    assert(event_queue_ptr != nullptr);

    CommonNetworkApi::event_queue = std::move(event_queue_ptr);
}

CallbackTracker& CommonNetworkApi::get_callback_tracker() noexcept {
    return callback_tracker;
}

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

void release_pending_workload_node(Workload* workload,
                                   WorkloadLayerHandlerData* wlhd) noexcept {
    if (workload == nullptr || wlhd == nullptr) {
        return;
    }

    auto node = workload->et_feeder->lookupNode(wlhd->node_id);
    if (!node) {
        return;
    }

    if (workload->hw_resource == nullptr) {
        return;
    }

    const auto node_id = node->id();
    if (workload->hw_resource->cpu_ops_node.count(node_id) != 0 ||
        workload->hw_resource->gpu_ops_node.count(node_id) != 0 ||
        workload->hw_resource->gpu_comms_node.count(node_id) != 0 ||
        workload->hw_resource->gpu_recvs_node.count(node_id) != 0) {
        workload->hw_resource->release(node);
    }
}

void cleanup_callback_arg(void* arg) noexcept {
    if (arg == nullptr) {
        return;
    }

    auto* const ehd = static_cast<BasicEventHandlerData*>(arg);
    switch (ehd->event) {
    case EventType::PacketReceived: {
        auto* const data = static_cast<RecvPacketEventHandlerData*>(arg);
        release_pending_workload_node(data->workload, data->wlhd);
        delete data;
        break;
    }
    case EventType::PacketSent: {
        auto* const data = static_cast<SendPacketEventHandlerData*>(arg);
        release_pending_workload_node(
            dynamic_cast<Workload*>(data->callable), data->wlhd);
        delete data;
        break;
    }
    case EventType::RendezvousSend: {
        auto* const data = static_cast<RendezvousSendData*>(arg);
        cleanup_callback_arg(data->send.fun_arg);
        data->send.fun_arg = nullptr;
        delete data;
        break;
    }
    case EventType::RendezvousRecv: {
        auto* const data = static_cast<RendezvousRecvData*>(arg);
        cleanup_callback_arg(data->recv.fun_arg);
        data->recv.fun_arg = nullptr;
        delete data;
        break;
    }
    case EventType::CompFinished:
    case EventType::MemLoadFinished:
    case EventType::MemStoreFinished:
        delete static_cast<MemEventHandlerData*>(arg);
        break;
    default:
        delete ehd;
        break;
    }
}

}  // namespace

void CommonNetworkApi::cleanup_pending_callbacks() noexcept {
    callback_tracker.cleanup_pending_entries(cleanup_callback_arg);
}

std::vector<std::string> CommonNetworkApi::describe_pending_callbacks() noexcept {
    return callback_tracker.describe_pending_entries();
}

void CommonNetworkApi::process_chunk_arrival(void* args) noexcept {
    assert(args != nullptr);

    // parse chunk data
    auto* const data =
        static_cast<std::tuple<int, int, int, uint64_t, int>*>(args);
    const auto [tag, src, dest, count, chunk_id] = *data;
    delete data;

    if (should_debug_tag(tag)) {
        std::cerr << "[analytical-debug] arrival tag=" << tag
                  << " src=" << src << " dst=" << dest
                  << " size=" << count << " chunk_id=" << chunk_id
                  << std::endl;
    }

    // search tracker
    auto& tracker = CommonNetworkApi::get_callback_tracker();
    const auto entry = tracker.search_entry(tag, src, dest, count, chunk_id);
    assert(entry.has_value());  // entry must exist

    // if both callbacks are registered, invoke both callbacks
    if (entry.value()->both_callbacks_registered()) {
        entry.value()->invoke_send_handler();
        entry.value()->invoke_recv_handler();

        // remove entry
        tracker.pop_entry(tag, src, dest, count, chunk_id);
    } else {
        // run only send callback, as recv is not ready yet.
        entry.value()->invoke_send_handler();

        // mark the transmission as finished
        // so that recv callback will be invoked immediately
        // when sim_recv() is called
        entry.value()->set_transmission_finished();
    }
}

CommonNetworkApi::CommonNetworkApi(const int rank) noexcept
    : AstraNetworkAPI(rank) {
    assert(rank >= 0);
}

timespec_t CommonNetworkApi::sim_get_time() {
    // get current time from event queue
    const auto current_time = event_queue->get_current_time();

    // return the current time in ASTRA-sim format
    const auto astra_sim_time = static_cast<double>(current_time);
    return {NS, astra_sim_time};
}

void CommonNetworkApi::sim_schedule(const timespec_t delta,
                                    void (*fun_ptr)(void*),
                                    void* const fun_arg) {
    assert(delta.time_res == NS);
    assert(fun_ptr != nullptr);

    // calculate absolute event time
    const auto current_time = sim_get_time();
    const auto event_time = current_time.time_val + delta.time_val;
    const auto event_time_ns = static_cast<EventTime>(event_time);

    // schedule the event to the event queue
    assert(event_time_ns >= event_queue->get_current_time());
    event_queue->schedule_event(event_time_ns, fun_ptr, fun_arg);
}

int CommonNetworkApi::sim_recv(void* const buffer,
                               const uint64_t count,
                               const int type,
                               const int src,
                               const int tag,
                               sim_request* const request,
                               void (*msg_handler)(void*),
                               void* const fun_arg) {
    const auto dst = sim_comm_get_rank();
    const auto matched_chunk_id =
        callback_tracker.find_chunk_waiting_for_recv(tag, src, dst, count);
    const auto chunk_id =
        matched_chunk_id.has_value()
            ? matched_chunk_id.value()
            : CommonNetworkApi::chunk_id_generator.create_recv_chunk_id(
                  tag, src, dst, count);

    if (should_debug_tag(tag)) {
        std::cerr << "[analytical-debug] recv tag=" << tag << " src=" << src
                  << " dst=" << dst << " size=" << count
                  << " chunk_id=" << chunk_id
                  << " matched_existing=" << matched_chunk_id.has_value()
                  << std::endl;
    }

    // search tracker
    auto entry = callback_tracker.search_entry(tag, src, dst, count, chunk_id);
    if (entry.has_value()) {
        // send() already invoked
        // behavior is decided whether the transmission is already finished or
        // not
        if (entry.value()->is_transmission_finished()) {
            // transmission already finished, run callback immediately

            // pop entry
            callback_tracker.pop_entry(tag, src, dst, count, chunk_id);

            // run recv callback immediately
            const auto delta = timespec_t{NS, 0};
            sim_schedule(delta, msg_handler, fun_arg);
        } else {
            // transmission not finished yet, just register callback
            entry.value()->register_recv_callback(msg_handler, fun_arg);
        }
    } else {
        // send() not yet called
        // create new entry and insert callback
        auto* const new_entry =
            callback_tracker.create_new_entry(tag, src, dst, count, chunk_id);
        new_entry->register_recv_callback(msg_handler, fun_arg);
    }

    // return
    return 0;
}

double CommonNetworkApi::get_BW_at_dimension(const int dim) {
    assert(0 <= dim && dim < dims_count);

    // return bandwidth of the requested dimension
    return bandwidth_per_dim[dim];
}
