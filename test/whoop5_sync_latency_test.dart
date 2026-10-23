import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

DrainController _drain({CommitSyncBatchSink? commit}) => DrainController(
  onRecord: (_, _) async {},
  onRecordsBatch: null,
  onCommit:
      commit ??
      (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {},
  onArchive: null,
  log: (_) {},
);

RawRecord _raw(int n) => RawRecord(
  counter: n,
  packetType: PacketType.historicalData,
  hex: '2f18',
  capturedAt: 1786000000000 + n,
  recTs: 1786000000 + n,
);

void main() {
  group('WHOOP 5 reactive drain completion', () {
    test('already completed history resolves without a one-second tick', () {
      fakeAsync((async) {
        final d = _drain()..onComplete();
        SyncReport? report;
        d
            .awaitComplete(isLinkUp: () => true, reactive: true)
            .then((r) => report = r);
        async.flushMicrotasks();
        expect(report?.complete, isTrue);
        expect(async.elapsed, Duration.zero);
        expect(async.periodicTimerCount, 0);
      });
    });

    test('completion at 25 ms resolves at 25 ms rather than the 1 s poll', () {
      fakeAsync((async) {
        final d = _drain();
        SyncReport? report;
        d
            .awaitComplete(isLinkUp: () => true, reactive: true)
            .then((r) => report = r);
        async.elapse(const Duration(milliseconds: 25));
        d.onComplete();
        async.flushMicrotasks();
        expect(report?.complete, isTrue);
        expect(async.elapsed, const Duration(milliseconds: 25));
        expect(async.periodicTimerCount, 0);
      });
    });

    test('terminal and link down release waiters without a timer tick', () {
      for (final terminate in <void Function(DrainController)>[
        (d) => d.onTaskTerminal(),
        (d) => d.onLinkDown(),
      ]) {
        fakeAsync((async) {
          final d = _drain();
          SyncReport? report;
          d
              .awaitComplete(isLinkUp: () => true, reactive: true)
              .then((r) => report = r);
          async.flushMicrotasks();
          expect(report, isNull);
          terminate(d);
          async.flushMicrotasks();
          expect(report?.complete, isFalse);
          expect(async.periodicTimerCount, 0);
        });
      }
    });

    test('completion then immediate claim never flushes replacement rows', () {
      fakeAsync((async) {
        final commits = <int>[];
        final d = _drain(
          commit:
              (
                raws,
                samples,
                token, {
                archives,
                ecgRawPackets,
                deviceFamily,
              }) async {
                commits.add(raws.length);
              },
        );
        SyncReport? report;
        d
            .awaitComplete(isLinkUp: () => true, reactive: true)
            .then((r) => report = r);
        d.onHistoricalRecord(_raw(1), null, 18);
        // Production already committed this task's tail before onComplete.
        d.commit(null);
        async.flushMicrotasks();
        commits.clear();
        d.onComplete();
        d.startFreshTask();
        d.onHistoricalRecord(_raw(2), null, 18);
        async.flushMicrotasks();
        expect((report?.complete, report?.records), (true, 1));
        expect(commits, isEmpty);
        expect(d.bufferedRecords, 1);
      });
    });

    test('overlapping event and timer cannot start a second final flush', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        var commits = 0;
        final d = _drain(
          commit:
              (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) {
                commits++;
                return gate.future;
              },
        );
        SyncReport? report;
        d
            .awaitComplete(isLinkUp: () => true, reactive: true)
            .then((r) => report = r);
        d.onHistoricalRecord(_raw(1), null, 18);
        d.onComplete();
        async.flushMicrotasks();
        d.onComplete();
        d.onLinkDown();
        async.elapse(const Duration(seconds: 2));
        expect(commits, 1);
        expect(report, isNull);
        gate.complete();
        async.flushMicrotasks();
        expect((report?.complete, report?.records), (true, 1));
        expect(async.periodicTimerCount, 0);
      });
    });

    test(
      'failed final flush re-buffers rows for a subsequent durable commit',
      () {
        fakeAsync((async) {
          var fail = true;
          final d = _drain(
            commit:
                (
                  raws,
                  samples,
                  token, {
                  archives,
                  ecgRawPackets,
                  deviceFamily,
                }) async {
                  if (fail) throw StateError('rollback');
                },
          );
          d.onHistoricalRecord(_raw(1), null, 18);
          d.onComplete();
          SyncReport? report;
          d
              .awaitComplete(isLinkUp: () => true, reactive: true)
              .then((r) => report = r);
          async.flushMicrotasks();
          expect(report, isNotNull);
          expect(
            report?.complete,
            isFalse,
            reason: 'a failed final durable commit cannot report sync success',
          );
          expect(d.bufferedRecords, 1);
          fail = false;
          bool? durable;
          d
              .commit(const [1, 2, 3, 4, 5, 6, 7, 8])
              .then((value) => durable = value);
          async.flushMicrotasks();
          expect(durable, isTrue);
          expect(d.bufferedRecords, 0);
        });
      },
    );

    test('a new task cannot mask an old waiter final commit failure', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        final d = _drain(
          commit:
              (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) =>
                  gate.future,
        );
        d.onHistoricalRecord(_raw(1), null, 18);
        SyncReport? report;
        d
            .awaitComplete(isLinkUp: () => true, reactive: true)
            .then((r) => report = r);
        d.onComplete();
        async.flushMicrotasks(); // final flush is now parked
        d.startFreshTask();
        d.onHistoricalRecord(_raw(2), null, 18);
        gate.completeError(StateError('old task tail rolled back'));
        async.flushMicrotasks();
        expect((report?.complete, report?.records), (false, 1));
        expect(
          d.bufferedRecords,
          2,
          reason: 'rollback restores the old row ahead of the new row',
        );
        expect(async.periodicTimerCount, 0);
      });
    });

    test('idle and deadline still stop a quiet connected drain', () {
      for (final timeout in [
        const Duration(seconds: 2),
        const Duration(minutes: 2),
      ]) {
        fakeAsync((async) {
          final d = _drain();
          SyncReport? report;
          d
              .awaitComplete(
                isLinkUp: () => true,
                reactive: true,
                timeout: timeout,
              )
              .then((r) => report = r);
          async.elapse(
            timeout.inSeconds < 60 ? timeout : const Duration(seconds: 60),
          );
          expect(report?.complete, isFalse);
          expect(async.periodicTimerCount, 0);
        });
      }
    });

    test('runSync enables reactivity only on WHOOP 5', () {
      for (final band in [BandProfile.gen5, BandProfile.gen4]) {
        fakeAsync((async) {
          final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
          engine.debugLedgerWriteHook = () async {};
          engine.debugInstallFakeLink(onWrite: (_) async => true, band: band);
          engine.debugDrain!.onComplete();
          SyncReport? report;
          engine.runSync().then((r) => report = r);
          async.flushMicrotasks();
          expect(report?.complete, band.isGen5 ? isTrue : isNull);
          async.elapse(const Duration(seconds: 1));
          expect(report?.complete, isTrue);
          expect(async.periodicTimerCount, 0);
        });
      }
    });
  });

  group('bounded WHOOP 5 success diagnostics', () {
    test('1000 pending successes retain only the newest snapshot', () async {
      final gate = Completer<void>();
      final seen = <int>[];
      final queue = CoalescingWorkQueue(onError: (_) {});
      queue.addLatest(() async {
        seen.add(0);
        await gate.future;
      });
      for (var i = 1; i <= 1000; i++) {
        final n = i;
        queue.addLatest(() async => seen.add(n));
      }
      expect(queue.pendingCount, 1);
      gate.complete();
      await queue.add(() async {});
      expect(seen, [0, 1000]);
    });

    test(
      'failure seals pending progress and later success keeps ordering',
      () async {
        final gate = Completer<void>();
        final seen = <String>[];
        final queue = CoalescingWorkQueue(onError: (_) {});
        queue.addLatest(() => gate.future);
        queue.addLatest(() async => seen.add('old success'));
        final failure = queue.add(() async => seen.add('failure'));
        queue.addLatest(() async => seen.add('new success'));
        gate.complete();
        await failure;
        await queue.add(() async {});
        expect(seen, ['old success', 'failure', 'new success']);
      },
    );

    test(
      'teardown discards pending success while preserving failure',
      () async {
        final gate = Completer<void>();
        final seen = <String>[];
        final queue = CoalescingWorkQueue(onError: (_) {});
        queue.addLatest(() => gate.future);
        queue.addLatest(() async => seen.add('old progress'));
        final failure = queue.add(() async => seen.add('failure'));
        queue.addLatest(() async => seen.add('closing link'));
        queue.discardLatest();
        queue.addLatest(() async => seen.add('new link'));
        gate.complete();
        await failure;
        await queue.add(() async {});
        expect(seen, ['old progress', 'failure', 'new link']);
      },
    );

    test(
      'throwing sink and reporter cannot wedge or escape the queue',
      () async {
        final seen = <String>[];
        final queue = CoalescingWorkQueue(
          onError: (e) {
            seen.add('error');
            throw StateError('reporter also failed');
          },
        );
        queue.addLatest(() async => throw StateError('sink failed'));
        await queue.add(() async => seen.add('next'));
        expect(seen, ['error', 'next']);
      },
    );
  });

  test('WHOOP 5 ACKs next burst while diagnostic sink is blocked; '
      'teardown prevents old progress writing into replacement link', () async {
    final gate = Completer<void>();
    final events = <String>[];
    var diagnosticCalls = 0;
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugLedgerWriteHook = () async {
      diagnosticCalls++;
      if (diagnosticCalls == 1) await gate.future;
    };
    void connect() => engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      onCommit:
          (
            raws,
            samples,
            token, {
            archives,
            ecgRawPackets,
            deviceFamily,
          }) async {
            if (token != null) events.add('commit:$token');
          },
      onWrite: (bytes) async {
        final f = parseFrame(bytes, profile: BandProfile.gen5)!;
        if (f.inner[2] == Cmd.historicalDataResult && f.inner[3] == 1) {
          events.add('ack:${f.inner.sublist(4).join(',')}');
        }
        return true;
      },
    );
    connect();
    engine.debugClaimHistoryTask();
    void burst(int token) {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final data = Uint8List(kGen5V18InnerLen);
      final v = ByteData.sublistView(data);
      data[0] = PacketType.historicalData;
      data[1] = 18;
      data[2] = 0x80;
      v.setUint32(3, token, Endian.little);
      v.setUint32(7, ts, Endian.little);
      data[14] = 64;
      v.setFloat32(33, 0.5, Endian.little);
      v.setFloat32(45, 1.0, Endian.little);
      final end = Uint8List(24);
      final ev = ByteData.sublistView(end);
      end[0] = PacketType.metadata;
      end[1] = 2;
      end[2] = SyncMeta.historyEnd;
      ev.setUint32(9, 1, Endian.little);
      ev.setUint32(13, token, Endian.little);
      ev.setUint32(17, 0x18, Endian.little);
      for (final inner in [
        Uint8List.fromList([PacketType.metadata, 1, SyncMeta.historyStart]),
        data,
        end,
      ]) {
        engine.debugReceiveFrame(Frame(inner, true, true));
      }
    }

    for (var n = 1; n <= 3; n++) {
      burst(n);
      await pumpEventQueue();
    }
    expect(events, [
      'commit:0100000018000000',
      'ack:1,0,0,0,24,0,0,0',
      'commit:0200000018000000',
      'ack:2,0,0,0,24,0,0,0',
      'commit:0300000018000000',
      'ack:3,0,0,0,24,0,0,0',
    ]);
    expect(
      diagnosticCalls,
      1,
      reason: 'a slow diagnostic write cannot block another safe ACK',
    );
    await engine.disconnect();
    gate.complete();
    await pumpEventQueue();
    expect(
      diagnosticCalls,
      1,
      reason: 'pending old progress and the old snapshot tail are dropped',
    );
    connect();
    engine.debugClaimHistoryTask();
    burst(4);
    await pumpEventQueue();
    expect(events.sublist(6), [
      'commit:0400000018000000',
      'ack:4,0,0,0,24,0,0,0',
    ]);
    expect(diagnosticCalls, 3);
    await engine.disconnect();
  });
}
