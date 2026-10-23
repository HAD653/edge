// Synthetic presentation snapshots only. Never insert these into a repository,
// AppState, SQLite, HealthKit, widget snapshots, or a wearable session.
import '../../data/day_label.dart';
import '../../models/metric.dart';
import '../activity/catalogue.dart';
import '../activity/summary.dart';
import '../screens/home_screen.dart';
import '../screens/metric_detail.dart';
import '../screens/readiness_detail.dart';
import '../screens/sleep_detail.dart';
import '../ui2.dart';

/// One reproducible sample, dated to the day the demo was opened. No plugins,
/// timers, randomness, persistence, or network calls are needed to construct it.
class DemoData {
  final DateTime today;

  DemoData({DateTime? now}) : today = _midnight(now ?? DateTime.now());

  static const historyDays = 30;
  static const metricKeys = [
    'resting_hr',
    'hrv',
    'steps',
    'calories',
    'strain',
    'sleep',
  ];

  String get day => dayLabelOf(today);

  static Metric _metric(double value, {String? unit}) => Metric(
    value: value,
    unit: unit,
    confidence: .8,
    tier: MetricTier.estimate,
  );

  List<ChartPoint> series(String key) {
    final (latest, spread) = switch (key) {
      'resting_hr' => (54.0, 4.0),
      'hrv' => (68.0, 12.0),
      'steps' => (8420.0, 2800.0),
      'calories' => (480.0, 130.0),
      'strain' => (12.4, 4.0),
      'sleep' => (450.0, 35.0),
      'readiness' => (82.0, 15.0),
      _ => throw ArgumentError.value(key, 'key', 'No demo fixture'),
    };
    return [
      for (var ago = historyDays - 1; ago >= 0; ago--)
        (
          t:
              DateTime(
                today.year,
                today.month,
                today.day - ago,
                12,
              ).millisecondsSinceEpoch ~/
              1000,
          v: ago == 0 ? latest : latest + ((ago * 7 % 13) - 6) / 6 * spread,
        ),
    ];
  }

  MetricData metric(String key) => MetricData(
    series: series(key),
    daysAvailable: historyDays,
    wear: [for (final point in series(key)) (t: point.t, v: 1380)],
  );

  HomeData get home => HomeData(
    name: 'Alex',
    dayId: day,
    readiness: _metric(82),
    strain: _metric(12.4),
    sleepMin: _metric(450, unit: 'min'),
    sleepNeedMin: _metric(480, unit: 'min'),
    rhr: _metric(54),
    steps: _metric(8420),
    calories: _metric(480),
  );

  ReadinessData get recovery => ReadinessData(
    readiness: _metric(82),
    series: [for (final point in series('readiness')) point.v],
  );

  SleepData get sleep {
    final wake =
        DateTime(
          today.year,
          today.month,
          today.day,
          7,
        ).millisecondsSinceEpoch ~/
        1000;
    final onset = wake - 480 * 60;
    // Segment minutes sum to eight hours: 450 asleep, 30 awake. Derive all
    // displayed totals from this fixture so the chart and cards agree.
    const segments = <(String, int)>[
      ('light', 35),
      ('deep', 45),
      ('light', 40),
      ('rem', 25),
      ('awake', 10),
      ('light', 40),
      ('deep', 35),
      ('light', 35),
      ('rem', 30),
      ('awake', 10),
      ('light', 45),
      ('deep', 20),
      ('light', 30),
      ('rem', 30),
      ('light', 40),
      ('awake', 10),
    ];
    var elapsed = 0;
    final hypnogram = <Map<String, Object>>[];
    final totals = <String, int>{};
    for (final (stage, minutes) in segments) {
      hypnogram.add({'t': onset + elapsed * 60, 'stage': stage});
      totals[stage] = (totals[stage] ?? 0) + minutes;
      elapsed += minutes;
    }
    hypnogram.add({'t': wake, 'stage': 'awake'});
    return SleepData(
      day: day,
      night: {
        'duration_min': 450,
        'in_bed_min': 480,
        'efficiency': 450 / 480,
        'onset_ts': onset,
        'wake_ts': wake,
        for (final stage in totals.entries) '${stage.key}_min': stage.value,
        'hypnogram': hypnogram,
        'nocturnal': {'sleeping_hr_avg': 57, 'sleeping_hr_min': 54},
      },
      timeline: {
        for (final (key, base, spread) in [
          ('hr', 57.0, 4.0),
          ('hrv', 68.0, 9.0),
          ('resp', 14.2, .6),
        ])
          key: [
            for (var i = 0; i <= 96; i++)
              {
                't': onset + i * 300,
                'v': base + ((i * 3 % 9) - 4) / 4 * spread,
              },
          ],
      },
      need: _metric(480),
      debt: _metric(30),
      tstHistory: [for (var i = 0; i < 28; i++) 420 + (i * 7 % 60).toDouble()],
      effHistory: [for (var i = 0; i < 28; i++) 90 + (i % 7).toDouble()],
      unobservedMin: 0,
      awakenings: 2,
      longestSleepMin: 165,
    );
  }

  ActivityResult get run => ActivityResult(
    activityByName('Running')!,
    start: DateTime(today.year, today.month, today.day - 1, 18, 30),
    duration: Motion.tick * 1800,
    distanceKm: 5,
    avgHr: 148,
    maxHr: 165,
    calories: 320,
    strain: 8.2,
    steps: 4920,
    hr: [for (var i = 0; i < 60; i++) 134 + (i * 7 % 32).toDouble()],
    zoneMinutes: const [2, 6, 16, 6, 0],
    splits: const [
      KmSplit(1, 370, avgHr: 140),
      KmSplit(1, 360, avgHr: 146),
      KmSplit(1, 350, avgHr: 154),
      KmSplit(1, 355, avgHr: 153),
      KmSplit(1, 365, avgHr: 147),
    ],
  );
}

// Calendar construction keeps history dates stable across daylight saving.
DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);
