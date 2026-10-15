// config.hpp -- tmd.conf.
#pragma once

#include <tm/stats.hpp>

#include <cstddef>
#include <map>
#include <string>

namespace tmd {

struct Config {
    std::size_t window = telemetry::kDefaultWindow;  // samples kept per metric
    std::size_t report_every = 0;                    // a snapshot every N samples; 0: at the end only
    std::map<std::string, double, std::less<>> thresholds;  // metric -> alarm above this value
};

// Reads `path` into cfg.  false when the file cannot be opened; std::runtime_error on a bad line.
[[nodiscard]] bool load_config(const std::string &path, Config &cfg);

}  // namespace tmd
