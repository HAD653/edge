import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/display_text.dart';
import '../../data/day_label.dart';
import '../activity/summary.dart';
import '../screens/home_screen.dart';
import '../screens/metric_detail.dart';
import '../screens/readiness_detail.dart';
import '../screens/sleep_detail.dart';
import '../ui2.dart';
import 'demo_data.dart';

/// An ephemeral route above onboarding. Its navigator keeps the demo banner
/// visible on every detail screen. All destinations receive snapshots; none
/// is given a repository, a paired device, or a save callback.
class DemoScreen extends StatefulWidget {
  final DemoData? data;
  const DemoScreen({super.key, this.data});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  late final DemoData _data = widget.data ?? DemoData();
  final _navigator = GlobalKey<NavigatorState>();
  Brightness? _brightness;

  @override
  Widget build(BuildContext context) => Theme(
    data: buildTheme(_brightness ?? Theme.of(context).brightness),
    child: Builder(
      builder: (c) {
        final p = P.of(c);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: Theme.of(c).brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: Scaffold(
            backgroundColor: p.bg,
            body: SafeArea(
              bottom: false,
              child: Column(
                // Navigator's modal route blocks semantics painted before it.
                // Paint the banner last, while keeping it visually at the top,
                // so VoiceOver can always identify and leave the demo.
                verticalDirection: VerticalDirection.up,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: NavigatorPopHandler<void>(
                      onPopWithResult: (_) =>
                          _navigator.currentState?.maybePop(),
                      child: Navigator(
                        key: _navigator,
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (_) => AppShell(
                            builder: (c, domain) => switch (domain) {
                              ShellDomain.today => _today(c),
                              ShellDomain.sleep => SleepDetail(
                                data: _data.sleep,
                                embedded: true,
                                readOnly: true,
                              ),
                              ShellDomain.activity => _activity(c),
                              ShellDomain.health => _health(c),
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  DemoBanner(
                    onExit: () => Navigator.of(context).pop(),
                    onTheme: () => setState(() {
                      _brightness = Theme.of(c).brightness == Brightness.dark
                          ? Brightness.light
                          : Brightness.dark;
                    }),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  void _open(BuildContext c, Widget page) =>
      Navigator.of(c).push<void>(MaterialPageRoute(builder: (_) => page));

  void _metric(BuildContext c, String key) =>
      _open(c, MetricDetail(key, data: _data.metric(key), readOnly: true));

  Widget _page(BuildContext c, String title, List<Widget> children) => ListView(
    padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x12),
    children: [ScreenTitle(title), ...children],
  );

  Widget _today(BuildContext c) {
    final l = AppLocalizations.of(c);
    return _page(c, l?.demoTodayTitle ?? 'A day with Alex', [
      RingTrio(
        d: _data.home,
        onOpen: (kind) => switch (kind) {
          HomeRingKind.recovery => _open(
            c,
            ReadinessDetail(data: _data.recovery, readOnly: true),
          ),
          HomeRingKind.strain => _metric(c, 'strain'),
          HomeRingKind.sleep => _open(
            c,
            SleepDetail(data: _data.sleep, readOnly: true),
          ),
        },
      ),
      const SizedBox(height: S.x5),
      _signal(c, 'resting_hr'),
      const SizedBox(height: S.x3),
      _signal(c, 'steps'),
      const SizedBox(height: S.x3),
      _signal(c, 'calories'),
      const SizedBox(height: S.x5),
      _runCard(c),
    ]);
  }

  Widget _signal(BuildContext c, String key) {
    final spec = specOf(key);
    final value = _data.series(key).last.v;
    return SignalCard(
      spec.icon,
      spec.color,
      uiText(c, spec.title),
      value.toStringAsFixed(key == 'strain' ? 1 : 0),
      unit: spec.unit,
      onTap: () => _metric(c, key),
    );
  }

  Widget _health(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return _page(c, ShellDomain.health.title(c), [
      Text(
        l?.demoHistory ?? '30 days of sample trends',
        style: F.body.copyWith(color: p.ink2),
      ),
      const SizedBox(height: S.x5),
      for (final key in DemoData.metricKeys) ...[
        Builder(
          builder: (c) {
            final spec = specOf(key);
            final points = _data.series(key);
            return TrendCard(
              uiText(c, spec.title),
              points.last.v.toStringAsFixed(key == 'strain' ? 1 : 0),
              spec.unit,
              '',
              l?.metricDetailRange30Days ?? '30 days',
              [for (final point in points) point.v],
              spec.color,
              good: null,
              dayOf: (i) => prettyDay(
                dayLabelOf(
                  DateTime.fromMillisecondsSinceEpoch(points[i].t * 1000),
                ),
                l,
              ),
              onTap: () => _metric(c, key),
            );
          },
        ),
        const SizedBox(height: S.x3),
      ],
    ]);
  }

  Widget _runCard(BuildContext c) {
    final l = AppLocalizations.of(c);
    return ActionCard(
      l?.demoRunTitle ?? 'An example run',
      '5 km · 30 min',
      l?.demoOpenActivity ?? 'View activity',
      LucideIcons.footprints,
      C.domMove,
      onTap: () => _open(c, ActivitySummary(_data.run, readOnly: true)),
    );
  }

  Widget _activity(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return _page(c, ShellDomain.activity.title(c), [
      Text(
        l?.demoActivityBody ??
            'Explore the summary, splits and heart-rate charts of a sample session.',
        style: F.body.copyWith(color: p.ink2),
      ),
      const SizedBox(height: S.x5),
      _runCard(c),
      const SizedBox(height: S.x5),
      _signal(c, 'strain'),
      const SizedBox(height: S.x3),
      _signal(c, 'steps'),
      const SizedBox(height: S.x3),
      _signal(c, 'calories'),
    ]);
  }
}

/// Also exercised in the component gallery at large accessibility text sizes.
class DemoBanner extends StatelessWidget {
  final VoidCallback? onExit, onTheme;
  const DemoBanner({super.key, this.onExit, this.onTheme});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Container(
      color: p.wash(C.blue),
      padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
      child: Wrap(
        spacing: S.x3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l?.demoSampleData ?? 'Demo · Fictional data',
            style: F.cap.copyWith(color: p.on(C.blue)),
          ),
          IconButton(
            onPressed: onTheme,
            tooltip: l?.demoTheme ?? 'Switch appearance',
            icon: Icon(LucideIcons.sunMoon, color: p.on(C.blue)),
          ),
          TextButton(
            onPressed: onExit,
            child: Text(l?.demoExit ?? 'Exit demo'),
          ),
        ],
      ),
    );
  }
}
