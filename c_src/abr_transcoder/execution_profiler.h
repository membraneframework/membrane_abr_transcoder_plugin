#pragma once

#include <chrono>
#include <vector>
#include <string>
#include <unordered_map>
#include <unordered_set>

class ExecutionProfiler {
    struct ProfilingSummary {
        int64_t max_time;
        int64_t min_time;
        int64_t average_time;
        int64_t total_time;
        int64_t measurements;
    };

public:
    ExecutionProfiler(const std::vector<std::string>& labels);

    void StartTimer(const std::string& label);
    void StopTimer(const std::string& label);

    ProfilingSummary Summary(const std::string& label) const { return summaries.at(label); }
    const std::unordered_map<std::string, ProfilingSummary>& Summaries() const { return summaries; }
private:
    std::unordered_map<std::string, ProfilingSummary>  summaries;
    std::unordered_map<std::string, std::chrono::system_clock::time_point> timers;
    std::unordered_set<std::string> active_timers;
};
