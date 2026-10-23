// The Sleep tab.
//
// Sleep used to be spread over the Home ring, a Health row that opened a
// generic chart, Wellness's "Recovery" sub-tab (need, debt, bedtime), Health's
// Body clock and the alarm in Settings. This tab is the Sleep screen itself,
// with those pieces under the night. The screens are the same ones; only
// where they live changed.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../profile/alarm.dart';
import '../ui2.dart';
import 'circadian_detail.dart';
import 'sleep_detail.dart';
import 'wellness_screen.dart';

class SleepTab extends StatelessWidget {
  const SleepTab({super.key});

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return SleepDetail(
      embedded: true,
      footer: [
        Section(
          l?.sleepTabPlanTitle ?? 'Your sleep plan',
          const WellnessScreen(sleepPlanOnly: true),
        ),
        Section(
          l?.sleepTabMoreTitle ?? 'Alarm and body clock',
          Surface(
            pad: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(
              children: [
                _tool(
                  c,
                  LucideIcons.alarmClock,
                  l?.settingsAlarmRowTitle ?? 'Alarm',
                  l?.settingsAlarmRowSub ??
                      'Buzzes on your wrist, on the band’s own clock',
                  () => Navigator.of(c).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AlarmScreen(),
                    ),
                  ),
                ),
                Divider(height: 1, color: P.of(c).line),
                _tool(
                  c,
                  LucideIcons.sunMoon,
                  l?.healthBodyClockTitle ?? 'Body clock',
                  l?.healthChronotypeJetlagRegularity ??
                      'Natural bedtime, weekend shift and schedule consistency',
                  () => Navigator.of(c).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CircadianDetail(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tool(
    BuildContext c,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x4),
        child: Row(
          children: [
            Icon(icon, size: S.x5, color: p.on(C.domSleep)),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.toUpperCase(),
                    style: F.section.copyWith(color: p.ink),
                  ),
                  const SizedBox(height: S.x1),
                  Text(subtitle, style: F.cap.copyWith(color: p.ink3)),
                ],
              ),
            ),
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: S.x5, color: p.ink3),
          ],
        ),
      ),
    );
  }
}
