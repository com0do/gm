// summary.cxx -- mean, standard deviation and nearest-rank percentiles.
#include <tm/stats.hpp>

#include <algorithm>
#include <cmath>
#include <numeric>
#include <vector>

namespace telemetry {

Summary summarize(const double *samples, std::size_t n)
{
    if (n == 0)
        return {};

    std::vector<double> v(samples, samples + n);
    std::sort(v.begin(), v.end());

    Summary s;
    s.count = n;
    s.mean = std::accumulate(v.begin(), v.end(), 0.0) / static_cast<double>(n);
    const double squares = std::accumulate(v.begin(), v.end(), 0.0,
                                           [mean = s.mean](double sum, auto x) { return sum + (x - mean) * (x - mean); });
    s.stddev = std::sqrt(squares / static_cast<double>(n));
    s.min = v.front();
    s.max = v.back();
    s.p50 = v[nearest_rank(0.50, n) - 1];
    s.p95 = v[nearest_rank(0.95, n) - 1];
    return s;
}

}  // namespace telemetry
