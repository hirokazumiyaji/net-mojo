"""Timing for one existing multiplex sibling batch, independent of fixture drain."""

import time


def begin_sibling_window():
    before = time.perf_counter()
    epoch = time.time()
    start = time.perf_counter()
    return start, epoch, start - before


def sibling_metrics(records, valid, window, observed_end):
    start, epoch, span = window
    records = list(records)
    completed = [
        record for record in records
        if isinstance(record, dict)
        and record.get("start") is not None
        and record.get("done_at") is not None
        and start <= record["start"] <= record["done_at"] <= observed_end
    ]
    samples = [record for record in completed if valid(record)]
    all_completed = bool(records) and len(samples) == len(records)
    end = max(record["done_at"] for record in samples) if all_completed else observed_end
    duration = end - start
    latencies = sorted((record["done_at"] - record["start"]) * 1_000_000 for record in samples)
    stats = {
        "sibling_samples": len(samples),
        "sibling_completed": len(completed),
        "sibling_missing_timing": len(records) - len(completed),
        "sibling_req_s": len(samples) / duration if duration > 0 else None,
        "sibling_window_s": duration,
        "sibling_window_start_unix_s": epoch + span / 2,
        "sibling_window_end_unix_s": epoch + span / 2 + duration,
        "sibling_clock_anchor_span_s": span,
        "sibling_clock_anchor_uncertainty_s": span / 2,
        "sibling_window_scope": "all_completed" if all_completed else "failed_phase_observation",
    }
    for percentile, fraction in ((50, 0.50), (95, 0.95), (99, 0.99)):
        stats[f"sibling_p{percentile}_us"] = latencies[int(fraction * (len(latencies) - 1))] if latencies else None
    return stats
