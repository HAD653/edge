import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final logs = <String>[];
  var notifies = 0;
  var phoneSteps = 0;
  var recoveryChecks = 0;
  var exports = 0;
  var reclaims = 0;

  setUp(() {
    logs.clear();
    notifies = 0;
    phoneSteps = 0;
    recoveryChecks = 0;
    exports = 0;
    reclaims = 0;
  });

  DeriveCoordinator make({
    bool Function()? background,
    bool Function()? disposed,
    bool healthSync = false,
    Future<int> Function()? runHealthExport,
    bool Function()? optimizeWhoop5,
    Future<void> Function()? refreshComputeFreshness,
    LocalRepository? repo,
  }) =>
      DeriveCoordinator(
        // Every test installs a debug hook for the engine calls, so any real
        // engine access is a laziness regression.
        derive: () => throw StateError('derive should stay lazy'),
        profile: () => const Profile(),
        repo: () => repo,
        background: background ?? () => false,
        disposed: disposed ?? () => false,
        log: logs.add,
        notify: () => notifies++,
        refreshPhoneStepsToday: () async => phoneSteps++,
        maybeNotifyRecoveryReady: () async => recoveryChecks++,
        runHealthExport: runHealthExport ??
            () async {
              exports++;
              return 2;
            },
        healthSyncEnabled: () => healthSync,
        telemetryConsent: () => false,
        healthShareConsent: () => false,
        maybeReclaimDiskSpace: () async => reclaims++,
        optimizeWhoop5: optimizeWhoop5,
        refreshComputeFreshness: refreshComputeFreshness,
      );

  test('constructing the coordinator and its scheduler never touches derive',
      () {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    expect(coordinator.scheduler, isNotNull);
    expect(coordinator.insightsRevision.value, 0);
  });

  test('a light pass notifies, bumps once and skips the heavy-only work',
      () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    final calls = <bool>[];
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      calls.add(heavy);
      return 0;
    };
    var rescans = 0;
    coordinator.debugRescanRecent = (_) async {
      rescans++;
      return 0;
    };

    await coordinator.afterDrain();
    await Future<void>.delayed(Duration.zero);

    expect(calls, [false]);
    expect(rescans, 0);
    expect(coordinator.insightsRevision.value, 1);
    expect(notifies, 1);
    expect(phoneSteps, 1);
    expect(recoveryChecks, 1);
    expect(reclaims, 0);
    expect(exports, 0);
  });

  test('a heavy pass awaits the rescan, then reclaims disk space', () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    final rescan = Completer<int>();
    coordinator.debugRescanRecent = (_) => rescan.future;

    var finished = false;
    final heavy =
        coordinator.afterDrain(heavy: true).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse, reason: 'the pass must wait for the rescan');
    expect(reclaims, 0);
    final notifiesBeforeRescan = notifies;

    rescan.complete(3);
    await heavy;
    await Future<void>.delayed(Duration.zero);
    expect(finished, isTrue);
    expect(notifies, notifiesBeforeRescan + 1,
        reason: 'a rescan that refreshed days notifies once more');
    expect(reclaims, 1);
  });

  test('a rescan that throws is logged and the pass carries on', () async {
    final coordinator = make(healthSync: true);
    addTearDown(coordinator.dispose);
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    coordinator.debugRescanRecent = (_) async => throw StateError('boom');

    await coordinator.afterDrain(heavy: true);
    await Future<void>.delayed(Duration.zero);

    expect(logs.any((l) => l.startsWith('[derive] rescan failed')), isTrue);
    expect(logs.any((l) => l.contains('post-drain failed')), isFalse);
    expect(exports, 1);
    expect(reclaims, 1);
  });

  test('a failing engine run is contained and skips the post-run steps',
      () async {
    final coordinator = make(healthSync: true);
    addTearDown(coordinator.dispose);
    var runs = 0;
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      runs++;
      throw StateError('no');
    };

    await coordinator.afterDrain();
    await Future<void>.delayed(Duration.zero);

    expect(runs, 1, reason: 'the hook, not the real engine, ran');
    expect(
        logs.any((l) =>
            l.startsWith('[derive] post-drain failed') && l.contains('no')),
        isTrue);
    expect(coordinator.insightsRevision.value, 0);
    expect(notifies, 0);
    expect(phoneSteps, 0);
    expect(recoveryChecks, 0);
    expect(exports, 0);
  });

  test('per-day progress notifies on the first, every third and the last day',
      () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    final notifiedAfter = <int>[];
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      for (var i = 1; i <= 7; i++) {
        final before = notifies;
        onDayDone!('d$i', i, 7);
        if (notifies > before) notifiedAfter.add(i);
      }
      return 7;
    };

    await coordinator.afterDrain();

    // Days 1, 3, 6 and 7, then the end-of-pass notification.
    expect(notifiedAfter, [1, 3, 6, 7]);
    expect(notifies, 5);
  });

  group('WHOOP 5 publication', () {
    test(
      'publishes today after freshness, before the remaining backlog',
      () async {
        final freshness = Completer<void>();
        final backlog = Completer<void>();
        final coordinator = make(
          optimizeWhoop5: () => true,
          refreshComputeFreshness: () => freshness.future,
        );
        addTearDown(coordinator.dispose);
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async {
              onDayDone!(todayLabel(), 1, 2);
              await backlog.future;
              return 2;
            };
        coordinator.debugRescanRecent = (_) async => 0;

        final pass = coordinator.afterDrain(heavy: true);
        await Future<void>.delayed(Duration.zero);
        expect(
          coordinator.insightsRevision.value,
          0,
          reason: 'freshness must validate the persisted night first',
        );
        freshness.complete();
        await Future<void>.delayed(Duration.zero);
        expect(
          coordinator.insightsRevision.value,
          1,
          reason: 'Home can load while older days are still computing',
        );
        expect(logs.any((l) => l.contains('WHOOP 5 day')), isTrue);

        backlog.complete();
        await pass;
        expect(coordinator.insightsRevision.value, 2);
      },
    );

    test(
      'refreshes early at most twice, then stamps final freshness',
      () async {
        var refreshes = 0;
        var active = 0;
        var maxActive = 0;
        final refreshed = Completer<void>();
        final coordinator = make(
          optimizeWhoop5: () => true,
          refreshComputeFreshness: () async {
            refreshes++;
            active++;
            if (active > maxActive) maxActive = active;
            await Future<void>.delayed(Duration.zero);
            active--;
            if (refreshes == 2) refreshed.complete();
          },
        );
        addTearDown(coordinator.dispose);
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async {
              for (var i = 1; i <= 7; i++) {
                onDayDone!(i == 2 ? todayLabel() : 'older$i', i, 7);
              }
              await refreshed.future;
              return 7;
            };

        await coordinator.afterDrain();
        expect(refreshes, 3);
        expect(maxActive, 1, reason: 'the freshness reads must not race');
        expect(coordinator.insightsRevision.value, 3);
      },
    );

    for (final finishesBeforeReturn in [false, true]) {
      test(
        'an early snapshot cannot overwrite final freshness '
        '(finishes before engine returns: $finishesBeforeReturn)',
        () async {
          final earlyRead = Completer<void>();
          var durable = 'first day';
          var freshness = 'before sync';
          var reads = 0;
          final coordinator = make(
            optimizeWhoop5: () => true,
            refreshComputeFreshness: () async {
              reads++;
              final snapshot = durable;
              if (reads == 1) await earlyRead.future;
              freshness = snapshot;
            },
          );
          addTearDown(coordinator.dispose);
          coordinator.debugDeriveRun =
              (profile, {heavy = false, onDayDone}) async {
                onDayDone!(todayLabel(), 1, 2);
                await Future<void>.delayed(Duration.zero);
                durable = 'all days';
                // The real engine stamps its final freshness before returning.
                freshness = durable;
                if (finishesBeforeReturn) {
                  earlyRead.complete();
                  await Future<void>.delayed(Duration.zero);
                  expect(freshness, 'first day',
                      reason: 'reproduce the early reader overwriting the stamp');
                }
                return 2;
              };
          final pass = coordinator.afterDrain();
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          if (!finishesBeforeReturn) {
            expect(freshness, 'all days');
            earlyRead.complete();
          }
          await pass;
          expect(reads, 2);
          expect(freshness, 'all days');
        },
      );
    }

    test(
      'today finishing first needs one early refresh and the final stamp',
      () async {
        var refreshes = 0;
        final coordinator = make(
          optimizeWhoop5: () => true,
          refreshComputeFreshness: () async => refreshes++,
        );
        addTearDown(coordinator.dispose);
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async {
              onDayDone!(todayLabel(), 1, 2);
              onDayDone('older', 2, 2);
              return 2;
            };

        await coordinator.afterDrain();
        expect(refreshes, 2);
      },
    );

    test(
      'a failed early freshness read still allows the final publication',
      () async {
        final coordinator = make(
          optimizeWhoop5: () => true,
          refreshComputeFreshness: () async => throw StateError('read failed'),
        );
        addTearDown(coordinator.dispose);
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async {
              onDayDone!(todayLabel(), 1, 1);
              return 1;
            };

        await coordinator.afterDrain();
        expect(coordinator.insightsRevision.value, 1);
        expect(
          logs.any((l) => l.contains('early freshness refresh deferred')),
          isTrue,
        );
        expect(logs.any((l) => l.contains('post-drain failed')), isFalse);
      },
    );

    test(
      'publishes before a slow rescore and again only when sessions change',
      () async {
        final repo = _SlowRescoreRepo();
        final coordinator = make(optimizeWhoop5: () => true, repo: repo);
        addTearDown(coordinator.dispose);
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async => 1;
        final pass = coordinator.afterDrain();
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.insightsRevision.value, 1);
        repo.result.complete(2);
        await pass;
        expect(
          coordinator.insightsRevision.value,
          2,
          reason: 'the corrected workout list needs its own refresh',
        );
      },
    );

    test(
      'a heavy rescan that changes scalars also advances the revision',
      () async {
        final coordinator = make(optimizeWhoop5: () => true);
        addTearDown(coordinator.dispose);
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async => 0;
        coordinator.debugRescanRecent = (_) async => 3;
        await coordinator.afterDrain(heavy: true);
        expect(coordinator.insightsRevision.value, 2);
      },
    );

    test(
      'disposal during freshness suppresses late UI and follow-up work',
      () async {
        final freshness = Completer<void>();
        final coordinator = make(
          optimizeWhoop5: () => true,
          refreshComputeFreshness: () => freshness.future,
        );
        coordinator.debugDeriveRun =
            (profile, {heavy = false, onDayDone}) async {
              onDayDone!(todayLabel(), 1, 1);
              return 1;
            };
        final pass = coordinator.afterDrain();
        await Future<void>.delayed(Duration.zero);
        coordinator.dispose();
        final notifiesBefore = notifies;
        freshness.complete();
        await pass;
        expect(notifies, notifiesBefore);
        expect(phoneSteps, 0);
        expect(recoveryChecks, 0);
        expect(logs.any((l) => l.contains('post-drain failed')), isFalse);
      },
    );

    test('other devices keep their original end-of-pass publication', () async {
      var refreshes = 0;
      final coordinator = make(
        optimizeWhoop5: () => false,
        refreshComputeFreshness: () async => refreshes++,
      );
      addTearDown(coordinator.dispose);
      coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
        onDayDone!(todayLabel(), 1, 1);
        expect(coordinator.insightsRevision.value, 0);
        return 1;
      };
      await coordinator.afterDrain();
      expect(refreshes, 0);
      expect(coordinator.insightsRevision.value, 1);
    });
  });

  test('health export runs only when enabled and logs its day count',
      () async {
    final off = make();
    addTearDown(off.dispose);
    off.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    await off.afterDrain();
    await Future<void>.delayed(Duration.zero);
    expect(exports, 0);

    final on = make(healthSync: true);
    addTearDown(on.dispose);
    on.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    await on.afterDrain();
    await Future<void>.delayed(Duration.zero);
    expect(exports, 1);
    expect(logs, contains('[health] exported 2 day(s)'));
  });

  test('a throwing health export is logged and never fails the pass',
      () async {
    final coordinator = make(
      healthSync: true,
      runHealthExport: () async => throw StateError('hk'),
    );
    addTearDown(coordinator.dispose);
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;

    await coordinator.afterDrain();
    await Future<void>.delayed(Duration.zero);

    expect(logs.any((l) => l.startsWith('[health] export failed')), isTrue);
    expect(logs.any((l) => l.contains('post-drain failed')), isFalse);
  });

  test('backs off to the cap, skips background retries, and resets on resume',
      () {
    fakeAsync((fa) {
      var background = false;
      final coordinator = make(background: () => background);
      var calls = 0;
      coordinator.debugRefreshActivityReviews = (_) async {
        calls++;
        return false;
      };

      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      fa.elapse(const Duration(minutes: 30));
      expect(calls, 11, reason: 'the first call plus ten capped retries');
      expect(fa.pendingTimers, isEmpty);

      background = true;
      unawaited(coordinator.refreshActivityReviews(retry: true));
      fa.flushMicrotasks();
      expect(calls, 11);

      background = false;
      coordinator.resetActivityReviewAttempts();
      unawaited(coordinator.refreshActivityReviews(retry: true));
      fa.flushMicrotasks();
      expect(calls, 12);
      expect(fa.pendingTimers, hasLength(1));
      coordinator.dispose();
    });
  });

  test('retries wait 2s, 4s, 8s, 16s and then 30s', () {
    fakeAsync((fa) {
      final coordinator = make();
      var calls = 0;
      coordinator.debugRefreshActivityReviews = (_) async {
        calls++;
        return false;
      };
      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      var expected = 1;
      for (final seconds in [2, 4, 8, 16, 30, 30]) {
        fa.elapse(Duration(seconds: seconds - 1));
        expect(calls, expected, reason: 'before the ${seconds}s retry');
        fa.elapse(const Duration(seconds: 1));
        expect(calls, ++expected, reason: 'at the ${seconds}s retry');
      }
      coordinator.dispose();
    });
  });

  test('a successful review refresh bumps and stops retrying', () {
    fakeAsync((fa) {
      final coordinator = make();
      coordinator.debugRefreshActivityReviews = (_) async => true;
      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      // One bump when the refresh starts, one when it lands.
      expect(coordinator.insightsRevision.value, 2);
      expect(fa.pendingTimers, isEmpty);
      coordinator.dispose();
    });
  });

  test('a retry does not bump on entry, and a disposed host does nothing',
      () async {
    var hostDisposed = false;
    final coordinator = make(disposed: () => hostDisposed);
    addTearDown(coordinator.dispose);
    var calls = 0;
    coordinator.debugRefreshActivityReviews = (_) async {
      calls++;
      return true;
    };

    await coordinator.refreshActivityReviews(retry: true);
    expect(calls, 1);
    expect(coordinator.insightsRevision.value, 1);

    hostDisposed = true;
    await coordinator.refreshActivityReviews();
    expect(calls, 1);
    expect(coordinator.insightsRevision.value, 1);
  });

  test('reanalyzeForNapEdit is a fresh, non-retry review refresh', () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    var calls = 0;
    coordinator.debugRefreshActivityReviews = (_) async {
      calls++;
      return true;
    };
    await coordinator.reanalyzeForNapEdit();
    expect(calls, 1);
    expect(coordinator.insightsRevision.value, 2);
  });

  test('dispose cancels the retry timer and disposes the revision notifier',
      () {
    fakeAsync((fa) {
      final coordinator = make();
      coordinator.debugRefreshActivityReviews = (_) async => false;
      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      expect(fa.pendingTimers, hasLength(1));
      final revision = coordinator.insightsRevision;
      coordinator.dispose();
      expect(fa.pendingTimers, isEmpty);
      expect(() => revision.addListener(() {}), throwsA(isA<FlutterError>()));
    });
  });
}

class _SlowRescoreRepo extends LocalRepository {
  final result = Completer<int>();

  @override
  Future<int> rescoreRecentSessions({int sinceDays = 3}) => result.future;

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}
