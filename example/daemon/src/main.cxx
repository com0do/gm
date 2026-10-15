// tmd -- the telemetry daemon.
//
// Reads `metric value` lines (standard input, or --input), keeps the last `window` samples of
// every metric, raises an alarm when a sample goes above its threshold and clears it when a
// sample is back at or below, and writes a JSON snapshot of all windows: every `report_every`
// samples and at the end of the input.  --fail-fast aborts on a MAJOR or CRITICAL alarm, for
// test runs that want a core file (gm core).
#include "config.hpp"
#include "report.hpp"

#include <tm/stats.hpp>

// Generated from pkg-tmd's pkg.yaml: the alarm table (libtmalarms) and the package identity
// (PKG_HEADERS := yes in tmd.mk).
#include <pkg-tmd/alarms.h>
#include <pkg-tmd/component.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

namespace alarms = gm_alarms_pkg_tmd;

constexpr std::string_view kVersion = TMD_PKG_VERSION "-" TMD_PKG_RELEASE;

enum class Severity { Other, Warning, Minor, Major, Critical };

Severity severity_of(std::string_view s) noexcept
{
    if (s == "CRITICAL") return Severity::Critical;
    if (s == "MAJOR") return Severity::Major;
    if (s == "MINOR") return Severity::Minor;
    if (s == "WARNING") return Severity::Warning;
    return Severity::Other;
}

// One stderr line from any number of pieces.
template <typename... Parts>
void say(const Parts &...parts)
{
    std::cerr << "tmd: ";
    (std::cerr << ... << parts) << '\n';
}

struct Options {
    std::string config = "tmd.conf";
    std::string input;           // empty: standard input
    std::string output = "-";
    bool fail_fast = false;
};

struct Sample {
    std::string metric;
    double value;
};

// `metric value`, nothing more; std::nullopt for anything else.
std::optional<Sample> parse_sample(const std::string &line)
{
    std::istringstream fields(line);
    Sample s;
    std::string rest;
    if (!(fields >> s.metric >> s.value) || (fields >> rest))
        return std::nullopt;
    return s;
}

int usage()
{
    std::cerr << "usage: tmd [--config FILE] [--input FILE] [--output FILE] [--fail-fast]\n"
                 "       tmd --version | --list-alarms\n";
    return 2;
}

const alarms::AlarmDef &alarm_def(unsigned number)
{
    for (std::size_t i = 0; i < alarms::alarms_count; ++i)
        if (alarms::alarms[i].number == number)
            return alarms::alarms[i];
    throw std::logic_error("alarm " + std::to_string(number) + " is not in pkg.yaml");
}

class Daemon {
public:
    Daemon(tmd::Config cfg, Options opt) : cfg_(std::move(cfg)), opt_(std::move(opt)) {}
    Daemon(const Daemon &) = delete;
    Daemon &operator=(const Daemon &) = delete;

    // `metric` is the metric, or what the alarm is about (a file, an input line) when limit is 0.
    void raise(unsigned number, const std::string &metric, double value, double limit)
    {
        const alarms::AlarmDef &def = alarm_def(number);
        if (limit != 0)
            say("ALARM ", def.number, ' ', def.severity, ' ', def.name, ' ', metric, '=', value,
                " (limit ", limit, "): ", def.short_text);
        else
            say("ALARM ", def.number, ' ', def.severity, ' ', def.name, ' ', metric, ": ", def.short_text);
        active_.push_back({def.number, def.name, def.severity, metric, value, limit});
        if (opt_.fail_fast && severity_of(def.severity) >= Severity::Major)
            std::abort();
    }

    void sample(const std::string &metric, double value)
    {
        windows_.try_emplace(metric, cfg_.window).first->second.push(value);
        ++samples_;

        if (const auto limit = cfg_.thresholds.find(metric); limit != cfg_.thresholds.end()) {
            const bool above = value > limit->second;
            if (above && breached_.insert(metric).second)
                raise(alarms::kTmThresholdExceeded, metric, value, limit->second);
            else if (!above && breached_.erase(metric))
                clear(alarms::kTmThresholdExceeded, metric, value);
        }
        if (cfg_.report_every && samples_ % cfg_.report_every == 0)
            report();
    }

    void malformed(std::uint64_t lineno)
    {
        if (malformed_++ == 0)
            raise(alarms::kTmInputMalformed, "line " + std::to_string(lineno), 0, 0);
    }

    bool report()
    {
        const tmd::Snapshot s{kVersion, samples_, malformed_, windows_, active_};
        if (tmd::write_snapshot(opt_.output, s))
            return true;
        say(opt_.output, ": ", std::strerror(errno));
        return false;
    }

private:
    void clear(unsigned number, const std::string &metric, double value)
    {
        const alarms::AlarmDef &def = alarm_def(number);
        say("CLEAR ", def.number, ' ', def.name, ' ', metric, '=', value);
        for (auto a = active_.begin(); a != active_.end(); ++a)
            if (a->number == number && a->metric == metric) {
                active_.erase(a);
                break;
            }
    }

    tmd::Config cfg_;
    Options opt_;
    std::map<std::string, telemetry::Window, std::less<>> windows_;
    std::set<std::string, std::less<>> breached_;
    std::vector<tmd::ActiveAlarm> active_;
    std::uint64_t samples_ = 0;
    std::uint64_t malformed_ = 0;
};

int run(const Options &opt)
{
    tmd::Config cfg;
    const bool have_config = tmd::load_config(opt.config, cfg);
    Daemon d(cfg, opt);
    if (!have_config)
        d.raise(alarms::kTmConfigMissing, opt.config, 0, 0);

    std::unique_ptr<std::ifstream> file;
    if (!opt.input.empty()) {
        file = std::make_unique<std::ifstream>(opt.input);
        if (!*file) {
            say(opt.input, ": ", std::strerror(errno));
            return 1;
        }
    }
    std::istream &in = file ? *file : std::cin;

    std::string line;
    std::uint64_t lineno = 0;
    while (std::getline(in, line)) {
        ++lineno;
        if (line.empty() || line[0] == '#')
            continue;
        if (const auto s = parse_sample(line))
            d.sample(s->metric, s->value);
        else
            d.malformed(lineno);
    }
    return d.report() ? 0 : 1;
}

void list_alarms()
{
    std::cout << TMD_PKG_NAME << " defines " << alarms::alarms_count << " alarm(s):\n";
    for (std::size_t i = 0; i < alarms::alarms_count; ++i) {
        const alarms::AlarmDef &a = alarms::alarms[i];
        std::cout << "  " << a.number << "  " << a.severity << '\t' << a.name << '\t' << a.short_text << '\n';
    }
}

}  // namespace

int main(int argc, char **argv)
{
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string_view arg = argv[i];
        const bool has_value = i + 1 < argc;
        if (arg == "--version") {
            std::cout << "tmd " << kVersion << " (" << TMD_PKG_NAME << ", " << TMD_NAME << ")\n"
                      << telemetry::version() << '\n'
                      << tm_core_version() << '\n';
            return 0;
        }
        if (arg == "--list-alarms") {
            list_alarms();
            return 0;
        }
        if (arg == "--fail-fast")
            opt.fail_fast = true;
        else if (arg == "--config" && has_value)
            opt.config = argv[++i];
        else if (arg == "--input" && has_value)
            opt.input = argv[++i];
        else if (arg == "--output" && has_value)
            opt.output = argv[++i];
        else
            return usage();
    }
    try {
        return run(opt);
    } catch (const std::exception &e) {
        say(e.what());
        return 1;
    }
}
