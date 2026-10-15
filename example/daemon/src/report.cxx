// report.cxx -- the JSON snapshot, written with minijson (third_party/minijson, vendor-built).
#include "report.hpp"

#include <minijson.h>
#include <minijson_file.h>

#include <array>
#include <string>
#include <utility>

namespace tmd {
namespace {

// The statistics of a Summary, in the order they are written.
constexpr std::array<std::pair<const char *, double telemetry::Summary::*>, 6> kStats{{
    {"mean", &telemetry::Summary::mean},
    {"stddev", &telemetry::Summary::stddev},
    {"min", &telemetry::Summary::min},
    {"max", &telemetry::Summary::max},
    {"p50", &telemetry::Summary::p50},
    {"p95", &telemetry::Summary::p95},
}};

// minijson is C: its writer, freed whichever way the function is left.
struct Writer {
    mj_writer w;
    Writer() noexcept { mj_init(&w); }
    ~Writer() { mj_free(&w); }
    Writer(const Writer &) = delete;
    Writer &operator=(const Writer &) = delete;
};

}  // namespace

bool write_snapshot(const std::string &path, const Snapshot &s)
{
    Writer doc;
    mj_writer *w = &doc.w;
    auto key = [w](const char *k) { mj_key(w, k); };
    auto number = [&](const char *k, double v) { key(k); mj_number(w, v); };
    auto integer = [&](const char *k, auto v) { key(k); mj_integer(w, static_cast<long long>(v)); };
    auto text = [&](const char *k, const std::string &v) { key(k); mj_string(w, v.c_str()); };

    mj_object_begin(w);
    text("tmd", std::string(s.version));
    integer("samples", s.samples);
    integer("malformed", s.malformed);

    key("metrics");
    mj_object_begin(w);
    for (const auto &[name, window] : s.metrics) {
        const telemetry::Summary sum = window.summary();
        key(name.c_str());
        mj_object_begin(w);
        integer("count", sum.count);
        for (const auto &[stat, member] : kStats)
            number(stat, sum.*member);
        mj_object_end(w);
    }
    mj_object_end(w);

    key("alarms");
    mj_array_begin(w);
    for (const ActiveAlarm &a : s.alarms) {
        mj_object_begin(w);
        integer("number", a.number);
        text("name", a.name);
        text("severity", a.severity);
        text("metric", a.metric);
        number("value", a.value);
        number("limit", a.limit);
        mj_object_end(w);
    }
    mj_array_end(w);
    mj_object_end(w);

    return mj_write_file(w, path.c_str()) == 0;
}

}  // namespace tmd
