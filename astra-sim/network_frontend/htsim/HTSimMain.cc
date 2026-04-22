/******************************************************************************
This source code is licensed under the MIT license found in the
LICENSE file in the root directory of this source tree.
*******************************************************************************/

#include "HTSimNetworkApi.hh"
#include "astra-sim/common/Logging.hh"
#include "common/CmdLineParser.hh"
#include "HTSimSession.hh"
#include <astra-network-analytical/common/EventQueue.h>
#include <astra-network-analytical/common/NetworkParser.h>
#include <astra-network-analytical/congestion_unaware/Helper.h>
#include <remote_memory_backend/analytical/AnalyticalRemoteMemory.hh>
#include <cstdint>
#include <fstream>

using namespace HTSim;

int main(int argc, char* argv[]) {
    // Parse command line arguments
    auto cmd_line_parser = CmdLineParser(argv[0]);
    cmd_line_parser.get_options().add_options()(
        "htsim-proto", "HTSim Network Protocol [tcp]",
        cxxopts::value<HTSimProto>()->default_value("tcp"));
    cmd_line_parser.parse(argc, argv);

    // Get command line arguments
    const auto workload_configuration = cmd_line_parser.get<std::string>("workload-configuration");
    const auto comm_group_configuration =
        cmd_line_parser.get<std::string>("comm-group-configuration");
    const auto system_configuration = cmd_line_parser.get<std::string>("system-configuration");
    const auto remote_memory_configuration =
        cmd_line_parser.get<std::string>("remote-memory-configuration");
    const auto network_configuration = cmd_line_parser.get<std::string>("network-configuration");
    const auto logging_configuration = cmd_line_parser.get<std::string>("logging-configuration");
    const auto num_queues_per_dim = cmd_line_parser.get<int>("num-queues-per-dim");
    const auto comm_scale = cmd_line_parser.get<double>("comm-scale");
    const auto injection_scale = cmd_line_parser.get<double>("injection-scale");
    const auto rendezvous_protocol = cmd_line_parser.get<bool>("rendezvous-protocol");
    const auto proto = cmd_line_parser.get<HTSimProto>("htsim-proto");

    AstraSim::LoggerFactory::init(logging_configuration);

    // Parse the network YAML.
    // Note: htsim builds its own topology graph (FatTree today, GenericCustomTopology
    // in Phase 1), so we deliberately do NOT call construct_topology() — which would
    // reject Custom topology. We only need npus_count / dims for the ASTRA-sim Sys ctor.
    const auto network_parser = NetworkParser(network_configuration);
    const auto dims_count = network_parser.get_dims_count();
    auto npus_count_per_dim = network_parser.get_npus_counts_per_dim();
    int npus_count = 1;
    for (auto n : npus_count_per_dim) {
        npus_count *= n;
    }
    // Prefer the external topology file when Custom is requested.
    const auto htsim_topology_file = network_parser.get_topology_file();

    // If the YAML left npus_count blank (common for Custom-only YAMLs like
    // megatron_gpt_experiment/gpt_76b_1024/analytical_network.yml), derive the
    // host count from topology.txt.  Format: line 1 = "<num_nodes> <num_switches> <num_links>".
    if (npus_count == 0 && !htsim_topology_file.empty()) {
        std::ifstream tf(htsim_topology_file);
        if (tf) {
            uint32_t num_nodes = 0, num_switches = 0, num_links = 0;
            tf >> num_nodes >> num_switches >> num_links;
            if (num_nodes > 0 && num_nodes >= num_switches) {
                npus_count = static_cast<int>(num_nodes - num_switches);
                npus_count_per_dim = {npus_count};
            }
        }
    }
    if (npus_count <= 0) {
        std::cerr << "[Error] (htsim/main) Could not determine npus_count "
                  << "(set npus_count in YAML or provide a Custom topology_file)."
                  << std::endl;
        return -1;
    }

    HTSimNetworkApi::set_dims_and_bandwidth(dims_count, network_parser.get_bandwidths_per_dim());
    auto completion_tracker = std::make_shared<CompletionTracker>(npus_count);
    HTSimNetworkApi::set_completion_tracker(completion_tracker);

    // Create ASTRA-sim related resources
    auto network_apis = std::vector<std::unique_ptr<HTSimNetworkApi>>();
    const auto memory_api =
        std::make_unique<Analytical::AnalyticalRemoteMemory>(remote_memory_configuration);
    auto systems = std::vector<Sys*>();

    auto queues_per_dim = std::vector<int>();
    for (auto i = 0; i < dims_count; i++) {
        queues_per_dim.push_back(num_queues_per_dim);
    }

    for (int i = 0; i < npus_count; i++) {
        // create network and system
        auto network_api = std::make_unique<HTSimNetworkApi>(i);
        auto* const system =
            new Sys(i, workload_configuration, comm_group_configuration, system_configuration,
                    memory_api.get(), network_api.get(), npus_count_per_dim, queues_per_dim,
                    injection_scale, comm_scale, rendezvous_protocol);

        // push back network and system
        network_apis.push_back(std::move(network_api));
        systems.push_back(system);
    }

    // Get HTSim opts
    int htsim_argc = 0;
    char** htsim_argv = NULL;
    for (int i = 0; i < argc; i++) {
        if (std::string(argv[i]) == "--htsim_opts") {
            htsim_argc = argc - i;
            htsim_argv = argv + i;
        }
    }

    // Report HTSim opts
    for (int i = 0; i < htsim_argc; i++) {
        std::cout << htsim_argv[i] << " ";
    }
    std::cout << std::endl;

    // Initialize HTSim session
    HTSimNetworkApi::htsim_info.nodes = npus_count;
    // Plumb the Custom topology path (if any) through to HTSimProtoTcp so
    // GenericCustomTopology can load it.  NetworkParser already resolves the
    // path relative to the YAML directory.
    static std::string htsim_custom_topo_storage;
    if (!htsim_topology_file.empty()) {
        htsim_custom_topo_storage = htsim_topology_file;
        HTSimNetworkApi::htsim_info.custom_topology_path = htsim_custom_topo_storage.c_str();
    } else {
        HTSimNetworkApi::htsim_info.custom_topology_path = nullptr;
    }
    // Choose protocol
    auto& ht = HTSimSession::init(&HTSimNetworkApi::htsim_info, htsim_argc, htsim_argv, proto);

    // Initiate simulation
    for (int i = 0; i < npus_count; i++) {
        systems[i]->workload->fire();
    }

    // run HTSim
    ht.run(&HTSimNetworkApi::htsim_info);

    // check if terminated properly
    if (!completion_tracker.get()->all_finished()) {
        std::cout << "Warning: Simulation timed out." << std::endl;
    }

    // terminate simulation
    AstraSim::LoggerFactory::shutdown();

    ht.finish();
    return 0;
}
