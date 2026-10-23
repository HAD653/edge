// Exercise the real Activity screen at iPhone 15 Pro width, with the bundled
// fonts. The redesign must keep entry points reachable with data and without it.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:openstrap_edge/ui2/screens/nutrition_screen.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  _Repo({required this.measured});
  final bool measured;
  final day = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );

  @override
  Future<Map<String, dynamic>> getProfile() async => const {'weight_kg': 72.4};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => measured
      ? {
          'strain': 12.4,
          'curve': [
            for (var i = 0; i < 240; i++)
              {
                't':
                    day
                        .add(Duration(minutes: 420 + i))
                        .millisecondsSinceEpoch ~/
                    1000,
                'v': 12.4 * i / 239,
              },
          ],
          'zones': {'z1': 92, 'z2': 31, 'z3': 17, 'z4': 12, 'z5': 4},
          'hr': {'max': 171},
          'max_hr_used': 187,
          'zone_source': 'observed',
          'zone_max_hr': 187,
          'zone_lower_bpm': [93, 112, 131, 149, 168],
        }
      : {};
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async =>
      measured ? const {'worn_min': 900, 'coverage_pct': 80} : const {};
  @override
  Future<Map<String, dynamic>> getInsights() async => measured
      ? const {
          'load': {
            'value': {'ctl': 28.0, 'atl': 36.0, 'tsb': -8.0},
          },
        }
      : const {};
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async => {
    'points': [
      if (measured)
        for (var i = 0; i < 7; i++)
          {
            't':
                DateTime(
                  day.year,
                  day.month,
                  day.day - 6 + i,
                  12,
                ).millisecondsSinceEpoch ~/
                1000,
            'v': 22.0 + i * 4,
          },
    ],
  };
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
    'workouts': [
      if (measured)
        {
          'id': 'fixture-running',
          'type': 'running',
          'start_ts':
              day.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000,
          'duration_min': 45,
          'strain': 10.2,
          'calories': 450,
          'avg_hr': 148,
          'max_hr': 171,
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> getRecords() async => {
    'workouts_tracked': measured ? 1 : 0,
  };
  @override
  Future<Map<String, dynamic>> getToday() async => const {};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(
    String date,
  ) async => {};
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<GlobalKey> _pump(
  WidgetTester t, {
  required bool measured,
  double scale = 1,
}) async {
  t.view.physicalSize = const Size(393, 852);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = _Repo(measured: measured);
  addTearDown(app.dispose);
  final shot = GlobalKey();
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<UnitsController>(
          create: (_) => UnitsController.seed(UnitSystem.metric),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: shot,
          child: const Scaffold(body: SafeArea(child: WorkoutScreen())),
        ),
      ),
    ),
  );
  await _settle(t);
  if (measured) {
    for (var i = 0; i < 200 && find.text('12.4').evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
  }
  return shot;
}

Future<void> _capture(WidgetTester t, GlobalKey shot, String name) async {
  final destination = Platform.environment['EDGE_ACTIVITY_LAYOUT_ARTIFACTS'];
  if (destination == null) return;
  final boundary =
      shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory(destination)..createSync(recursive: true);
    File(
      '${folder.path}/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'whoop_activity_layout_test.db';
    await databaseFactory.deleteDatabase(
      path.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    await LocalDb.instance;
    final icons = FontLoader('packages/lucide_icons_flutter/Lucide');
    icons.addFont(
      rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
    );
    await icons.load();
    for (final family in ['.SF Pro Text', 'Manrope', 'Barlow Condensed']) {
      final folder = family == 'Barlow Condensed'
          ? 'BarlowCondensed'
          : 'Manrope';
      final fonts = FontLoader(family);
      for (final file in Directory(
        'assets/fonts/$folder',
      ).listSync().whereType<File>()) {
        if (file.path.endsWith('.ttf')) {
          fonts.addFont(file.readAsBytes().then(ByteData.sublistView));
        }
      }
      await fonts.load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      path.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets(
      'real dark Activity fits $scale text and keeps the session action',
      (t) async {
        final shot = await _pump(t, measured: true, scale: scale);
        expect(find.text('12.4'), findsOneWidget);
        expect(t.takeException(), isNull);
        await _capture(t, shot, 'activity-$scale');
        await t.scrollUntilVisible(
          find.text('START A SESSION').first,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await t.tap(find.text('START A SESSION').first);
        await t.pumpAndSettle();
        expect(find.byType(ActivityPicker), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('nutrition, history and logging a past workout remain usable', (
    t,
  ) async {
    await _pump(t, measured: true);
    await t.scrollUntilVisible(
      find.text('Nutrition'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(find.text('Nutrition'));
    await t.pumpAndSettle();
    await t.tap(find.text('Nutrition').hitTestable());
    await _settle(t);
    expect(find.byType(NutritionScreen), findsOneWidget);
    Navigator.of(t.element(find.byType(NutritionScreen))).pop();
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('History'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(find.text('History'));
    await t.pumpAndSettle();
    await t.tap(find.text('History').hitTestable());
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('Running'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Running'), findsOneWidget);
    await t.scrollUntilVisible(
      find.text('Log a past workout'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(find.text('Log a past workout'));
    await t.pumpAndSettle();
    await t.tap(find.text('Log a past workout').hitTestable());
    await t.pumpAndSettle();
    expect(find.byType(LogWorkout), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'a new account has no invented score and keeps start and history',
    (t) async {
      final shot = await _pump(t, measured: false, scale: 3);
      expect(find.text('12.4'), findsNothing);
      expect(t.takeException(), isNull);
      await _capture(t, shot, 'activity-no-data-3');
      await t.ensureVisible(find.text('History'));
      await t.pumpAndSettle();
      await t.tap(find.text('History').hitTestable());
      await t.pumpAndSettle();
      expect(find.text('No sessions recorded yet'), findsOneWidget);
      await t.scrollUntilVisible(
        find.text('Start a workout'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(find.text('Start a workout'));
      await t.pumpAndSettle();
      await t.tap(find.text('Start a workout').hitTestable());
      await t.pumpAndSettle();
      expect(find.byType(ActivityPicker), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
