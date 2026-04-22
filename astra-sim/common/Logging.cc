#include "astra-sim/common/Logging.hh"
#include <filesystem>

namespace AstraSim {

std::unordered_set<spdlog::sink_ptr> LoggerFactory::default_sinks;

std::shared_ptr<spdlog::logger> LoggerFactory::get_logger(
    const std::string& logger_name) {
    constexpr bool ENABLE_DEFAULT_SINK_FOR_OTHER_LOGGERS = true;
    auto logger = spdlog::get(logger_name);
    if (logger == nullptr) {
        logger = spdlog::create_async<spdlog::sinks::null_sink_mt>(logger_name);
        logger->set_level(spdlog::level::trace);
        // Default: flush only on err (shutdown will drain remaining async
        // messages at exit). Set ASTRASIM_FLUSH_ON=(trace|debug|info|warn|err)
        // to flush at a lower level — useful for long acceptance runs
        // where the only way to see "sys[X] finished" progress before the
        // process exits is to flush on info-level writes.
        spdlog::level::level_enum flush_lvl = spdlog::level::err;
        if (const char* env = std::getenv("ASTRASIM_FLUSH_ON")) {
            std::string v{env};
            for (auto& c : v) c = static_cast<char>(std::tolower(c));
            if (v == "trace") flush_lvl = spdlog::level::trace;
            else if (v == "debug") flush_lvl = spdlog::level::debug;
            else if (v == "info") flush_lvl = spdlog::level::info;
            else if (v == "warn") flush_lvl = spdlog::level::warn;
            else if (v == "err" || v == "error") flush_lvl = spdlog::level::err;
            else if (v == "off") flush_lvl = spdlog::level::off;
        }
        logger->flush_on(flush_lvl);
    }
    if constexpr (!ENABLE_DEFAULT_SINK_FOR_OTHER_LOGGERS) {
        return logger;
    }
    auto& logger_sinks = logger->sinks();
    for (auto sink : default_sinks) {
        if (std::find(logger_sinks.begin(), logger_sinks.end(), sink) ==
            logger_sinks.end()) {
            logger_sinks.push_back(sink);
        }
    }
    return logger;
}

void LoggerFactory::init(const std::string& log_config_path,
                         const std::string& log_path) {
    if (log_config_path != "empty") {
        spdlog_setup::from_file(log_config_path);
    }
    init_default_components(log_path);
}

void LoggerFactory::shutdown(void) {
    default_sinks.clear();
    spdlog::drop_all();
    spdlog::shutdown();
}

void LoggerFactory::init_default_components(const std::string& log_path) {
    std::filesystem::path folderPath(log_path);

    if (!std::filesystem::exists(folderPath)) {
        std::filesystem::create_directory(folderPath);
    }

    auto sink_color_console =
        std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
    sink_color_console->set_level(spdlog::level::info);
    default_sinks.insert(sink_color_console);

    // The rotating file sink can emit hundreds of thousands of debug lines
    // per second on large workloads (e.g. megatron_gpt_39b @ 256 NPU).
    // On short-simtime runs this is tolerable; on long-simtime acceptance
    // runs it becomes a wall-time multiplier and masks real progress.
    // Gate with ASTRASIM_LOG_LEVEL=(debug|info|warn|err|off) — default
    // keeps the historical "debug into log.log" behaviour.
    auto sink_rotate_out =
        std::make_shared<spdlog::sinks::rotating_file_sink_mt>(
            log_path + "/log.log", 1024 * 1024 * 10, 10);
    spdlog::level::level_enum file_level = spdlog::level::debug;
    if (const char* env = std::getenv("ASTRASIM_LOG_LEVEL")) {
        std::string v{env};
        for (auto& c : v) c = static_cast<char>(std::tolower(c));
        if (v == "trace") file_level = spdlog::level::trace;
        else if (v == "debug") file_level = spdlog::level::debug;
        else if (v == "info") file_level = spdlog::level::info;
        else if (v == "warn") file_level = spdlog::level::warn;
        else if (v == "err" || v == "error") file_level = spdlog::level::err;
        else if (v == "off") file_level = spdlog::level::off;
    }
    sink_rotate_out->set_level(file_level);
    default_sinks.insert(sink_rotate_out);

    auto sink_rotate_err =
        std::make_shared<spdlog::sinks::rotating_file_sink_mt>(
            log_path + "/err.log", 1024 * 1024 * 10, 10);
    sink_rotate_err->set_level(spdlog::level::err);
    default_sinks.insert(sink_rotate_err);

    spdlog::init_thread_pool(8192, 1);
    spdlog::set_pattern("[%Y-%m-%dT%T%z] [%L] <%n>: %v");
}

}  // namespace AstraSim
