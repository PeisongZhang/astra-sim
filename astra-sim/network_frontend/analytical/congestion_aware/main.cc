/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "astra-sim/common/Logging.hh"
#include "astra-sim/system/BaseStream.hh"
#include "common/CmdLineParser.hh"
#include "congestion_aware/CongestionAwareNetworkApi.hh"
#include <iostream>
#include <cstdlib>
#include <chrono>
#include <map>
#include <astra-network-analytical/common/EventQueue.h>
#include <astra-network-analytical/common/NetworkParser.h>
#include <astra-network-analytical/congestion_aware/Helper.h>
#include <remote_memory_backend/analytical/AnalyticalRemoteMemory.hh>

using namespace AstraSim;
using namespace Analytical;
using namespace AstraSimAnalytical;
using namespace AstraSimAnalyticalCongestionAware;
using namespace NetworkAnalytical;
using namespace NetworkAnalyticalCongestionAware;

namespace {

class PhaseTimer {
  public:
    explicit PhaseTimer(const char* const phase_name) noexcept
        : phase_name(phase_name),
          start_time(std::chrono::steady_clock::now()) {
        if (enabled()) {
            std::cerr << "[analytical-timing] start " << phase_name << std::endl;
        }
    }

    ~PhaseTimer() noexcept {
        if (!enabled()) {
            return;
        }

        const auto elapsed = std::chrono::steady_clock::now() - start_time;
        const auto elapsed_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
        std::cerr << "[analytical-timing] end " << phase_name << " elapsed_ms="
                  << elapsed_ms << std::endl;
    }

    static bool enabled() noexcept {
        const char* const raw = std::getenv("ASTRA_ANALYTICAL_TIMING");
        return raw != nullptr && *raw != '\0' && std::string(raw) != "0";
    }

  private:
    const char* phase_name;
    std::chrono::steady_clock::time_point start_time;
};

bool should_dump_stuck_state() noexcept {
    const char* const raw = std::getenv("ASTRA_ANALYTICAL_DEBUG_STUCK");
    return raw != nullptr && *raw != '\0' && std::string(raw) != "0";
}

void dump_stuck_state(const std::vector<Sys*>& systems) noexcept {
    if (!should_dump_stuck_state()) {
        return;
    }

    for (auto* const system : systems) {
        if (system == nullptr || system->workload == nullptr ||
            system->workload->is_finished) {
            continue;
        }

        std::cerr << "[analytical-stuck] sys=" << system->id
                  << " ready_list=" << system->ready_list.size()
                  << " total_running=" << system->total_running_streams
                  << " first_phase=" << system->first_phase_streams;
        if (!system->ready_list.empty()) {
            const auto* const front = system->ready_list.front();
            std::cerr << " front_stream=" << front->stream_id
                      << " front_queue=" << front->current_queue_id;
            std::cerr << " ready_streams=[";
            bool first = true;
            for (const auto* const stream : system->ready_list) {
                if (!first) {
                    std::cerr << ",";
                }
                first = false;
                std::cerr << stream->stream_id;
            }
            std::cerr << "]";
        }
        std::cerr << std::endl;
    }
}

bool schedule_stranded_ready_streams(
    const std::vector<Sys*>& systems) noexcept {
    using ReadyStream =
        std::pair<Sys*, std::list<BaseStream*>::iterator>;

    std::map<int, std::vector<ReadyStream>> ready_streams_by_id;

    for (auto* const system : systems) {
        if (system == nullptr || system->ready_list.empty() ||
            system->total_running_streams != 0) {
            continue;
        }

        for (auto it = system->ready_list.begin();
             it != system->ready_list.end(); ++it) {
            auto* const stream = *it;
            if (stream == nullptr || stream->current_queue_id != -1) {
                continue;
            }
            const auto sync_it =
                BaseStream::synchronizer.find(stream->stream_id);
            const auto sync_target_it =
                BaseStream::synchronizer_target.find(stream->stream_id);
            if (sync_it == BaseStream::synchronizer.end() ||
                sync_target_it == BaseStream::synchronizer_target.end() ||
                sync_it->second < sync_target_it->second) {
                continue;
            }
            ready_streams_by_id[stream->stream_id].emplace_back(system, it);
        }
    }

    for (auto& [stream_id, ready_streams] : ready_streams_by_id) {
        const auto sync_target_it =
            BaseStream::synchronizer_target.find(stream_id);
        if (sync_target_it == BaseStream::synchronizer_target.end() ||
            static_cast<int>(ready_streams.size()) != sync_target_it->second) {
            continue;
        }

        int running_before = 0;
        for (const auto& [system, _] : ready_streams) {
            running_before += system->total_running_streams;
        }

        for (const auto& [system, it] : ready_streams) {
            if (it != system->ready_list.begin()) {
                system->ready_list.splice(system->ready_list.begin(),
                                          system->ready_list, it);
            }
        }

        ready_streams.front().first->ask_for_schedule(1);

        int running_after = 0;
        for (const auto& [system, _] : ready_streams) {
            running_after += system->total_running_streams;
        }
        if (running_after > running_before) {
            return true;
        }
    }

    return false;
}

bool issue_stranded_dependency_free_nodes(
    const std::vector<Sys*>& systems) noexcept {
    bool issued_any = false;

    for (auto* const system : systems) {
        if (system == nullptr || system->workload == nullptr ||
            system->workload->is_finished) {
            continue;
        }

        if (system->workload->issue_dep_free_nodes()) {
            issued_any = true;
        }
    }

    return issued_any;
}

}  // namespace

