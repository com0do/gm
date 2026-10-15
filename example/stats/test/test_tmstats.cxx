// Unit tests for libtmstats.
#include <gtest/gtest.h>
#include <tm/stats.hpp>

#include <array>
#include <stdexcept>
#include <vector>

using telemetry::nearest_rank;
using telemetry::Summary;
using telemetry::Window;

// nearest_rank is constexpr: these hold at compile time.
static_assert(nearest_rank(0.50, 8) == 4);
static_assert(nearest_rank(0.95, 8) == 8);
static_assert(nearest_rank(0.95, 100) == 95);
static_assert(nearest_rank(0.00, 5) == 1);

TEST(Summary, OfNothingIsAllZero) {
    const Summary s = telemetry::summarize(nullptr, 0);
    EXPECT_EQ(s.count, 0u);
    EXPECT_DOUBLE_EQ(s.mean, 0);
}

TEST(Summary, OfAKnownSet) {
    // Mean 5, population standard deviation exactly 2.
    const double v[] = {9, 2, 4, 4, 4, 5, 5, 7};
    const auto [count, mean, stddev, min, max, p50, p95] = telemetry::summarize(v);
    EXPECT_EQ(count, 8u);
    EXPECT_DOUBLE_EQ(mean, 5);
    EXPECT_DOUBLE_EQ(stddev, 2);
    EXPECT_DOUBLE_EQ(min, 2);
    EXPECT_DOUBLE_EQ(max, 9);
    EXPECT_DOUBLE_EQ(p50, 4);  // 4 of the 8 samples are <= 4
    EXPECT_DOUBLE_EQ(p95, 9);
}

TEST(Summary, TakesAnyContiguousContainer) {
    const std::vector<double> vec{1, 2, 3};
    const std::array<double, 3> arr{1, 2, 3};
    EXPECT_DOUBLE_EQ(telemetry::summarize(vec).mean, 2);
    EXPECT_DOUBLE_EQ(telemetry::summarize(arr).mean, 2);
}

TEST(Window, SummarizesOnlyTheLastSamples) {
    Window w(4);
    for (int i = 1; i <= 10; ++i)
        w.push(i);
    const Summary s = w.summary();
    EXPECT_EQ(s.count, 4u);
    EXPECT_DOUBLE_EQ(s.mean, 8.5);  // 7 8 9 10
    EXPECT_EQ(w.total(), 10u);
}

TEST(Window, RejectsASizeOfZero) {
    EXPECT_THROW({ Window w(0); }, std::invalid_argument);
}

TEST(Version, NamesBothPackagesThatShipTheLibrary) {
    const std::string_view v = telemetry::version();
    EXPECT_NE(v.find("pkg-tmd 1.4.0-"), std::string_view::npos) << v;
    EXPECT_NE(v.find("pkg-tm-devel 1.4.0-"), std::string_view::npos) << v;
}
