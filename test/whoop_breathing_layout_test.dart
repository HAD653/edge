import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/calm_breathing.dart';
import 'package:openstrap_edge/ui2/screens/driver_breakdown.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show specOf;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

class _OfflineApp extends AppState {
  _OfflineApp() : super.forTesting();

  @override
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) async =>
      [];
}

class _QuietApp extends _OfflineApp {
  bool _windowOpen = false;

  @override
  bool get isConnected => true;
  @override
  bool get breathingWindowOpen => _windowOpen;
  @override
  Future<void> openBreathingWindow() async => _windowOpen = true;
  @override
  Future<void> closeBreathingWindow() async => _windowOpen = false;
}

Future<void> _fonts() async {
  for (final (family, directory) in [
    ('Manrope', 'Manrope'),
    ('.SF Pro Text', 'Manrope'),
    ('Barlow Condensed', 'BarlowCondensed'),
  ]) {
    final loader = FontLoader(family);
    for (final file in Directory(
      'assets/fonts/$directory',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
      loader.addFont(
        file.readAsBytes().then(
          (b) => ByteData.sublistView(Uint8List.fromList(b)),
        ),
      );
    }
    await loader.load();
  }
  final icons = FontLoader('packages/lucide_icons_flutter/Lucide');
  icons.addFont(
    rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
  );
  await icons.load();
}

Future<void> _capture(WidgetTester t, String name) async {
  final path = Platform.environment['EDGE_LAYOUT_ARTIFACTS'];
  if (path == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(path).create(recursive: true);
    await File('$path/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<_OfflineApp> _pump(
  WidgetTester t, {
  double width = 393,
  double height = 852,
  double scale = 1,
  bool reducedMotion = false,
  String language = 'en',
  _OfflineApp? appOverride,
}) async {
  t.view.physicalSize = Size(width, height);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final app = appOverride ?? _OfflineApp();
  await t.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reducedMotion,
          ),
          child: child!,
        ),
        home: const RepaintBoundary(
          key: ValueKey('capture'),
          child: CalmBreathing(),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });
  return app;
}

void main() {
  setUpAll(_fonts);

  testWidgets('all protocols, lengths and phase timings remain selectable', (
    t,
  ) async {
    await _pump(t);
    expect(find.text('RESONANCE'), findsWidgets);
    expect(find.text('5.5s'), findsNWidgets(2));
    await _capture(t, 'breathing-setup');
    await t.tap(find.text('BOX'));
    await t.pumpAndSettle();
    expect(find.text('4s'), findsNWidgets(4));
    await t.scrollUntilVisible(find.text('2 min'), 300);
    await t.tap(find.text('2 min'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await _capture(t, 'breathing-protocols');
  });

  testWidgets(
    'offline pacer counts the real phase and never invents coherence',
    (t) async {
      await _pump(t);
      await t.tap(find.text('BEGIN'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      expect(find.text('6'), findsOneWidget);
      expect(find.text('Inhale'), findsOneWidget);
      expect(find.text('No coherence score for this session'), findsOneWidget);
      await _capture(t, 'breathing-inhale');
      await t.pump(const Duration(seconds: 6));
      expect(find.text('Exhale'), findsOneWidget);
      expect(find.text('of 05:05'), findsOneWidget);
      await _capture(t, 'breathing-exhale');
      await t.tap(find.text('END SESSION'));
      await t.pumpAndSettle();
      expect(find.text('That is done.'), findsOneWidget);
      expect(find.text('No coherence score for this session'), findsOneWidget);
      expect(find.text('Cardiac coherence'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('a quiet window stays unpaced and can be stopped at large text', (
    t,
  ) async {
    final app = _QuietApp();
    await _pump(t, scale: 3.1, reducedMotion: true, appOverride: app);
    final window = find.text('Measure before and after · adds 4 min');
    await t.scrollUntilVisible(window.hitTestable(), 200);
    await t.tap(window);
    await t.pumpAndSettle();
    await t.tap(find.text('BEGIN'));
    await t.pump();
    expect(app.breathingWindowOpen, isTrue);
    expect(find.byType(BreathCircle), findsNothing);
    expect(find.text('BEFORE'), findsOneWidget);
    expect(t.takeException(), isNull);
    await _capture(t, 'breathing-quiet-large-text');
    await t.tap(find.text('STOP'));
    await t.pumpAndSettle();
    expect(app.breathingWindowOpen, isFalse);
    expect(find.text('BEGIN'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('both additional protocols expose their actual phase durations', (
    t,
  ) async {
    await _pump(t);
    for (final (label, seconds) in [
      ('4-7-8', ['4s', '7s', '8s']),
      ('LONG EXHALE', ['4s', '8s']),
    ]) {
      final choice = find.text(label).last;
      await t.scrollUntilVisible(choice.hitTestable(), 200);
      await t.tap(choice);
      await t.pumpAndSettle();
      t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await t.pumpAndSettle();
      for (final duration in seconds) {
        expect(find.text(duration), findsOneWidget);
      }
      expect(t.takeException(), isNull);
    }
  });

  testWidgets(
    'a recovery driver keeps history behind its tap and raw values hidden',
    (t) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final facts = [
        DriverFacts(
          key: 'hrv',
          spec: specOf('hrv'),
          used: true,
          contribution: 3.5,
          weightShare: 1,
          beyondUsualSpread: true,
          note: null,
          value: 70,
          usual: 65,
          halfBand: 5,
          delta: 5,
          mdcMultiples: 2,
          series: [for (var i = 0; i < 30; i++)
            i == 12 ? null : i == 29 ? 70.0 : 60 + i % 12.0],
        ),
        DriverFacts(
          key: 'temp',
          spec: specOf('skin_temp'),
          used: false,
          contribution: null,
          weightShare: null,
          beyondUsualSpread: false,
          note: 'need_baseline:have=2,need=7',
          value: 32411,
          usual: 32380,
          halfBand: null,
          delta: 31,
          mdcMultiples: null,
          series: const [],
        ),
      ];
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: RepaintBoundary(
            key: const ValueKey('capture'),
            child: Scaffold(
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(S.x4),
                  children: [DriverBreakdown(facts)],
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(ChartFrame), findsNothing);
      expect(find.textContaining('32411'), findsNothing);
      expect(find.textContaining('32380'), findsNothing);
      await t.tap(find.text('HRV'));
      await t.pumpAndSettle();
      expect(find.byType(ChartFrame), findsOneWidget);
      await _capture(t, 'recovery-driver-expanded');
      await t.tap(find.text('HRV').first);
      await t.pumpAndSettle();
      expect(find.byType(ChartFrame), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  for (final (width, height, scale) in [
    (320.0, 600.0, 1.0),
    (393.0, 852.0, 2.0),
    (393.0, 852.0, 3.1),
  ]) {
    testWidgets(
      'breathing scrolls at $width / ${scale}x, with reduced motion',
      (t) async {
        await _pump(
          t,
          width: width,
          height: height,
          scale: scale,
          reducedMotion: true,
          language: 'ru',
        );
        for (var i = 0; i < 5; i++) {
          await t.drag(find.byType(ListView), const Offset(0, -400));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        }
        final start = find.byType(Pressable).last;
        await t.tap(start);
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(t.takeException(), isNull);
        final stop = find.byType(Pressable).last;
        expect(stop.hitTestable(), findsOneWidget);
        await t.tap(stop);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      },
    );
  }
}
