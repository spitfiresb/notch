#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

output="${1:-.build/benchmarks/codex-$(date -u +%Y%m%dT%H%M%SZ).json}"
mkdir -p "$(dirname "$output")"
swift --version > "${output%.json}.environment.txt" 2>&1
sw_vers >> "${output%.json}.environment.txt"
sysctl -n hw.model hw.memsize hw.ncpu >> "${output%.json}.environment.txt"
git rev-parse HEAD >> "${output%.json}.environment.txt"
git status --short >> "${output%.json}.environment.txt"
shasum -a 256 Sources/Notch/Services/CodexSessionMonitor.swift \
    Sources/Notch/Services/AgentSessions.swift \
    Tests/NotchRenderTests/CodexPerformanceTests.swift >> "${output%.json}.environment.txt"

NOTCH_CODEX_BENCHMARK=1 NOTCH_BENCHMARK_OUTPUT="$output" \
    swift test -c release --filter CodexPerformanceTests/testCodexMonitoringBenchmark
