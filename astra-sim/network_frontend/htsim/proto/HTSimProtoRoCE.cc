#include "HTSimProtoRoCE.hh"
#include "HTSimSession.hh"

#include "route.h"
#include "network.h"

#include <cstdlib>
#include <cstring>
#include <sstream>

namespace HTSim {

static constexpr uint32_t kHostNicMbps = 400 * 1000;  // 400 Gbps default

HTSimProtoRoCE::HTSimProtoRoCE(const HTSim::tm_info* const tm, int argc, char** argv) {
    // Seed rand()/random() with a fixed value for reproducible runs.
    // Override with ASTRASIM_HTSIM_RANDOM_SEED to explore seed-sensitivity.
    unsigned int seed = 0xA571A517u;
    if (const char* env = std::getenv("ASTRASIM_HTSIM_RANDOM_SEED")) {
        seed = static_cast<unsigned int>(std::strtoul(env, nullptr, 0));
    }
    std::srand(seed);
    ::srandom(seed);
    // Default: 0 = unlimited (eventlist runs until completion_tracker is done
    // or the event queue drains). Override with ASTRASIM_HTSIM_ENDTIME_SEC > 0
    // to cap simulated time; values <= 0 are treated as "unlimited".
    double endtime_sec = 0.0;
    if (const char* env = std::getenv("ASTRASIM_HTSIM_ENDTIME_SEC")) {
        endtime_sec = std::atof(env);
    }
    // §11.3 speed lever — MTU/packet size. htsim's default is 1500 B; real DC
    // RoCE fabrics use 4 KB frames (MLNX default PAYLOAD_SIZE) or 9 KB jumbo
    // frames. Bigger MTU proportionally cuts simulated packet events. Default
    // to 4 KB here; override with ASTRASIM_HTSIM_PACKET_BYTES.
    int packet_bytes = 4096;
    if (const char* env = std::getenv("ASTRASIM_HTSIM_PACKET_BYTES")) {
        int v = std::atoi(env);
        if (v >= 256 && v <= 65536) packet_bytes = v;
    }
    Packet::set_packet_size(packet_bytes);
    if (endtime_sec > 0) {
        eventlist.setEndtime(timeFromSec(endtime_sec));
    } else {
        // 0 = "unlimited" 语义。但 Clock 是个无限自重排的进度指示器，一旦所有
        // flow 都完成而 CompletionTracker 又因为某些 rank 卡住没触发
        // stop_simulation()，heap 里就只剩 Clock，simtime 会被以 0.5 s 一格
        // 推高到 UINT64_MAX 附近，下一次 sourceIsPendingRel(now()+period)
        // 在 uint64 上 wrap 后小于 now()，触发 eventlist.cpp:115 的
        // assert(when>=now())。设一个远大于任何真实 workload 又远离溢出的
        // 上限（1e6 s ≈ 11.5 天 simtime）来兜底。
        eventlist.setEndtime(timeFromSec(1.0e6));
    }
    c = std::make_unique<Clock>(timeFromSec(50 / 100.), eventlist);
    no_of_nodes = tm->nodes;
    linkspeed = speedFromMbps((double)kHostNicMbps);

    filename << "logout.dat";
    logfile = std::make_unique<Logfile>(filename.str(), eventlist);
    logfile->setStartTime(timeFromSec(0));

    const bool htsim_loggers_enabled = (std::getenv("ASTRASIM_HTSIM_LOGGERS") != nullptr);
    // Do NOT instantiate a QueueLoggerFactory when loggers are disabled.
    // LOGGER_EMPTY still allocates a QueueLoggerEmpty EventSource per queue,
    // and its tick `_period` is read from QueueLoggerFactory::_sample_period
    // which is uninitialized in the ctor — often 0, which puts the logger
    // into an infinite self-reschedule loop at the same simtime. Pass
    // nullptr for qlf so topologies skip per-queue logger allocation
    // entirely (both GenericCustomTopology and FatTreeTopology handle null).
    qlf = nullptr;
    if (htsim_loggers_enabled) {
        qlf = std::make_unique<QueueLoggerFactory>(
            logfile.get(), QueueLoggerFactory::LOGGER_SAMPLING, eventlist);
        qlf->set_sample_period(timeFromUs(1000.0));
    }

    // Choose topology.
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
        // NIC pacing rate. Default: recommended = min(max host link,
        // min backbone link). On heterogeneous fabrics (llama/qwen/gpt
        // topologies with 4800 Gbps host NICs and 200 Gbps backbone),
        // pacing at wire speed pushes the packet-level sim into a
        // retransmission storm (RTO 20 ms × N flows) that explodes
        // wall-time without changing fluid outcome. Pacing at bottleneck
        // reproduces fluid-level throughput correctly.
        // Override with ASTRASIM_HTSIM_NIC_GBPS (in Gbps).
        // Set ASTRASIM_HTSIM_NIC_WIRE_SPEED=1 to force legacy max_host behaviour.
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
            std::cout << "[roce] host NIC pacing = " << (topo_bw / 1e9) << " Gbps" << std::endl;
        }
        top_generic = std::move(gtop);
        active_topology = top_generic.get();

