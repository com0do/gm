// report.hpp -- the JSON snapshot tmd writes.
#pragma once

#include <tm/stats.hpp>

#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace tmd {

struct ActiveAlarm {
    unsigned number;
    std::string name;
    std::string severity;
    std::string metric;
    double value;
    double limit;
};

struct Snapshot {
    std::string_view version;
    std::uint64_t samples;
    std::uint64_t malformed;
    const std::map<std::string, telemetry::Window, std::less<>> &metrics;
    const std::vector<ActiveAlarm> &alarms;
};

// Writes the snapshot to path ("-": standard output).  false with errno set on failure.
[[nodiscard]] bool write_snapshot(const std::string &path, const Snapshot &s);

}  // namespace tmd
