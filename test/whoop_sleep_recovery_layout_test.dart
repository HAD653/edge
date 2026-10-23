import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/demo/demo_data.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget screen,
    {double width = 393, double scale = 1, String language = 'en'}) async {
  t.view.physicalSize = Size(width, 852);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.dark),
    locale: Locale(language),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: RepaintBoundary(
      key: const ValueKey('capture'),
      child: KeyedSubtree(key: UniqueKey(), child: screen),
    ),
  ));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

Future<void> _capture(WidgetTester t, String name) async {
  final directory = Platform.environment['EDGE_LAYOUT_ARTIFACTS'];
  if (directory == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')));
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    for (final (family, directory) in [
      ('Manrope', 'Manrope'),
      ('.SF Pro Text', 'Manrope'),
      ('Barlow Condensed', 'BarlowCondensed'),
    ]) {
      final loader = FontLoader(family);
      for (final file in Directory('assets/fonts/$directory')
          .listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
        loader.addFont(file.readAsBytes().then((b) =>
            ByteData.sublistView(Uint8List.fromList(b))));
      }
      await loader.load();
    }
    final icons = FontLoader('packages/lucide_icons_flutter/Lucide');
    icons.addFont(rootBundle.load(
        'packages/lucide_icons_flutter/assets/lucide.ttf'));
    await icons.load();
  });
  final demo = DemoData(now: DateTime(2026, 10, 23));

  testWidgets('sleep dial names measured efficiency and retains total sleep',
      (t) async {
    await _pump(t, SleepDetail(data: demo.sleep, readOnly: true));
    expect(find.text('94%'), findsOneWidget);
    expect(find.text('SLEEP EFFICIENCY'), findsOneWidget);
    expect(find.text('7h 30m'), findsOneWidget);
    expect(find.text('Sleep performance'), findsNothing);
    await _capture(t, 'sleep');
  });

  testWidgets('a night without efficiency has no fabricated percentage',
      (t) async {
    await _pump(t, const SleepDetail(
      readOnly: true,
      data: SleepData(night: {'duration_min': 450, 'in_bed_min': 480}),
    ));
    expect(find.text('7h 30m'), findsOneWidget);
    expect(find.text('TOTAL SLEEP'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('recovery uses its existing scalar and keeps absent scores absent',
      (t) async {
    await _pump(t, ReadinessDetail(data: demo.recovery, readOnly: true));
    expect(find.text('82'), findsOneWidget);
    await _capture(t, 'recovery');
    await _pump(t, const ReadinessDetail(
        data: ReadinessData(), readOnly: true));
    expect(find.text('82'), findsNothing);
    expect(find.text('Recovery is not scored'), findsOneWidget);
    await _capture(t, 'recovery-absent');
  });

  testWidgets('a negative regularity index keeps its place on the full scale',
      (t) async {
    await _pump(t, const CircadianDetail(
      data: CircadianData(regularity: Metric(value: -25)),
    ));
    expect(find.text('-25'), findsOneWidget);
    expect(find.text('−100 … 100'), findsOneWidget);
    final dial = t.widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter).whereType<Ring>().single;
    expect(dial.v, greaterThan(0),
        reason: 'a valid negative SRI must not collapse into an empty dial');
    expect(dial.v, lessThan(.5),
        reason: 'negative agreement belongs below the midpoint, not above it');
    await _capture(t, 'body-clock-negative-index');
  });

  for (final (width, scale) in [(320.0, 1.0), (393.0, 2.0), (393.0, 3.1)]) {
    testWidgets('sleep and recovery reflow at $width / ${scale}x', (t) async {
      for (final screen in [
        SleepDetail(data: demo.sleep, readOnly: true),
        ReadinessDetail(
          readOnly: true,
          data: ReadinessData(
            readiness: demo.recovery.readiness,
            series: demo.recovery.series,
            breakdown: const [
              {'label': 'hrv', 'used': true, 'weight': .4,
                'weighted_contribution': 3.5, 'past_mdc': true},
              {'label': 'temp', 'used': false},
            ],
          ),
        ),
        const CircadianDetail(data: CircadianData(
          regularity: Metric(value: 75),
          chronotypeLabel: 'Evening',
          midFreeH: 4.3,
          midWorkH: 3.5,
          nFree: 8,
          nWork: 20,
        )),
      ]) {
        await _pump(t, screen, width: width, scale: scale, language: 'ru');
        for (var i = 0; i < 12; i++) {
          await t.drag(find.byType(ListView).first, const Offset(0, -600));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull,
              reason: '${screen.runtimeType} at $width / ${scale}x');
        }
      }
    });
  }
}
