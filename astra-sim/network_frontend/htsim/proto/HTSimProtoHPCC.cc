#include "HTSimProtoHPCC.hh"
#include "HTSimSession.hh"

#include "route.h"
#include "network.h"

#include <cstdlib>
#include <cstring>
#include <sstream>

namespace HTSim {

HTSimProtoHPCC::HTSimProtoHPCC(const HTSim::tm_info* const tm, int argc, char** argv) {
    // Seed rand()/random() with a fixed value for reproducible runs (same
    // convention as HTSimProtoRoCE / HTSimProtoTcp).
    unsigned int seed = 0xA571A517u;
    if (const char* env = std::getenv("ASTRASIM_HTSIM_RANDOM_SEED")) {
        seed = static_cast<unsigned int>(std::strtoul(env, nullptr, 0));
    }
    std::srand(seed);
    ::srandom(seed);

    // HPCC relies on *LosslessOutputQueue* for INT injection —
    // queue_lossless_output.cpp:139 is where switch queuesize/timestamp/txbytes
    // are appended to each HPCC data packet.  CompositeQueue does not carry
    // INT.  Force-select lossless mode if the user hasn't picked one; they can
    // still override by setting ASTRASIM_HTSIM_QUEUE_TYPE explicitly.
    if (!std::getenv("ASTRASIM_HTSIM_QUEUE_TYPE")) {
        setenv("ASTRASIM_HTSIM_QUEUE_TYPE", "lossless", 1);
    }

    double endtime_sec = 1000.0;
    if (const char* env = std::getenv("ASTRASIM_HTSIM_ENDTIME_SEC")) {
        double v = std::atof(env);
        if (v > 0) endtime_sec = v;
    }
    int packet_bytes = 4096;
    if (const char* env = std::getenv("ASTRASIM_HTSIM_PACKET_BYTES")) {
        int v = std::atoi(env);
        if (v >= 256 && v <= 65536) packet_bytes = v;
    }
    Packet::set_packet_size(packet_bytes);
    eventlist.setEndtime(timeFromSec(endtime_sec));
    c = std::make_unique<Clock>(timeFromSec(50 / 100.), eventlist);
    no_of_nodes = tm->nodes;
    linkspeed = speedFromMbps(400.0 * 1000);  // 400 Gbps placeholder

    filename << "logout.dat";
    logfile = std::make_unique<Logfile>(filename.str(), eventlist);
    logfile->setStartTime(timeFromSec(0));

    const bool htsim_loggers_enabled = (std::getenv("ASTRASIM_HTSIM_LOGGERS") != nullptr);
    qlf = nullptr;
    if (htsim_loggers_enabled) {
        qlf = std::make_unique<QueueLoggerFactory>(
            logfile.get(), QueueLoggerFactory::LOGGER_SAMPLING, eventlist);
        qlf->set_sample_period(timeFromUs(1000.0));
    }

    // Topology selection: mirror HTSimProtoRoCE.
    const char* custom_topo_file = (tm->custom_topology_path && tm->custom_topology_path[0])
                                       ? tm->custom_topology_path
                                       : nullptr;
    if (custom_topo_file) {
        auto gtop = std::make_unique<HTSim::GenericCustomTopology>(&eventlist, qlf.get(), logfile.get());
        if (!gtop->load(custom_topo_file)) {
            std::cerr << "Failed to load custom topology file " << custom_topo_file << std::endl;
            std::exit(1);
        }
        if (gtop->no_of_hosts() != no_of_nodes) {
            std::cerr << "Mismatch between workload nodes (" << no_of_nodes
                      << ") and custom topology hosts (" << gtop->no_of_hosts() << ")" << std::endl;
            std::exit(1);
        }
        double topo_bw = gtop->recommended_nic_linkspeed_bps();
        if (std::getenv("ASTRASIM_HTSIM_NIC_WIRE_SPEED")) {
            topo_bw = gtop->max_host_linkspeed_bps();
        }
        if (const char* env = std::getenv("ASTRASIM_HTSIM_NIC_GBPS")) {
            double v = std::atof(env);
            if (v > 0) topo_bw = v * 1e9;
        }
        if (topo_bw > 0) {
            linkspeed = static_cast<linkspeed_bps>(topo_bw);
            std::cout << "[hpcc] host NIC pacing = " << (topo_bw / 1e9) << " Gbps" << std::endl;
        }
        top_generic = std::move(gtop);
        active_topology = top_generic.get();
    } else {
        top_fat = std::make_unique<FatTreeTopology>(no_of_nodes, linkspeed, memFromPkt(8),
                                                    qlf.get(), &eventlist, nullptr, RANDOM, 0);
        active_topology = top_fat.get();
    }
    no_of_nodes = active_topology->no_of_nodes();
    std::cout << "[hpcc] actual nodes " << no_of_nodes
              << " (INT via LosslessOutputQueue + PFC backpressure; "
              << "sender adapts CWND using INT telemetry)"
              << std::endl;
}

void HTSimProtoHPCC::schedule_htsim_event(HTSim::FlowInfo flow, int flow_id) {
    const auto src = flow.src;
    const auto dst = flow.dst;
    const auto msg_size = flow.size;
    simtime_picosec start = eventlist.now();

    auto key = std::make_pair(src, dst);
    if (net_paths.find(key) == net_paths.end()) {
        net_paths[key] = active_topology->get_paths(src, dst);
    }
    auto* paths = net_paths[key];
    if (!paths || paths->empty()) {
        std::cerr << "[hpcc] No path from " << src << " to " << dst << std::endl;
        return;
    }
    size_t choice = static_cast<size_t>(std::rand() % paths->size());

    auto* hpccSrc = new HPCCSrc(nullptr, nullptr, eventlist, linkspeed);
    hpccSrc->_debug_srcid = static_cast<int>(src);
    hpccSrc->_debug_dstid = static_cast<int>(dst);
    hpccSrc->astrasim_flow_finish_send_cb = &HTSimSession::flow_finish_send;
    hpccSrc->set_flowsize(msg_size);
    hpccSrc->set_dst(dst);

    auto* hpccSnk = new HPCCSink();
    hpccSnk->_debug_srcid = static_cast<int>(src);
    hpccSnk->_debug_dstid = static_cast<int>(dst);
    hpccSnk->astrasim_flow_finish_recv_cb = &HTSimSession::flow_finish_recv;
    hpccSnk->set_src(src);

    Route* routeout = new Route(*(paths->at(choice)));
    routeout->push_back(hpccSnk);

    auto rev_key = std::make_pair(dst, src);
    if (net_paths.find(rev_key) == net_paths.end()) {
        net_paths[rev_key] = active_topology->get_paths(dst, src);
    }
    auto* rev_paths = net_paths[rev_key];
    if (!rev_paths || rev_paths->empty()) {
        std::cerr << "[hpcc] No reverse path from " << dst << " to " << src << std::endl;
        return;
    }
    size_t rev_choice = static_cast<size_t>(std::rand() % rev_paths->size());
    Route* routein = new Route(*(rev_paths->at(rev_choice)));
    routein->push_back(hpccSrc);

    hpccSrc->setName("hpcc_" + std::to_string(src) + "_" + std::to_string(dst));
    logfile->writeName(*hpccSrc);
    hpccSnk->setName("hpccsink_" + std::to_string(src) + "_" + std::to_string(dst));
    logfile->writeName(*hpccSnk);

    if (flow_id) {
        hpccSrc->set_flowid(flow_id);
    }
    hpccSrc->connect(routeout, routein, *hpccSnk, start);
}

void HTSimProtoHPCC::run(const HTSim::tm_info* const /*tm*/) {
    Logged::dump_idmap();
    while (eventlist.doNextEvent()) {
    }
}

void HTSimProtoHPCC::finish() {
    std::cout << "\n[hpcc] Simulation of events finished\n";
}

}  // namespace HTSim
