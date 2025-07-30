#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Battery performance test script.

This script benchmarks the performance of different battery monitoring implementations.
"""

import statistics
import time
from typing import Callable, List, Tuple

from batteryguardian.modules.battery import get_ac_status, get_battery_percentage
from batteryguardian.modules.battery_monitor import get_battery_status


def run_test(
    name: str,
    test_func: Callable[[], Tuple[int, str]],
    iterations: int = 10,
    runs: int = 5,
) -> float:
    """Run a performance benchmark test."""
    print(f"Testing {name}...")

    # Clear cache if test_func is the standard implementation
    if name == "Standard implementation":
        from batteryguardian.modules.battery import _cached_battery_status

        _cached_battery_status.cache_clear()

    times: List[float] = []
    for i in range(runs):
        # Clear cache before each run to ensure fair testing
        if name == "Standard implementation":
            from batteryguardian.modules.battery import _cached_battery_status

            _cached_battery_status.cache_clear()

        start = time.time()
        for _ in range(iterations):
            test_func()
        duration = time.time() - start
        times.append(duration)
        print(f"  Run {i + 1}: {duration * 1000:.2f}ms for {iterations} checks")

    avg = statistics.mean(times)
    print(f"\n{name} average: {avg * 1000:.2f}ms ({avg * 100:.2f}ms per check)\n")
    return avg


def test_standard() -> Tuple[int, str]:
    """Standard implementation test function."""
    percent = get_battery_percentage()
    status = get_ac_status()
    return percent, status


print("=== Battery Monitoring Performance Benchmark ===\n")

# Run the standard implementation test
std_avg = run_test("Standard implementation", test_standard)

# Run the optimized implementation test
opt_avg = run_test("Optimized implementation", get_battery_status)

# Calculate improvement
improvement = std_avg / opt_avg if opt_avg > 0 else 0
print(f"Performance improvement: {improvement:.2f}x faster")
improvement = std_avg / opt_avg if opt_avg > 0 else 0
print(f"Performance improvement: {improvement:.2f}x faster")
