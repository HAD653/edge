#!/usr/bin/env python3
"""Measure the WHOOP 5 substrate pagination optimization without a bracelet.

    python3 tool/benchmark_whoop5_paging.py --hours 36 --repeats 5

Uses synthetic, in-memory SQLite rows and the production read's projection,
predicate, ordering, and (rec_ts, counter) index. Every page is compared before
timing complete walks of one sleep-search window. These timings measure query
work only, not BLE, Dart/native serialization, staging, or whole-sync latency.
"""

import argparse
import json
import sqlite3
import statistics
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=36)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--page-size", type=int, default=2000)
    args = parser.parse_args()
    if args.hours <= 0 or args.repeats < 1 or args.page_size < 1:
        parser.error("hours, repeats, and page-size must be positive")

    count = max(1, round(args.hours * 3600))
    start = 1700000000
    end = start + count - 1
    db = sqlite3.connect(":memory:")
    db.execute("""
        CREATE TABLE decoded_onehz (
            device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL,
            counter INTEGER NOT NULL, rec_ts INTEGER NOT NULL, hr INTEGER,
            ax REAL, ay REAL, az REAL, spo2_red_raw INTEGER,
            spo2_ir_raw INTEGER, skin_temp_raw INTEGER, step_count INTEGER,
            step_cadence REAL, activity_class INTEGER, skin_temp_c REAL,
            on_wrist INTEGER, hr_valid INTEGER, hr_alt INTEGER,
            device_family TEXT, band_sleep_state INTEGER, source TEXT,
            PRIMARY KEY (device_id, ts_ms))
    """)
    db.execute("CREATE INDEX idx_decoded_onehz_rects "
               "ON decoded_onehz(rec_ts, counter)")
    db.executemany("""
        INSERT INTO decoded_onehz
            (ts_ms, counter, rec_ts, hr, ax, ay, az, step_count,
             skin_temp_c, hr_valid, device_family)
        VALUES (?, ?, ?, 61, 0.05, 0.05, 0.99, ?, 33.3, 1, 'gen5')
    """, (((start + i) * 1000, i % 65536, start + i, i // 10)
          for i in range(count)))
    db.commit()

    projection = (
        "SELECT counter, rec_ts, hr, ax, ay, az, spo2_red_raw, spo2_ir_raw, "
        "skin_temp_raw, step_count, step_cadence, activity_class, skin_temp_c, "
        "on_wrist, hr_valid, hr_alt, device_family, device_id, band_sleep_state "
        "FROM decoded_onehz WHERE rec_ts >= ? AND rec_ts <= ? "
        "AND source IS NULL "
    )
    ordering = "ORDER BY rec_ts ASC, counter ASC LIMIT ?"
    first = projection + ordering
    paged = (projection + "AND (rec_ts > ? OR (rec_ts = ? AND counter > ?)) "
             + ordering)

    def page(cursor, optimized):
        if cursor is None:
            return db.execute(first, (start, end, args.page_size)).fetchall()
        ts, counter = cursor
        lower = max(start, ts) if optimized else start
        return db.execute(paged, (
            lower, end, ts, ts, counter, args.page_size)).fetchall()

    cursor = None
    pages = 0
    while True:
        before = page(cursor, False)
        after = page(cursor, True)
        assert before == after, f"different output on page {pages}"
        if not before:
            break
        pages += 1
        cursor = (before[-1][1], before[-1][0])

    def walk(optimized):
        cursor = None
        seen = 0
        started = time.perf_counter()
        while True:
            rows = page(cursor, optimized)
            if not rows:
                break
            seen += len(rows)
            cursor = (rows[-1][1], rows[-1][0])
        elapsed = (time.perf_counter() - started) * 1000
        assert seen == count
        return elapsed

    # Alternate order so one variant does not always get the warmer cache.
    old = []
    new = []
    for repeat in range(args.repeats):
        for optimized in ([False, True] if repeat % 2 == 0 else [True, False]):
            (new if optimized else old).append(walk(optimized))
    old_ms, new_ms = statistics.median(old), statistics.median(new)
    print(json.dumps({
        "sqlite_version": sqlite3.sqlite_version,
        "synthetic_window_hours": args.hours,
        "rows": count,
        "pages": pages,
        "page_size": args.page_size,
        "identical_pages": True,
        "original_walk_median_ms": round(old_ms, 2),
        "whoop5_walk_median_ms": round(new_ms, 2),
        "query_speedup": round(old_ms / new_ms, 2),
        "scope": "SQLite query work only; not whole-sync latency",
    }, indent=2))
    db.close()


if __name__ == "__main__":
    main()
