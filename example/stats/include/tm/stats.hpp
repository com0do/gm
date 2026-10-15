// tm/stats.hpp -- summary statistics over a sliding window of samples.
#pragma once

#include <tm/core.h>

#include <cstddef>
#include <cstdint>
#include <iterator>
#include <string_view>

namespace telemetry {

inline constexpr std::size_t kDefaultWindow = 120;  // samples per metric, when not configured

struct Summary {
    std::size_t count = 0;
    double mean = 0;
    double stddev = 0;  // population standard deviation
    double min = 0;
    double max = 0;
    double p50 = 0;     // nearest-rank percentiles
    double p95 = 0;
};

// The 1-based rank of the q-quantile among n sorted samples (nearest-rank method): the smallest
// rank with at least a fraction q of the samples at or below it.  constexpr: tests check it
// with static_assert.
constexpr std::size_t nearest_rank(double q, std::size_t n)
{
    const double exact = q * static_cast<double>(n);
    std::size_t rank = static_cast<std::size_t>(exact);
    if (static_cast<double>(rank) < exact)
        ++rank;
    return rank == 0 ? 1 : rank;
}

// Summary of n samples in any order; all zero when n is 0.
[[nodiscard]] Summary summarize(const double *samples, std::size_t n);

// Any contiguous container of doubles: std::vector, std::array, a C array.
template <typename Container>
[[nodiscard]] Summary summarize(const Container &samples)
{
    return summarize(std::data(samples), std::size(samples));
}

// The last `size` samples of one metric, kept in libtmcore's ring.
class Window {
public:
    explicit Window(std::size_t size = kDefaultWindow);  // std::invalid_argument unless 1..TM_RING_MAX
    void push(double v) noexcept { tm_ring_push(&ring_, v); }
    [[nodiscard]] Summary summary() const;
    [[nodiscard]] std::uint64_t total() const noexcept { return ring_.total; }

private:
    tm_ring ring_;
};

// "libtmstats, shipped in pkg-tm-devel 1.4.0-1 and pkg-tmd 1.4.0-1" -- a string literal.
[[nodiscard]] std::string_view version() noexcept;

}  // namespace telemetry
