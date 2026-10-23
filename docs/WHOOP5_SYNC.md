# WHOOP 5 sync performance

The performance switches apply only when the connected band's discovered
generation is `gen5`, or its saved pairing says `gen5` before discovery. A
discovered generation overrides that hint. No analytics formulas, sibling pins,
schema versions, or `kAlgoVersion` change in this pass.

| Path | Change |
| --- | --- |
| Transfer completion | WHOOP 5 drain waiters react to COMPLETE, task termination, and disconnection immediately. The one-second poll remains for idle/deadline detection. |
| Transfer diagnostics | Successful chunk diagnostics run outside the frame receive path, retaining one active and the latest pending progress snapshot. Failure and recovered-token records retain their ordering. Closing a link discards its pending progress callbacks. |
| Durability failure | A WHOOP 5 waiter reports an incomplete sync if its final commit fails, including when another history task starts during that commit. The failed rows remain buffered. |
| Compute scheduling | WHOOP 5 coalesces for 250 ms after capture releases its gate, replacing the extra 8-second light / 2-second heavy settle. Existing BLE debounce, workout holds, and iOS background deferral remain active. |
| Compute queue | Acquisition holds the scheduler lane before awaiting the database. Snapshot readers share the in-flight read and repeat it when new work arrives. A WHOOP 5 heavy claim absorbs pre-existing queued light work in its transaction; data arriving during that heavy pass retains a follow-up job. |
| Substrate reads | Subsequent pages start their indexed timestamp range at the current cursor, avoiding repeated scans of earlier pages. The predicates, ordering, and rows returned are unchanged. |
| First visible results | Home reloads the first persisted day and today's day while older days continue computing. The existing freshness and provisional-night gates run first, reading metadata without expanding curves or recounting the raw tables. Publication also precedes workout rescoring; changed sessions and baseline rescans publish another revision. |
| Repeated foreground events | An already-configured WHOOP 5 connection uses the normal liveness check and floored catch-up, avoiding repeated setup and an unnecessary heavy calculation. |
| iOS background tasks | WHOOP 5 skips the intermediate light pass and runs the background task's chosen light/heavy pass once after all sensor inputs land. Other headless wake sources retain their light pass. |

Decoded data and the history cursor still commit atomically before the exact
eight-byte HISTORY_END token is acknowledged. Nothing acknowledges a partial
chunk. Raw-data retention and metric absence rules are unchanged.

## Reproduce the query measurement

```sh
python3 tool/benchmark_whoop5_paging.py --hours 36 --repeats 5
```

This builds 129,600 synthetic seconds in an in-memory SQLite database, compares
every returned page, then alternates timing the original and optimized walks
over 65 pages. One local run with SQLite 3.54.0 measured median query times of
477.83 ms before and 179.08 ms after (2.67 times faster). Another run measured
455.82 ms and 211.21 ms (2.16 times faster). Timings depend on the host and load.
These measure SQLite query work, not BLE radio throughput, phone performance,
native serialization, or total sync duration.

The reactive-drain fake-clock test measures COMPLETE at 25 ms resolving at
25 ms, instead of the original next tick at 1,000 ms. A blocked diagnostic-sink
test verifies that three bursts still commit and ACK with their exact tokens.
The bounded-queue test retains the first and last of 1,001 progress snapshots
when the first write is blocked.

`test/whoop_freeze_golden_test.dart` enables the optimized read path for gen5
and compares stored metrics, payload hashes, and cross-day output against the
existing goldens. Do not regenerate those goldens to accept this optimization.

No physical WHOOP 5 was used to measure this change. Device-to-device radio
timing and end-to-end speedup still require a run on the user's bracelet.

## Validation

`flutter analyze --no-pub` reported no issues. The complete 509-file test suite
ran serially within three isolated copies of the same source snapshot, so their
SQLite test databases could not collide: 6,220 tests passed, 23 were skipped,
and two failed. One failure exposed a new disposed-scheduler guard that dropped
a durable follow-up job. Removing that guard restored the original queueing
behavior; a fresh final-source run of all 19 affected sync/lifecycle test files
passed all 280 tests, including that regression. The final scheduler also
passed targeted static analysis. No other Dart source changed after the broad
suite snapshot.

The remaining failure is pre-existing on macOS:
`health_workout_export_delete_gate_test.dart` expects a non-Apple host for its
`delete=false` assertion, while `HealthExporter.isApple` is true on Darwin.
Fresh isolated runs of both the modified source and original HEAD `189ec375`
each produced the same nine passes and one failure. Health export code and its
test are unchanged by this optimization.

The stored-output goldens also passed with the optimized gen5 read path in
UTC, Asia/Kolkata, and America/New_York, without regenerating any golden file.

## When the app checks for data

These are the existing scheduling rules, not newly increased polling rates:

| Situation | Trigger / interval |
| --- | --- |
| Initial connection | History starts after subscription and bootstrap. |
| App stays in foreground | Controller catch-up timer every 10 minutes; skipped when disconnected, reconnecting, busy, or another sync burst is running. |
| Foreground return | Catch-up on the current connection, with at least 90 seconds since the previous offload request. A stale connection is probed or reconnected. |
| Explicit manual sync | Requests a pull without the foreground cadence floor; history command writes still respect their five-second protocol floor. |
| Connected engine | Additional periodic trigger every 15 minutes, coalesced/rate-limited against previous requests; repeated empty transfers can back off. |
| iOS background, link retained | Bracelet notification prompts every 15 minutes. Their two-hour lease is renewed by the existing wake-window policy. |
| Smart wake window | Bracelet prompts every 61 seconds. Offloads still have a 90-second event floor, with backoff after empty transfers, so each prompt need not start a transfer. |
| iOS BGProcessing / BGAppRefresh | Requested no earlier than 10 minutes later; iOS chooses the actual execution time. |
| Lost link | Bluetooth events and reconnect retries, plus a one-minute reconnect supervisor while the process is executing. |
| Link maintenance | 30-second liveness/keep-alive tick; this is not a full historical-data sync. |

Dart timers do not keep running while iOS fully suspends the process. The
bracelet's notifications, CoreBluetooth restoration, and OS background tasks
provide the wake opportunities. Capture can continue during background wakes;
ordinary AppState derivation is held while iOS is backgrounded and resumed on
foreground return. An explicit OS background task also attempts its bounded
light/heavy calculation. Consequently, seeing “Crunching last night's numbers”
on opening the app does not mean no data was captured in the background.

Apple documents that
[earliestBeginDate is a lower bound, not a promised launch time](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate).
[Bluetooth restoration also depends on pending events and app/device state](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).
