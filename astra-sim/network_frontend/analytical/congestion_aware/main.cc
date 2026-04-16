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
    bool scheduled_any = false;

    for (auto* const system : systems) {
        if (system == nullptr || system->ready_list.empty() ||
            system->total_running_streams != 0) {
            continue;
        }

        if (system->ready_list.front()->current_queue_id != -1) {
            continue;
        }

        const auto running_before = system->total_running_streams;
        system->ask_for_schedule(static_cast<int>(system->ready_list.size()));
        if (system->total_running_streams > running_before) {
            scheduled_any = true;
        }
    }

    return scheduled_any;
}

bool issue_stranded_dependency_free_nodes(
    const std::vector<Sys*>& systems) noexcept {
    bool issued_any = false;

    for (auto* const system : systems) {
        if (system == nullptr || system->workload == nullptr ||
            system->workload->is_finished) {
            continue;
        }

        const auto ready_before = system->ready_list.size();
        system->workload->issue_dep_free_nodes();
        if (system->ready_list.size() > ready_before) {
            issued_any = true;
        }
    }

    return issued_any;
}

}  // namespace

int main(int argc, char* argv[]) {
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

    // Generate topology
    const auto network_parser = NetworkParser(network_configuration);
    const auto topology = construct_topology(network_parser);

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

    // Initiate ASTRA-sim simulation
    for (int i = 0; i < npus_count; i++) {
        systems[i]->workload->fire();
    }

    // run simulation
    while (true) {
        while (!event_queue->finished()) {
            event_queue->proceed();
        }

        const auto issued_any = issue_stranded_dependency_free_nodes(systems);
        const auto scheduled_any = schedule_stranded_ready_streams(systems);
        if (!issued_any && !scheduled_any) {
            dump_stuck_state(systems);
            break;
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
