#include "execution_profiler.h"
#include <limits>
#include <algorithm>

ExecutionProfiler::ExecutionProfiler(const std::vector<std::string>& labels) {
    for (auto& label : labels) {
        summaries[label] = {
            0,
            std::numeric_limits<int64_t>::max(),
            0,
            0,
            0
        };
    }
}

void ExecutionProfiler::StartTimer(const std::string& label) {
    timers[label] = std::chrono::high_resolution_clock::now();
    active_timers.insert(label);
}

void ExecutionProfiler::StopTimer(const std::string& label) {
    if (active_timers.find(label) == std::end(active_timers)) return;
    active_timers.erase(label);

    auto start = timers[label];
    auto stop = std::chrono::high_resolution_clock::now();

    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(stop - start).count();

    auto& summary = summaries[label];

    summary.measurements += 1;
    summary.total_time += duration;
    summary.max_time = std::max(summary.max_time, duration);
    summary.min_time = std::min(summary.min_time, duration);
    summary.average_time = summary.total_time / summary.measurements;
}
