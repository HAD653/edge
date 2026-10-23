import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/summary.dart';
import 'package:openstrap_edge/ui2/demo/demo_data.dart';
import 'package:openstrap_edge/ui2/demo/demo_screen.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// Deliberately no AppState, repositories, preferences, Bluetooth, or platform
// channels. A demo action that starts relying on the live app must fail here.
Future<void> pumpDemo(WidgetTester t, {String language = 'en'}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: const WelcomeScreen(),
    ),
  );
  await t.pumpAndSettle();
  final entry = find.text(
    language == 'fr' ? 'Explorer la démo' : 'Explore demo',
  );
  await t.ensureVisible(entry);
  await t.tap(entry);
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  final finder = find.text(text).last;
  await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

void main() {
  test('fixtures agree across cards, charts, stages and activity splits', () {
    final data = DemoData(now: DateTime(2026, 3, 30));
    for (final key in DemoData.metricKeys) {
      final points = data.series(key);
      expect(points, hasLength(30));
      final dates = points
          .map(
            (p) => dayLabelOf(DateTime.fromMillisecondsSinceEpoch(p.t * 1000)),
          )
          .toSet();
      expect(dates, hasLength(30));
      expect(dates.last, data.day);
      expect(data.metric(key).series, data.series(key));
    }
    expect(data.home.rhr.value, data.series('resting_hr').last.v);
    expect(data.home.strain.value, data.series('strain').last.v);
    expect(data.home.steps.value, data.series('steps').last.v);
    final night = data.sleep.night;
    expect(night['duration_min'], data.home.sleepMin.value);
    expect(
      night['light_min'] + night['deep_min'] + night['rem_min'],
      night['duration_min'],
    );
    expect(night['duration_min'] + night['awake_min'], night['in_bed_min']);
    expect(night['wake_ts'] - night['onset_ts'], night['in_bed_min'] * 60);
    expect(
      data.run.splits.fold<int>(0, (n, s) => n + s.sec),
      data.run.duration.inSeconds,
    );
    expect(
      data.run.zoneMinutes.reduce((a, b) => a + b),
      data.run.duration.inMinutes,
    );
    expect(data.run.sessionId, isNull);
  });

  testWidgets(
    'welcome enters demo, keeps its label on details, exits and re-enters',
    (t) async {
      await pumpDemo(t);
      expect(find.bySemanticsLabel('Exit demo'), findsOneWidget);
      expect(find.text('Demo · Fictional data'), findsOneWidget);
      expect(find.text('82'), findsOneWidget);
      await tapText(t, '82');
      expect(find.byType(ReadinessDetail), findsOneWidget);
      expect(find.bySemanticsLabel('Exit demo'), findsOneWidget);
      expect(find.text('Demo · Fictional data'), findsOneWidget);
      expect(
        t.widget<ReadinessDetail>(find.byType(ReadinessDetail)).readOnly,
        isTrue,
      );
      await tapText(t, 'Exit demo');
      expect(find.byType(DemoScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      await tapText(t, 'Explore demo');
      expect(find.text('82'), findsOneWidget);
    },
  );

  testWidgets(
    'all four tabs and interactive details work without live services',
    (t) async {
      await pumpDemo(t);
      await tapText(t, 'Sleep');
      expect(t.widget<SleepDetail>(find.byType(SleepDetail)).readOnly, isTrue);
      await t.drag(
        find.byType(ListView).hitTestable().first,
        const Offset(0, 350),
      );
      await t.pumpAndSettle(); // Refresh must retain the injected night.
      expect(find.text('7h 30m'), findsWidgets);
      await tapText(t, 'Activity');
      await tapText(t, 'View activity');
      expect(find.byType(ActivitySummary), findsOneWidget);
      expect(find.byIcon(Icons.share), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Share this')), findsNothing);
      await tapText(t, 'Splits');
      await tapText(t, 'Graphs');
      await t.tap(find.bySemanticsLabel('Back'));
      await t.pumpAndSettle();
      await tapText(t, 'Health');
      await tapText(t, 'HRV');
      expect(
        t.widget<MetricDetail>(find.byType(MetricDetail)).readOnly,
        isTrue,
      );
      await tapText(t, '7 days');
      await tapText(t, '30 days');
      expect(find.text('Advanced charts'), findsNothing);
      // System Back belongs to the nested detail route, not onboarding.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(MetricDetail), findsNothing);
      expect(find.byType(DemoScreen), findsOneWidget);
      await tapText(t, 'Exit demo');
      expect(find.byType(WelcomeScreen), findsOneWidget);
    },
  );

  testWidgets('French demo supports a local theme change', (t) async {
    await pumpDemo(t, language: 'fr');
    expect(find.text('Démo · Données fictives'), findsOneWidget);
    final banner = find.byType(DemoBanner);
    expect(Theme.of(t.element(banner)).brightness, Brightness.light);
    await t.tap(find.byTooltip('Changer l’apparence'));
    await t.pumpAndSettle();
    expect(Theme.of(t.element(banner)).brightness, Brightness.dark);
    await tapText(t, 'Quitter la démo');
    expect(
      Theme.of(t.element(find.byType(WelcomeScreen))).brightness,
      Brightness.light,
    );
  });

  for (final scale in [1.0, 2.0, 3.1]) {
    testWidgets('demo banner remains usable at ${scale}x', (t) async {
      t.view.physicalSize = const Size(360, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: DemoBanner(onExit: () {}, onTheme: () {}),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      expect(find.text('Exit demo').hitTestable(), findsOneWidget);
    });
  }
}
