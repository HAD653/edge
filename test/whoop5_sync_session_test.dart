import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'whoop5_sync_session.db';

void _whoop5(SyncRig rig) {
  rig.app.paired = PairedDevice(kRemoteId, kSerial, generation: 'gen5');
  rig.engine.state.generation = 'gen5';
}

Future<void> _openWhoop5(SyncRig rig) async {
  _whoop5(rig);
  await rig.app.openSession();
  await rig.waitFor(() => rig.engine.count('prompt') == 2);
  await rig.jobQueued('derive_heavy');
  await rig.waitFor(() => rig.timers!
      .activeOneShot(const Duration(milliseconds: 250)).isNotEmpty);
  await rig.clearJobs();
  rig.engine.events.clear();
}

void Function() _sessionCase(
  Future<void> Function(SyncRig rig, SyncTimers timers) body,
) => () async {
  final timers = SyncTimers(minOneShot: const Duration(milliseconds: 250));
  late SyncRig rig;
  try {
    await timers.run(() async {
      rig = SyncRig(timers: timers);
      await body(rig, timers);
    });
  } finally {
    // Cleanup's real 250-ms settling wait must run outside the timer zone.
    await rig.close();
  }
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test(
    'a WHOOP 5 duplicate foreground open pulls only the missing history',
    _sessionCase((rig, timers) async {
      await _openWhoop5(rig);

      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.jobQueued('derive_light');
      await rig.quiesce();

      expect(rig.engine.events, [
        'setBackground:false',
        'requestForegroundSync',
        'runSync:180',
      ]);
      expect(await rig.jobTypes(), ['derive_light']);
      expect(rig.app.busy, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
    }),
  );

  test(
    'a WHOOP 5 rapid foreground open does not poll or derive again',
    _sessionCase((rig, timers) async {
      await _openWhoop5(rig);
      rig.engine.foregroundSyncAllowed = false;

      await rig.app.openSession();
      await rig.quiesce();

      expect(rig.engine.events, [
        'setBackground:false',
        'requestForegroundSync',
      ]);
      expect(await rig.jobTypes(), isEmpty);
    }),
  );

  test(
    'a WHOOP 5 duplicate foreground open leaves its running burst alone',
    _sessionCase((rig, timers) async {
      _whoop5(rig);
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.events.clear();

      await rig.app.openSession();
      await rig.quiesce();

      expect(rig.engine.events, ['setBackground:false']);
      expect(await rig.jobTypes(), isEmpty);
      expect(rig.app.busy, isFalse);

      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
      expect(
        rig.engine.count('runSync'),
        0,
        reason: 'only the original burst ran before events were cleared',
      );
    }),
  );

  test(
    'a WHOOP 5 duplicate open still probes a quiet link before reuse',
    _sessionCase((rig, timers) async {
      await _openWhoop5(rig);
      rig.engine.quiet = const Duration(minutes: 20);
      rig.engine.probeAnswer = true;
      rig.engine.foregroundSyncAllowed = false;

      await rig.app.openSession();
      await rig.quiesce();

      expect(rig.engine.events, [
        'setBackground:false',
        'probe',
        'requestForegroundSync',
      ]);
      expect(rig.engine.count('connect'), 0);
      expect(await rig.jobTypes(), isEmpty);
    }),
  );

  test(
    'a WHOOP 5 stale link is recovered rather than falsely reused',
    _sessionCase((rig, timers) async {
      await _openWhoop5(rig);
      rig.engine.quiet = const Duration(minutes: 20);
      rig.engine.probeAnswer = false;

      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.quiesce();

      expect(rig.engine.count('probe'), 1);
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('requestForegroundSync'), 0);
      expect(
        rig.engine.events.indexOf('disconnect'),
        lessThan(rig.engine.events.indexOf('connect:$kRemoteId:gen5')),
      );
    }),
  );

  test(
    'discovered WHOOP 4 overrides a stale WHOOP 5 pairing hint',
    _sessionCase((rig, timers) async {
      await rig.openAndSettle();
      await rig.clearJobs();
      rig.engine.events.clear();
      rig.app.paired = PairedDevice(kRemoteId, kSerial, generation: 'gen5');
      rig.engine.state.generation = 'gen4';

      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');

      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.count('requestForegroundSync'), 0);
    }),
  );
}
