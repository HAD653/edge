// The compact WHOOP layout must keep its real values and navigation accessible
// on iPhone 15 Pro width, including enlarged text and missing sleep targets.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _home = HomeData(
  readiness: Metric(value: 70, confidence: .9),
  strain: Metric(value: 12.4, confidence: .8),
  sleepMin: Metric(value: 450, confidence: .8),
  sleepNeedMin: Metric(value: 480, confidence: .8),
  rhr: Metric(value: 50, confidence: .8),
  stress: Metric(value: 34, confidence: .8),
  steps: Metric(value: 8432, confidence: .8),
  calories: Metric(value: 482, confidence: .8),
);

Widget _frame(Widget child, {double scale = 1}) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: SafeArea(child: child)),
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final family in ['.SF Pro Text', 'Manrope', 'Barlow Condensed']) {
      final dir = family == 'Barlow Condensed' ? 'BarlowCondensed' : 'Manrope';
      final loader = FontLoader(family);
      for (final file in Directory('assets/fonts/$dir').listSync().whereType<File>()) {
        if (!file.path.endsWith('.ttf')) continue;
        loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      }
      await loader.load();
    }
  });

  test('home and health read the stress score envelope without recovery fallback', () async {
    final raw = <String, dynamic>{
      'score': 34, 'confidence': .63, 'tier': 'ESTIMATE',
      'note': 'measured_note', 'inputs_used': ['rr_intervals'],
    };
    final home = await HomeData.load(_StressRepo(raw));
    final health = HealthData(today: {'stress': raw});
    for (final metric in [home.stress, health.stress]) {
      expect(metric.value, 34);
      expect(metric.confidence, .63);
      expect(metric.tier, MetricTier.estimate);
      expect(metric.note, 'measured_note');
      expect(metric.inputsUsed, ['rr_intervals']);
    }

    // A different field, or a high recovery, never stands in for the score.
    final absent = <String, dynamic>{
      'value': 99, 'confidence': .42, 'note': 'need_more_rr',
    };
    final missingHome = await HomeData.load(_StressRepo(absent));
    final missingHealth = HealthData(today: {'stress': absent});
    for (final metric in [missingHome.stress, missingHealth.stress]) {
      expect(metric.value, isNull);
      expect(metric.confidence, .42);
      expect(metric.note, 'need_more_rr');
    }
    expect(const HealthData().stress.value, isNull);
    expect((await HomeData.load(_StressRepo(null))).stress.value, isNull);
  });

  testWidgets('sleep, recovery and strain retain WHOOP order and honest target', (t) async {
    t.view.physicalSize = const Size(393, 852);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_frame(const Center(child: RingTrio(d: _home))));
    await t.pumpAndSettle();
    expect(t.getCenter(find.text('94%')).dx, lessThan(t.getCenter(find.text('70')).dx));
    expect(t.getCenter(find.text('70')).dx, lessThan(t.getCenter(find.text('12.4')).dx));
    expect(find.text('7h 30m'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Sleep.*of 8h 00m')), findsOneWidget);
    expect(t.takeException(), isNull);

    await t.pumpWidget(_frame(const Center(child: RingTrio(d: HomeData(
      sleepMin: Metric(value: 450, confidence: .8),
    )))));
    await t.pumpAndSettle();
    expect(find.text('94%'), findsNothing);
    expect(find.text('7h 30m'), findsOneWidget);
    expect(find.text('No target yet'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('My Day opens the real logger and a picker wired to the app host', (t) async {
    final app = AppState.forTesting();
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.dark);
    addTearDown(app.dispose);
    addTearDown(theme.dispose);
    await t.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<ThemeController>.value(value: theme),
    ], child: _frame(const HomeScreen(data: _home))));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('LOG A PAST WORKOUT'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('LOG A PAST WORKOUT'));
    await t.pumpAndSettle();
    expect(find.byType(LogWorkout), findsOneWidget);
    expect(t.takeException(), isNull);
    Navigator.of(t.element(find.byType(LogWorkout))).pop();
    await t.pumpAndSettle();
    await t.tap(find.text('START A SESSION'));
    await t.pumpAndSettle();
    final picker = t.widget<ActivityPicker>(find.byType(ActivityPicker));
    expect(picker.host.onStart, isNotNull);
    expect(picker.host.onFinish, isNotNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('the metric selector opens the selected live metric route', (t) async {
    final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.dark);
    addTearDown(theme.dispose);
    await t.pumpWidget(ChangeNotifierProvider<ThemeController>.value(
      value: theme,
      child: _frame(const MetricDetail('hrv', data: MetricData())),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('HRV'));
    await t.pumpAndSettle();
    await t.tap(find.text('Steps'));
    await t.pumpAndSettle();
    expect(t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, 'steps');
    expect(t.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('home dark at 393 points and ${scale}x text keeps My Day usable', (t) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_frame(const HomeScreen(data: _home), scale: scale));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.text('My Day'), 250,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('My Day'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('health monitor and metric trends fit ${scale}x text', (t) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_frame(const HealthScreen(data: HealthData(today: {
        'daily': {'resting_hr': {'value': 50, 'confidence': .8}},
        'hrv': {'rmssd': 87, 'confidence': .8},
        'sleep': {'duration_min': {'value': 450, 'confidence': .8}},
        'resp': {'value': 15.1, 'confidence': .8},
      })), scale: scale));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);

      final now = DateTime.now();
      final points = [for (var i = 0; i < 30; i++) (
        t: DateTime(now.year, now.month, now.day - 29 + i, 12)
            .millisecondsSinceEpoch ~/ 1000,
        v: 65.0 + i % 14,
      )];
      await t.pumpWidget(_frame(MetricDetail('hrv', data: MetricData(
        series: points, daysAvailable: 30,
      )), scale: scale));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.ensureVisible(find.text('30 days'));
      await t.tap(find.text('30 days'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byType(ChartFrame), 250,
          scrollable: find.byType(Scrollable).first);
      expect(t.takeException(), isNull);
    });
  }
}


class _StressRepo extends LocalRepository {
  _StressRepo(this.stress);
  final Map<String, dynamic>? stress;
  @override
  Future<Map<String, dynamic>> getToday() async => {
    'daily': {'readiness': 98},
    'status': {'today_day': todayLabel()},
    if (stress != null) 'stress': stress,
  };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
}
