#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Benchmark for measuring first-call performance of battery status checking.

This script performs a more realistic benchmark focusing on fresh calls
to battery status functions, avoiding caching effects.
"""

import statistics
import time
from typing import Callable, List, Tuple


def clear_all_lru_caches():
    """Clear all LRU caches in the battery module to ensure fresh reads."""
    # Import late to ensure we can clear the cache before benchmarking
    from batteryguardian.modules.battery import (
        _cached_battery_status,
        get_ac_status,
        get_battery_percentage,
    )

    _cached_battery_status.cache_clear()

    # These might be decorated with lru_cache
    if hasattr(get_battery_percentage, "cache_clear"):
        get_battery_percentage.cache_clear()
    if hasattr(get_ac_status, "cache_clear"):
        get_ac_status.cache_clear()


def test_fresh_standard() -> Tuple[int, str]:
    """Test standard implementation with fresh filesystem reads."""
    # Import inside function to avoid module-level caching
    from batteryguardian.modules.battery import get_ac_status, get_battery_percentage

    # Clear any cached data
    clear_all_lru_caches()

    # Perform a fresh read
    percent = get_battery_percentage()
    status = get_ac_status()
    return percent, status


def test_fresh_optimized() -> Tuple[int, str]:
    """Test optimized implementation with fresh file descriptor reads."""
    # Import inside function to avoid module-level object reuse
    from batteryguardian.modules.battery_monitor import get_battery_status

    # Get a fresh status reading
    return get_battery_status()


def run_fresh_benchmark(
    name: str, test_func: Callable[[], Tuple[int, str]], runs: int = 10
) -> float:
    """Run a benchmark measuring first-call performance."""
    print(f"Testing fresh calls to {name}...")

    times: List[float] = []
    results = []

    for i in range(runs):
        start = time.time()
        result = test_func()  # Run just once per timing
        duration = time.time() - start
        times.append(duration)
        results.append(result)
        print(f"  Run {i + 1}: {duration * 1000:.2f}ms - Result: {result}")

    avg = statistics.mean(times)
    print(f"\n{name} average: {avg * 1000:.2f}ms per fresh check\n")
    return avg


def main():
    """Run the benchmarks."""
    print("=== Battery Monitoring First-Call Performance Benchmark ===\n")

    # Test standard implementation (fresh reads)
    std_avg = run_fresh_benchmark("Standard implementation", test_fresh_standard)

    # Test optimized implementation (file descriptor based)
    opt_avg = run_fresh_benchmark("Optimized implementation", test_fresh_optimized)

    # Calculate improvement
    improvement = std_avg / opt_avg if opt_avg > 0 else 0
    if improvement >= 1.0:
        print(
            f"Performance improvement: {improvement:.2f}x faster with optimized implementation"
        )
    else:
        print(
            f"Performance result: Optimized implementation is {1 / improvement:.2f}x slower"
        )


if __name__ == "__main__":
    main()