        // OCS mutator exerciser (§11.4 / U6).  Set
        //   ASTRASIM_HTSIM_OCS_SCHEDULE="<at_us>:<src>:<dst>:<bw_gbps>:<up>[,...]"
        // to schedule run-time bandwidth/up-down changes.  Useful both as a
        // unit-ish test for the mutator API and as a seed for MoE-OCS research.
        if (const char* env = std::getenv("ASTRASIM_HTSIM_OCS_SCHEDULE")) {
            std::string s(env);
            size_t start = 0;
            while (start < s.size()) {
                size_t comma = s.find(',', start);
                std::string ev = s.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
                start = (comma == std::string::npos) ? s.size() : comma + 1;
                // parse "at_us:src:dst:bw_gbps:up"
                double at_us = 0, bw_gbps = 0;
                uint32_t src_ = 0, dst_ = 0;
                int up_ = 1;
                if (std::sscanf(ev.c_str(), "%lf:%u:%u:%lf:%d",
                                &at_us, &src_, &dst_, &bw_gbps, &up_) == 5) {
                    uint64_t at_ps = static_cast<uint64_t>(at_us * 1e6);  // us -> ps
                    double new_bw_bps = bw_gbps * 1e9;
                    top_generic->schedule_link_change(at_ps, src_, dst_, new_bw_bps, up_ != 0);
                    std::cout << "[ocs] scheduled link_change @ " << at_us
                              << "us " << src_ << "<->" << dst_
                              << " bw=" << bw_gbps << "Gbps up=" << up_ << std::endl;
                } else {
                    std::cerr << "[ocs] malformed ASTRASIM_HTSIM_OCS_SCHEDULE entry '"
                              << ev << "', expected at_us:src:dst:bw_gbps:up" << std::endl;
                }
            }
        }
    } else {
        top_fat = std::make_unique<FatTreeTopology>(no_of_nodes, linkspeed, memFromPkt(8),
                                                    qlf.get(), &eventlist, nullptr, RANDOM, 0);
        active_topology = top_fat.get();
    }
    no_of_nodes = active_topology->no_of_nodes();
    std::cout << "[roce] actual nodes " << no_of_nodes << std::endl;
}

