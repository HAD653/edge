import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('scheduler did not progress');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'openstrap_whoop5_derive_queue_test.db';
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });
  setUp(() async => (await LocalDb.instance).delete('compute_jobs'));
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  DeriveScheduler make({
    required Future<void> Function({required DeriveJobKind kind}) run,
    bool Function()? optimize,
    Duration settle = const Duration(milliseconds: 10),
  }) {
    final scheduler = DeriveScheduler(
      run: run,
      log: (_) {},
      onChanged: () {},
      optimizeWhoop5: optimize,
      lightSettle: settle,
      heavySettle: settle,
    );
    addTearDown(() async {
      scheduler.dispose();
      await _until(() => !scheduler.running);
      // Finish the final snapshot before the next test empties the DB.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    return scheduler;
  }

  test(
    'WHOOP 5 starts after the short window; other generations keep pacing',
    () async {
      var whoop5 = false;
      var calls = 0;
      final scheduler = make(
        run: ({required kind}) async => calls++,
        optimize: () => whoop5,
        settle: const Duration(seconds: 3),
      );
      await scheduler.init();
      scheduler.markStoredData();
      await _until(() => scheduler.pendingLight);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(calls, 0);
      // Discovery can confirm the generation after the scheduler was created.
      scheduler.setOffloadActive(true);
      whoop5 = true;
      scheduler.setOffloadActive(false);
      await _until(() => calls == 1);
      await _until(() => !scheduler.running);
    },
  );

  test(
    'one acquisition owns the lane while requests and releases overlap',
    () async {
      final claim = Completer<void>();
      var claims = 0;
      final runs = <DeriveJobKind>[];
      final scheduler = make(run: ({required kind}) async => runs.add(kind));
      scheduler.debugBeforeClaim = () {
        claims++;
        return claim.future;
      };
      await scheduler.init();
      scheduler.markStoredData();
      await _until(() => claims == 1);
      expect(scheduler.running, isTrue);
      scheduler.requestHeavy();
      await _until(() => scheduler.pendingHeavy);
      scheduler.setOffloadActive(true);
      scheduler.setOffloadActive(false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        claims,
        1,
        reason: 'acquisition must serialize before the DB await',
      );
      claim.complete();
      await _until(() => runs.isNotEmpty && !scheduler.running);
      expect(runs, [DeriveJobKind.heavy]);
    },
  );

  test(
    'capture beginning during acquisition returns the job without attempt',
    () async {
      final claim = Completer<void>();
      var claiming = false;
      var runs = 0;
      final scheduler = make(run: ({required kind}) async => runs++);
      scheduler.debugBeforeClaim = () {
        claiming = true;
        return claim.future;
      };
      await scheduler.init();
      scheduler.markStoredData();
      await _until(() => claiming);
      scheduler.setOffloadActive(true);
      claim.complete();
      await _until(() => !scheduler.running && scheduler.pendingLight);
      expect(runs, 0);
      final queued = await LocalDb.computeJobs(state: 'queued');
      expect(queued.single['attempts'], 0);
      scheduler.setOffloadActive(false);
      await _until(() => runs == 1 && !scheduler.running);
    },
  );

  test(
    'enqueue during a stale snapshot rereads before publishing its flags',
    () async {
      final snapshot = Completer<void>();
      var reads = 0;
      final runs = <DeriveJobKind>[];
      final scheduler = make(run: ({required kind}) async => runs.add(kind));
      await scheduler.init();
      scheduler.setOffloadActive(true);
      scheduler.debugAfterSnapshotRead = () {
        reads++;
        return reads == 1 ? snapshot.future : Future<void>.value();
      };
      scheduler.markStoredData();
      await _until(() => reads == 1);
      scheduler.requestHeavy();
      // A real durable upgrade lands while the first query holds the old light.
      while ((await LocalDb.computeJobs(state: 'queued')).single['type'] !=
          'derive_heavy') {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      snapshot.complete();
      await _until(() => scheduler.pendingHeavy);
      expect(reads, greaterThanOrEqualTo(2));
      expect(scheduler.pendingLight, isFalse);
      scheduler.setOffloadActive(false);
      await _until(() => runs.isNotEmpty && !scheduler.running);
      expect(runs, [DeriveJobKind.heavy]);
    },
  );

  test(
    'data arriving during a heavy pass keeps its own follow-up job',
    () async {
      final heavy = Completer<void>();
      final runs = <DeriveJobKind>[];
      final scheduler = make(
        optimize: () => true,
        run: ({required kind}) async {
          runs.add(kind);
          if (kind == DeriveJobKind.heavy) await heavy.future;
        },
      );
      await scheduler.init();
      scheduler.requestHeavy();
      await _until(() => runs.isNotEmpty);
      scheduler.markStoredData();
      await _until(() => scheduler.pendingLight);
      heavy.complete();
      await _until(() => runs.length == 2 && !scheduler.running);
      expect(runs, [DeriveJobKind.heavy, DeriveJobKind.light]);
    },
  );

  for (final whoop5 in [false, true]) {
    test('a requeued light predating the heavy claim is coalesced only for '
        'WHOOP 5 (gate=$whoop5)', () async {
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
      final light = (await LocalDb.takeNextComputeJob())!;
      // Capture closes while acquisition is in flight. The heavy request
      // arrives before the scheduler returns the light to the durable queue.
      await LocalDb.enqueueDeriveJob(type: 'derive_heavy', reason: 'test');
      await LocalDb.requeueComputeJob(light['id'].toString());
      expect(await LocalDb.computeJobs(state: 'queued'), hasLength(2));
      final runs = <DeriveJobKind>[];
      final scheduler = make(
        run: ({required kind}) async => runs.add(kind),
        optimize: () => whoop5,
      );
      await scheduler.init();
      await _until(
        () =>
            runs.length == (whoop5 ? 1 : 2) &&
            !scheduler.running &&
            !scheduler.pendingLight,
      );
      expect(
        runs,
        whoop5
            ? [DeriveJobKind.heavy]
            : [DeriveJobKind.heavy, DeriveJobKind.light],
      );
    });
  }

  test(
    'dispose while claiming returns durable work and never runs it',
    () async {
      final claim = Completer<void>();
      var claiming = false;
      var runs = 0;
      final scheduler = make(run: ({required kind}) async => runs++);
      scheduler.debugBeforeClaim = () {
        claiming = true;
        return claim.future;
      };
      await scheduler.init();
      scheduler.markStoredData();
      await _until(() => claiming);
      scheduler.dispose();
      claim.complete();
      await _until(() => !scheduler.running);
      expect(runs, 0);
      expect(await LocalDb.computeJobs(state: 'queued'), hasLength(1));
    },
  );
}
