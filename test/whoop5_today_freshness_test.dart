import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'openstrap_whoop5_today_freshness_test.db';
  late Database db;
  late String today;
  late String yesterday;
  late int nowSec;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
    db = await LocalDb.instance;
  });
  setUp(() async {
    for (final table in [
      'day_result',
      'decoded_onehz',
      'decoded_rr',
      'compute_freshness',
      'wake_day_features',
      'baselines',
    ]) {
      await db.delete(table);
    }
    final now = DateTime.now();
    today = dayLabelOf(now);
    yesterday = dayLabelOf(DateTime(now.year, now.month, now.day - 1));
    nowSec = now.millisecondsSinceEpoch ~/ 1000;
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  Map<String, dynamic> night(int wake, int edge) => {
    'scalars': {'readiness': 61},
    'data_edge_sec': edge,
    'sleep': {
      'window': {
        'value': {'offset_ms': wake * 1000},
      },
      'accounting': {
        'value': {'tst_sec': 6 * 3600},
      },
    },
    // Both compact encodings, plus a legacy curve. None is an input to the
    // freshness decisions and omitting them must preserve every metadata type.
    'series': {
      'hr_curve': {
        't0': wake,
        'dt': 60,
        'v': [61, 62, null],
      },
      'hrv_day': {
        't0': wake,
        'to': [0, 61, 140],
        'v': [30, null, 32],
      },
      'strain_curve': [
        {'t': wake, 'v': 0.5},
      ],
    },
    'activity_curve': {
      't0': wake,
      'dt': 60,
      'v': [0.1, null, 0.2],
    },
  };

  Future<void> putDay(
    String day,
    Object payload, {
    int version = kAlgoVersion,
    double? readiness,
  }) async {
    await db.insert('day_result', {
      'day_id': day,
      'algo_version': version,
      'payload_json': jsonEncode(payload),
      'computed_at': 1234,
      'readiness': readiness,
      'window_json': '{}',
    });
  }

  Future<void> putRaw(int ts, {String source = '', String device = ''}) async {
    await db.insert('decoded_onehz', {
      'device_id': device,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': 1,
      'hr': 61,
      'source': source.isEmpty ? null : source,
    });
  }

  Future<Map<String, dynamic>> todaySnapshot() async =>
      (jsonDecode(
                (await LocalDb.computeFreshness('today'))!['payload_json']
                    as String,
              )
              as Map)
          .cast<String, dynamic>();

  Future<Map<String, dynamic>> compareFullAndLight() async {
    await LocalDb.refreshComputeFreshness();
    final full = await todaySnapshot();
    await LocalDb.putComputeFreshness('capture', '{"sentinel":"capture"}');
    await LocalDb.putComputeFreshness('crossday', '{"sentinel":"crossday"}');
    final capture = await LocalDb.computeFreshness('capture');
    final crossday = await LocalDb.computeFreshness('crossday');
    await LocalDb.refreshComputeFreshness(todayOnly: true);
    final light = await todaySnapshot();
    expect(light, full);
    expect(await LocalDb.computeFreshness('capture'), capture);
    expect(await LocalDb.computeFreshness('crossday'), crossday);
    return light;
  }

  test(
    'missing inputs produce identical absence and create only today',
    () async {
      await LocalDb.refreshComputeFreshness(todayOnly: true);
      expect(await LocalDb.computeFreshness('capture'), isNull);
      expect(await LocalDb.computeFreshness('crossday'), isNull);
      final snapshot = await compareFullAndLight();
      expect(snapshot['activity_state'], 'missing');
      expect(snapshot['overnight_state'], 'missing');
      expect(snapshot['recovery_state'], isNull);
    },
  );

  test('the coordinator publishes real Today gates before the backlog ends',
      () async {
    await putRaw(nowSec);
    await putDay(today, night(nowSec - 3 * 3600, nowSec));
    await LocalDb.putComputeFreshness('capture', '{"sentinel":"capture"}');
    await LocalDb.putComputeFreshness('crossday', '{"sentinel":"crossday"}');
    final capture = await LocalDb.computeFreshness('capture');
    final crossday = await LocalDb.computeFreshness('crossday');
    final backlog = Completer<void>();
    final published = Completer<void>();
    final coordinator = DeriveCoordinator(
      derive: () => throw StateError('test uses the compute hook'),
      profile: () => const Profile(),
      repo: () => null,
      background: () => false,
      disposed: () => false,
      log: (_) {},
      notify: () {},
      refreshPhoneStepsToday: () async {},
      maybeNotifyRecoveryReady: () async {},
      runHealthExport: () async => 0,
      healthSyncEnabled: () => false,
      telemetryConsent: () => false,
      healthShareConsent: () => false,
      maybeReclaimDiskSpace: () async {},
      optimizeWhoop5: () => true,
    );
    addTearDown(coordinator.dispose);
    coordinator.insightsRevision.addListener(() {
      if (!published.isCompleted) published.complete();
    });
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      onDayDone!(today, 1, 2);
      await backlog.future;
      return 2;
    };
    final pass = coordinator.afterDrain();
    try {
      await published.future.timeout(const Duration(seconds: 5));
      final snapshot = await todaySnapshot();
      expect(snapshot['overnight_day'], today);
      expect(snapshot['overnight_state'], 'ready');
      expect(snapshot['recovery_state'], 'final');
      expect(await LocalDb.computeFreshness('capture'), capture);
      expect(await LocalDb.computeFreshness('crossday'), crossday);
    } finally {
      backlog.complete();
      await pass;
    }
  });

  for (final state in ['night_in_progress', 'provisional', 'final']) {
    test(
      '$state night preserves compact-curve metadata and fallback',
      () async {
        final wake = nowSec - 3 * 3600;
        final edge = switch (state) {
          'night_in_progress' => wake + 60,
          'provisional' => wake + 35 * 60,
          _ => wake + 2 * 3600,
        };
        await putRaw(nowSec);
        await putDay(yesterday, night(wake - 24 * 3600, edge));
        await putDay(today, night(wake, edge));
        final snapshot = await compareFullAndLight();
        expect(snapshot['recovery_state'], state);
        expect(snapshot['overnight_day'], state == 'final' ? today : yesterday);
      },
    );
  }

  test(
    'no-sleep flag and string window preserve a settled no-sleep answer',
    () async {
      await putDay(yesterday, night(nowSec - 24 * 3600, nowSec));
      await putDay(today, {
        'flags': ['NO_SLEEP_DETECTED'],
        'sleep': {
          'window': {'value': '—'},
        },
        'data_edge_sec': nowSec - kOvernightGiveUpSec - 3600,
        'scalars': {'readiness': null},
        'series': {
          'hr_curve': {
            't0': nowSec,
            'dt': 60,
            'v': [61, 62, 63],
          },
        },
      });
      final snapshot = await compareFullAndLight();
      expect(snapshot['overnight_day'], today);
      expect(snapshot['overnight_state'], 'ready');
      expect(snapshot['recovery_day'], yesterday);
    },
  );

  test(
    'true skipped metadata remains a boolean after JSON projection',
    () async {
      await putRaw(nowSec);
      await putDay(yesterday, night(nowSec - 24 * 3600, nowSec));
      await putDay(today, {
        ...night(nowSec - 3 * 3600, nowSec),
        'skipped': true,
      });
      final snapshot = await compareFullAndLight();
      expect(snapshot['overnight_day'], yesterday);
      expect(snapshot['recovery_day'], yesterday);
      expect(snapshot['recovery_state'], isNull);
    },
  );

  test(
    'latest raw uses every source/device, independently of the band edge',
    () async {
      final yesterdayStart = localDayStartSec(yesterday)!;
      await putRaw(yesterdayStart + 3600);
      await putRaw(nowSec, source: 'unverified_sensor', device: 'other');
      expect(await LocalDb.lastDecodedRecTs(), yesterdayStart + 3600);
      final snapshot = await compareFullAndLight();
      expect(snapshot['activity_state'], 'building');
      expect(snapshot['overnight_state'], 'building');
    },
  );

  test('nonpositive timestamps do not make absent activity building', () async {
    await putRaw(0);
    await putRaw(-1);
    final snapshot = await compareFullAndLight();
    expect(snapshot['activity_state'], 'missing');
  });

  test('wake-only activity uses the same computed timestamp', () async {
    await LocalDb.putWakeDayFeatures(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
    );
    final snapshot = await compareFullAndLight();
    expect(snapshot['activity_state'], 'ready');
    expect(snapshot['activity_computed_at'], isA<int>());
  });

  test('served-version ceiling and row readiness remain identical', () async {
    final wake = nowSec - 3 * 3600;
    await putDay(today, night(wake, nowSec), readiness: 62);
    await putDay(today, {'skipped': true}, version: kAlgoVersion + 1);
    final snapshot = await compareFullAndLight();
    expect(snapshot['overnight_day'], today);
    expect(snapshot['recovery_day'], today);
  });

  test(
    'malformed and non-object JSON keep the tolerant full-path behavior',
    () async {
      await putDay(yesterday, night(nowSec - 24 * 3600, nowSec));
      await putDay(today, []);
      await compareFullAndLight();
      await db.update(
        'day_result',
        {'payload_json': '{invalid json'},
        where: 'day_id = ?',
        whereArgs: [today],
      );
      final snapshot = await compareFullAndLight();
      expect(snapshot['overnight_day'], yesterday);
      // SQLite can hold a BLOB in a TEXT column after an old import. The full
      // decoder refuses a non-String; SQL JSON functions must not admit it.
      await db.update(
        'day_result',
        {
          'payload_json': Uint8List.fromList(
            utf8.encode(jsonEncode(night(nowSec - 3 * 3600, nowSec))),
          ),
        },
        where: 'day_id = ?',
        whereArgs: [today],
      );
      expect((await compareFullAndLight())['overnight_day'], yesterday);
    },
  );
}
