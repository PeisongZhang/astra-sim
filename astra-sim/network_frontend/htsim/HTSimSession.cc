#include "HTSimSession.hh"
#include "HTSimSessionImpl.hh"
#include "HTSimProtoTcp.hh"
#include "HTSimProtoRoCE.hh"
#include "HTSimProtoHPCC.hh"
#include "FlowLogger.hh"

#include <cstdlib>
#include <iostream>

namespace HTSim {

std::map<std::pair<int, HTSim::Dir>, int> HTSimSession::node_bytes_sent;
std::map<std::pair<HTSim::MsgEventKey, int>, HTSim::MsgEvent>
    HTSimSession::send_waiting;
std::map<HTSim::MsgEventKey, HTSim::MsgEvent> HTSimSession::recv_waiting;
std::map<HTSim::MsgEventKey, int> HTSimSession::msg_standby;
std::map<int, int> HTSimSession::flow_id_to_tag;
HTSimSession* HTSimSession::session = nullptr;
HTSimConf HTSimSession::conf;

typedef void (*EventHandler)(void*);

class AstraEventSrc : public EventSource {
public:
    AstraEventSrc(EventHandler msg_handler, void* fun_arg, EventList& eventList);
    void doNextEvent();

private:
    EventHandler _msg_handler;
    void* _fun_arg;
};

// Event source for scheduling callbacks to be executed by HTSim
std::vector<AstraEventSrc*> astra_events;

AstraEventSrc::AstraEventSrc(EventHandler msg_handler,
                             void* fun_arg,
                             EventList& eventList)
    : EventSource(eventList, "astraSimSrc"), _msg_handler(msg_handler), _fun_arg(fun_arg) {
}

void AstraEventSrc::doNextEvent() {
    // Run the handler
    _msg_handler(_fun_arg);
}

std::stringstream& operator>> (std::stringstream& is, HTSimProto& proto) {
    std::string s;
    is >> s;
    if (s == "tcp") {
        proto = HTSimProto::Tcp;
    } else if (s == "roce") {
        proto = HTSimProto::RoCE;
    } else if (s == "dcqcn") {
        proto = HTSimProto::DCQCN;
    } else if (s == "hpcc") {
        proto = HTSimProto::HPCC;
    } else {
        proto = HTSimProto::None;
    }
    return is;
}

// Send_flow commands the HTSim simulator to schedule a message to be sent
// between two pair of nodes. send_flow is triggered by sim_send.
// Per §11.3 lever #3: gate per-flow verbose logging. 1024-NPU runs produce ~10M such
// lines which alone burn minutes of wall time on stdout flushing.
static const bool kHTSimVerboseFlows = (std::getenv("ASTRASIM_HTSIM_VERBOSE") != nullptr);

void HTSimSession::send_flow(FlowInfo flow,
                            int flow_id,
                            void (*msg_handler)(void* fun_arg),
                            void* fun_arg) {
    // Create a MsgEvent instance and register callback function.
    if (kHTSimVerboseFlows) {
        std::cout << "Send flow " << flow_id << " from " << flow.src << " to " << flow.dst
                  << " with size " << flow.size << "\n";
    }
    MsgEvent send_event = MsgEvent(flow.src, flow.dst, Dir::Send, flow.size, fun_arg, msg_handler);
    flow_id_to_tag[flow_id] = flow.tag;
    std::pair<MsgEventKey, int> send_event_key = std::make_pair(
        std::make_pair(flow.tag, std::make_pair(send_event.src_id, send_event.dst_id)), flow_id);
    HTSimSession::send_waiting[send_event_key] = send_event;

    // Offline flow-event log (ASTRASIM_HTSIM_FLOW_LOG): capture simulator-time
    // t_start so the finish hook can emit (src, dst, size, t_start, t_end).
    FlowLogger::instance().record_start(
        static_cast<uint32_t>(flow_id),
        static_cast<uint64_t>(get_time_ns()));

    // Create a queue pair and schedule within the HTSim simulator.
    impl->schedule_htsim_event(flow, flow_id);
}

// notify_receiver_receive_data looks at whether the astra-sim has issued
// sim_recv for this message. If the system layer is waiting for this message,
// call the callback handler for the MsgEvent. If the system layer is not *yet*
// waiting for this message, register that this message has arrived,
// so that the system layer can later call the callback handler when sim_recv
// is called.
void HTSimSession::notify_receiver_receive_data(int src_id,
                                                int dst_id,
                                                int message_size,
                                                int tag,
                                                int flow_id) {
    MsgEventKey recv_expect_event_key = make_pair(tag, make_pair(src_id, dst_id));

    if (HTSimSession::recv_waiting.find(recv_expect_event_key) !=
        HTSimSession::recv_waiting.end()) {
        // The Sys object is waiting for packets to arrive.
        MsgEvent recv_expect_event = recv_waiting[recv_expect_event_key];
        if (message_size == recv_expect_event.remaining_msg_bytes) {
            // We received exactly the amount of data what Sys object was expecting.
            HTSimSession::recv_waiting.erase(recv_expect_event_key);
            recv_expect_event.callHandler();
        } else if (message_size > recv_expect_event.remaining_msg_bytes) {
            // We received more packets than the Sys object is expecting.
            // Place task in received_msg_standby_hash and wait for Sys object to issue more sim_recv
            // calls. Call callback handler for the amount Sys object was waiting for.
            HTSimSession::msg_standby[recv_expect_event_key] = message_size - recv_expect_event.remaining_msg_bytes;
            HTSimSession::recv_waiting.erase(recv_expect_event_key);
            recv_expect_event.callHandler();
        } else {
            // There are still packets to arrive.
            // Reduce the number of packets we are waiting for. Do not call callback
            // handler.
            recv_expect_event.remaining_msg_bytes -= message_size;
            HTSimSession::recv_waiting[recv_expect_event_key] = recv_expect_event;
        }
    } else {
        // The Sys object is not yet waiting for packets to arrive.
        if (HTSimSession::msg_standby.find(recv_expect_event_key) ==
            HTSimSession::msg_standby.end()) {
            // Place task in msg_standby and wait for Sys object to issue more sim_recv
            // calls.
            HTSimSession::msg_standby[recv_expect_event_key] = message_size;
        } else {
            // Sys object is still waiting. Add number of bytes we are waiting for.
            HTSimSession::msg_standby[recv_expect_event_key] += message_size;
        }
    }

    // Add to the number of total bytes received.
    if (HTSimSession::node_bytes_sent.find(make_pair(dst_id, Dir::Receive)) ==
        HTSimSession::node_bytes_sent.end()) {
        HTSimSession::node_bytes_sent[make_pair(dst_id, Dir::Receive)] = message_size;
    } else {
        HTSimSession::node_bytes_sent[make_pair(dst_id, Dir::Receive)] += message_size;
    }
}

void HTSimSession::notify_sender_sending_finished(int src_id,
                                                  int dst_id,
                                                  int message_size,
                                                  int tag,
                                                  int flow_id) {
    // Lookup the send_event registered at send_flow().
    std::pair<MsgEventKey, int> send_event_key =
        make_pair(make_pair(tag, make_pair(src_id, dst_id)), flow_id);
    if (HTSimSession::send_waiting.find(send_event_key) == HTSimSession::send_waiting.end()) {
        std::cerr << "Cannot find send_event in sent_hash. Something is wrong."
             << "src_id, dst_id: " << src_id << " " << dst_id << " : " << tag << " - " << flow_id
             << "\n";
        assert(0 && "notify_sender_sending_finished failed");
    }

    // Verify that the (HTSim identified) sent message size matches what was
    // expected by the system layer.
    MsgEvent send_event = HTSimSession::send_waiting[send_event_key];
    HTSimSession::send_waiting.erase(send_event_key);

    // Add to the number of total bytes sent.
    if (HTSimSession::node_bytes_sent.find(make_pair(src_id, Dir::Send)) ==
        HTSimSession::node_bytes_sent.end()) {
        HTSimSession::node_bytes_sent[make_pair(src_id, Dir::Send)] = message_size;
    } else {
        HTSimSession::node_bytes_sent[make_pair(src_id, Dir::Send)] += message_size;
    }
    send_event.callHandler();
}

// flow_finish is triggered by HTSim to indicate that a flow has finished.
// Registered as the callback handler for the source
// instance created at send_flow.
void HTSimSession::flow_finish_send(int src_id, int dst_id, int msg_size, int flow_id) {

    // Offline flow-event log: record end-of-flow.  `flow_finish_send` is
    // always called exactly once per flow across tcp / roce / hpcc.
    FlowLogger::instance().record_finish(
        static_cast<uint32_t>(flow_id), src_id, dst_id,
        static_cast<uint32_t>(msg_size),
        static_cast<uint64_t>(instance().get_time_ns()));

    int tag = flow_id_to_tag[flow_id];
    // Let sender knows that the flow has finished.
    notify_sender_sending_finished(src_id, dst_id, msg_size, tag, flow_id);

    if (!conf.recv_flow_finish) {
        // Let receiver knows that it has received packets.
        notify_receiver_receive_data(src_id, dst_id, msg_size, tag, flow_id);
    }
}

// flow_finish is triggered by HTSim to indicate that a flow has finished.
// Registered as the callback handler for the sink
// instance created at send_flow.
void HTSimSession::flow_finish_recv(int src_id, int dst_id, int msg_size, int flow_id) {

    if (conf.recv_flow_finish) {
        int tag = flow_id_to_tag[flow_id];
        // Let receiver knows that it has received packets.
        notify_receiver_receive_data(src_id, dst_id, msg_size, tag, flow_id);
    }

}

void HTSimSession::finish() {
    FlowLogger::instance().close();
    impl->finish();
}

void HTSimSession::stop_simulation() {
    impl->stop_simulation();
}

void HTSimSession::HTSimSessionImpl::stop_simulation() {
    std::cout << "HTSim stopping simulation..." << std::endl;
    auto now = eventlist.now();
    eventlist.setEndtime(now);
}

// Constructor creates inner impl
HTSimSession& HTSimSession::init(const HTSim::tm_info* const tm, const int argc, char** argv, const HTSimProto proto) {
    if (session != nullptr)
        assert(0 && "HTSim session initialized twice");
    static HTSimSession session_(tm, argc, argv, proto);
    session = &session_;
    return session_;
};

// Instance getter
HTSimSession& HTSimSession::instance() {
    if (session == nullptr)
        assert(0 && "HTSim session not initialized");
    return (*session);
}

HTSimSession::HTSimSession(const HTSim::tm_info* const tm, int argc, char** argv, HTSimProto proto) {
    switch(proto) {
        case HTSimProto::Tcp:
            impl = std::make_unique<HTSimProtoTcp>(tm, argc, argv);
            break;
        case HTSimProto::RoCE:
            impl = std::make_unique<HTSimProtoRoCE>(tm, argc, argv);
            break;
        case HTSimProto::DCQCN:
            // Phase 3.1b (U3) — full DCQCN CC now live:
            //   (a) CompositeQueue marks ECN_CE in-band (configure
            //       thresholds via ASTRASIM_HTSIM_DCQCN_KMIN_KB/KMAX_KB);
            //   (b) RoceSink echoes ECN_CE → ECN_ECHO on the ACK;
            //   (c) RoceSrc runs AIMD on ECN_ECHO / unmarked windows
            //       (enable_dcqcn in roce.cpp).
            {
                if (!std::getenv("ASTRASIM_HTSIM_QUEUE_TYPE")) {
                    // Default to composite so DCQCN's ECN marking path is actually
                    // exercised.  Users can override back to lossless / random.
                    setenv("ASTRASIM_HTSIM_QUEUE_TYPE", "composite", 1);
                }
                // Gate the AIMD CC logic in HTSimProtoRoCE on DCQCN selection.
                // HTSimProtoRoCE reads ASTRASIM_HTSIM_DCQCN_AIMD and calls
                // RoceSrc::enable_dcqcn() per flow when set.
                if (!std::getenv("ASTRASIM_HTSIM_DCQCN_AIMD")) {
                    setenv("ASTRASIM_HTSIM_DCQCN_AIMD", "1", 1);
                }
                std::cout << "[dcqcn] Note: CC enabled — CompositeQueue ECN "
                          << "marking + RoceSink ECN echo + RoceSrc AIMD. "
                          << "Tunables: ASTRASIM_HTSIM_DCQCN_{KMIN_KB,KMAX_KB,"
                          << "AI_MBPS,MIN_MBPS,BYTES,G_RECIP}\n";
            }
            impl = std::make_unique<HTSimProtoRoCE>(tm, argc, argv);
            break;
        case HTSimProto::HPCC:
            // U4 — native HPCC via htsim's HPCCSrc / HPCCSink + CompositeQueue
            // INT path. HTSimProtoHPCC ctor force-selects QUEUE_TYPE=composite.
            impl = std::make_unique<HTSimProtoHPCC>(tm, argc, argv);
            break;
        default:
            std::cerr << "Unknown HTSim protocol" << std::endl;
            abort();
    }
}

void HTSimSession::schedule_astra_event(long double when_ns,
                                        void (*msg_handler)(void* fun_arg),
                                        void* fun_arg) {
    AstraEventSrc* src = new AstraEventSrc(msg_handler, fun_arg, impl->eventlist);
    astra_events.push_back(src);
    impl->eventlist.sourceIsPendingRel(*src, timeFromNs(when_ns));
}

// Wrapper functions

void HTSimSession::run(const HTSim::tm_info* const tm) {
    impl->run(tm);
}

double HTSimSession::get_time_ns() {
    return timeAsNs(impl->eventlist.now());
}

double HTSimSession::get_time_us() {
    return timeAsUs(impl->eventlist.now());
}

HTSimSession::~HTSimSession() {}

} // namespace HTSim