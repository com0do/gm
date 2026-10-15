// config.cxx -- tmd.conf, read with libini (third_party/ini).
#include "config.hpp"

#include <ini.h>

#include <charconv>
#include <cstdlib>
#include <stdexcept>
#include <string_view>

namespace tmd {
namespace {

struct Parse {
    Config *cfg;
    std::string error;
};

double number(std::string_view name, const char *value)
{
    char *end;
    const double v = std::strtod(value, &end);
    if (end == value || *end)
        throw std::runtime_error(std::string(name) + ": not a number: '" + value + "'");
    return v;
}

std::size_t count(std::string_view name, std::string_view value)
{
    std::size_t n = 0;
    const auto [rest, ec] = std::from_chars(value.data(), value.data() + value.size(), n);
    if (ec != std::errc() || rest != value.data() + value.size())
        throw std::runtime_error(std::string(name) + ": not a count: '" + std::string(value) + "'");
    return n;
}

// libini calls this for every `name = value`; exceptions must not cross its C frames.
int on_value(void *user, const char *section, const char *name, const char *value)
{
    auto *p = static_cast<Parse *>(user);
    const std::string_view sec = section, key = name;
    try {
        if (sec == "daemon" && key == "window")
            p->cfg->window = count(key, value);
        else if (sec == "daemon" && key == "report_every")
            p->cfg->report_every = count(key, value);
        else if (sec == "thresholds")
            p->cfg->thresholds.insert_or_assign(std::string(key), number(key, value));
        else
            throw std::runtime_error("unknown setting [" + std::string(sec) + "] " + std::string(key));
    } catch (const std::exception &e) {
        p->error = e.what();
        return 0;
    }
    return 1;
}

}  // namespace

bool load_config(const std::string &path, Config &cfg)
{
    Parse p{&cfg, {}};
    if (const int rc = ini_parse(path.c_str(), on_value, &p); rc < 0)
        return false;
    else if (rc > 0)
        throw std::runtime_error(path + ":" + std::to_string(rc) + ": " +
                                 (p.error.empty() ? "syntax error" : p.error));
    return true;
}

}  // namespace tmd