void HTSimProtoRoCE::schedule_htsim_event(HTSim::FlowInfo flow, int flow_id) {
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
        std::cerr << "[roce] No path from " << src << " to " << dst << std::endl;
        return;
    }
    size_t choice = static_cast<size_t>(std::rand() % paths->size());

    // Build Src/Sink and connect along the returned route.
    auto* roceSrc = new RoceSrc(nullptr, nullptr, eventlist, linkspeed);
    roceSrc->_debug_srcid = static_cast<int>(src);
    roceSrc->_debug_dstid = static_cast<int>(dst);
    roceSrc->astrasim_flow_finish_send_cb = &HTSimSession::flow_finish_send;
    roceSrc->set_flowsize(msg_size);

    // U3 — enable DCQCN AIMD CC on the RoCE source.  Controlled by
    // ASTRASIM_HTSIM_DCQCN_AIMD, which HTSimSession::HTSimSession() sets
    // when the `dcqcn` protocol variant is selected.  Safe no-op for plain
    // RoCE (leave the env var unset).  Parameters come from env:
    //   ASTRASIM_HTSIM_DCQCN_AI_MBPS       additive-increase step (Mbps)
    //   ASTRASIM_HTSIM_DCQCN_MIN_MBPS      minimum allowed rate (Mbps)
    //   ASTRASIM_HTSIM_DCQCN_BYTES         bytes between rate updates
    //   ASTRASIM_HTSIM_DCQCN_G_RECIP       1/g for alpha EWMA (e.g. 16)
    static const bool dcqcn_aimd =
        (std::getenv("ASTRASIM_HTSIM_DCQCN_AIMD") != nullptr);
    if (dcqcn_aimd) {
        linkspeed_bps ai_bps = 0;
        linkspeed_bps min_bps = 0;
        uint64_t byte_threshold = 0;
        double g = 0.0;
        if (const char* e = std::getenv("ASTRASIM_HTSIM_DCQCN_AI_MBPS")) {
            double mbps = std::atof(e);
            if (mbps > 0) ai_bps = (linkspeed_bps)(mbps * 1.0e6);
        }
        if (const char* e = std::getenv("ASTRASIM_HTSIM_DCQCN_MIN_MBPS")) {
            double mbps = std::atof(e);
            if (mbps > 0) min_bps = (linkspeed_bps)(mbps * 1.0e6);
        }
        if (const char* e = std::getenv("ASTRASIM_HTSIM_DCQCN_BYTES")) {
            long long v = std::atoll(e);
            if (v > 0) byte_threshold = (uint64_t)v;
        }
        if (const char* e = std::getenv("ASTRASIM_HTSIM_DCQCN_G_RECIP")) {
            int v = std::atoi(e);
            if (v > 1) g = 1.0 / (double)v;
        }
        roceSrc->enable_dcqcn(ai_bps, min_bps, byte_threshold, g);
    }

    auto* roceSnk = new RoceSink();
    roceSnk->_debug_srcid = static_cast<int>(src);
    roceSnk->_debug_dstid = static_cast<int>(dst);
    roceSnk->astrasim_flow_finish_recv_cb = &HTSimSession::flow_finish_recv;

    // RoCE needs a *full* reverse path for ACKs — main_roce.cpp does
    // `new Route(*top->get_bidir_paths(dest, src, false)->at(choice))` and
    // `add_endpoints(roceSnk, roceSrc)`.  Without this, ACKs are never
    // generated correctly on multi-hop topologies (the TCP fast-path of
    // `routein=[tcpSrc]` works because htsim TCP is forgiving; RoCE is not).
    Route* routeout = new Route(*(paths->at(choice)));
    routeout->push_back(roceSnk);

    auto rev_key = std::make_pair(dst, src);
    if (net_paths.find(rev_key) == net_paths.end()) {
        net_paths[rev_key] = active_topology->get_paths(dst, src);
    }
    auto* rev_paths = net_paths[rev_key];
    if (!rev_paths || rev_paths->empty()) {
        std::cerr << "[roce] No reverse path from " << dst << " to " << src << std::endl;
        return;
    }
    size_t rev_choice = static_cast<size_t>(std::rand() % rev_paths->size());
    Route* routein = new Route(*(rev_paths->at(rev_choice)));
    routein->push_back(roceSrc);

    roceSrc->setName("roce_" + std::to_string(src) + "_" + std::to_string(dst));
    logfile->writeName(*roceSrc);
    roceSnk->setName("rocesink_" + std::to_string(src) + "_" + std::to_string(dst));
    logfile->writeName(*roceSnk);

    if (flow_id) {
        roceSrc->set_flowid(flow_id);
    }
    roceSrc->connect(routeout, routein, *roceSnk, start);
}

void HTSimProtoRoCE::run(const HTSim::tm_info* const /*tm*/) {
    Logged::dump_idmap();
    while (eventlist.doNextEvent()) {
    }
}

void HTSimProtoRoCE::finish() {
    std::cout << "\n[roce] Simulation of events finished\n";
}

}  // namespace HTSim