int main(int argc, char* argv[]) {
    auto total_timer = PhaseTimer("total");

    // Parse command line arguments
    auto cmd_line_parser = CmdLineParser(argv[0]);
    cmd_line_parser.parse(argc, argv);

    // Get command line arguments
    const auto workload_configuration =
        cmd_line_parser.get<std::string>("workload-configuration");
    const auto comm_group_configuration =
        cmd_line_parser.get<std::string>("comm-group-configuration");
    const auto system_configuration =
        cmd_line_parser.get<std::string>("system-configuration");
    const auto remote_memory_configuration =
        cmd_line_parser.get<std::string>("remote-memory-configuration");
    const auto network_configuration =
        cmd_line_parser.get<std::string>("network-configuration");
    const auto logging_configuration =
        cmd_line_parser.get<std::string>("logging-configuration");
    const auto logging_folder =
        cmd_line_parser.get<std::string>("logging-folder");
    const auto num_queues_per_dim =
        cmd_line_parser.get<int>("num-queues-per-dim");
    const auto comm_scale = cmd_line_parser.get<double>("comm-scale");
    const auto injection_scale = cmd_line_parser.get<double>("injection-scale");
    const auto rendezvous_protocol =
        cmd_line_parser.get<bool>("rendezvous-protocol");

    AstraSim::LoggerFactory::init(logging_configuration, logging_folder);

    // Instantiate event queue
    const auto event_queue = std::make_shared<EventQueue>();
    Topology::set_event_queue(event_queue);

    std::shared_ptr<Topology> topology;
    {
        auto timer = PhaseTimer("construct_topology");
        const auto network_parser = NetworkParser(network_configuration);
        topology = construct_topology(network_parser);
    }

    // Get topology information
    const auto npus_count = topology->get_npus_count();
    const auto npus_count_per_dim = topology->get_npus_count_per_dim();
    const auto dims_count = topology->get_dims_count();

    // Set up Network API
    CongestionAwareNetworkApi::set_event_queue(event_queue);
    CongestionAwareNetworkApi::set_topology(topology);

    // Create ASTRA-sim related resources
    auto network_apis =
        std::vector<std::unique_ptr<CongestionAwareNetworkApi>>();
    const auto memory_api =
        std::make_unique<AnalyticalRemoteMemory>(remote_memory_configuration);
    auto systems = std::vector<Sys*>();

    auto queues_per_dim = std::vector<int>();
    for (auto i = 0; i < dims_count; i++) {
        queues_per_dim.push_back(num_queues_per_dim);
    }

    {
        auto timer = PhaseTimer("construct_systems");
        for (int i = 0; i < npus_count; i++) {
            // create network and system
            auto network_api = std::make_unique<CongestionAwareNetworkApi>(i);
            auto* const system =
                new Sys(i, workload_configuration, comm_group_configuration,
                        system_configuration, memory_api.get(), network_api.get(),
                        npus_count_per_dim, queues_per_dim, injection_scale,
                        comm_scale, rendezvous_protocol);

            // push back network and system
            network_apis.push_back(std::move(network_api));
            systems.push_back(system);
        }
    }

    // Initiate ASTRA-sim simulation
    {
        auto timer = PhaseTimer("workload_fire");
        for (int i = 0; i < npus_count; i++) {
            systems[i]->workload->fire();
        }
    }

    // run simulation
    {
        auto timer = PhaseTimer("simulation_loop");
        uint64_t outer_iterations = 0;
        uint64_t proceed_calls = 0;
        auto proceed_time = std::chrono::steady_clock::duration::zero();
        auto issue_time = std::chrono::steady_clock::duration::zero();
        auto schedule_time = std::chrono::steady_clock::duration::zero();
        while (true) {
            ++outer_iterations;
            while (!event_queue->finished()) {
                const auto begin = std::chrono::steady_clock::now();
                event_queue->proceed();
                proceed_time += std::chrono::steady_clock::now() - begin;
                ++proceed_calls;
            }

            auto begin = std::chrono::steady_clock::now();
            const auto issued_any = issue_stranded_dependency_free_nodes(systems);
            issue_time += std::chrono::steady_clock::now() - begin;
            begin = std::chrono::steady_clock::now();
            const auto scheduled_any = schedule_stranded_ready_streams(systems);
            schedule_time += std::chrono::steady_clock::now() - begin;
            if (!issued_any && !scheduled_any) {
                dump_stuck_state(systems);
                break;
            }
        }

        if (PhaseTimer::enabled()) {
            const auto to_ms = [](const auto duration) {
                return std::chrono::duration_cast<std::chrono::milliseconds>(
                           duration)
                    .count();
            };
            std::cerr << "[analytical-timing] simulation_loop_breakdown"
                      << " outer_iterations=" << outer_iterations
                      << " proceed_calls=" << proceed_calls
                      << " proceed_ms=" << to_ms(proceed_time)
                      << " issue_dep_free_ms=" << to_ms(issue_time)
                      << " schedule_stranded_ms=" << to_ms(schedule_time)
                      << std::endl;
        }
    }

    const auto pending_callbacks = CommonNetworkApi::describe_pending_callbacks();
    if (!pending_callbacks.empty()) {
        std::cerr << "[analytical] Pending callbacks before cleanup: "
                  << pending_callbacks.size() << std::endl;
        for (const auto& entry : pending_callbacks) {
            std::cerr << "[analytical]   " << entry << std::endl;
        }
    }

    CommonNetworkApi::cleanup_pending_callbacks();

    for (auto it : systems) {
        delete it;
    }
    systems.clear();

    // terminate simulation
    AstraSim::LoggerFactory::shutdown();
    return pending_callbacks.empty() ? 0 : 2;
}
