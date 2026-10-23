import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  for (final scale in [1.0, 2.0, 3.1]) {
    testWidgets('coach shortcut preserves all four tabs at ${scale}x', (t) async {
      t.view.physicalSize = const Size(393, 852);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final semantics = t.ensureSemantics();
      var coachOpened = 0;
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        locale: const Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AppShell(
          onCoach: () => coachOpened++,
          builder: (_, domain) => Center(child: Text('screen ${domain.name}')),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      for (final label in ['Sommeil', 'Activité', 'Santé', "Aujourd'hui"]) {
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
      expect(find.text('screen today'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Coach'));
      await t.pumpAndSettle();
      expect(coachOpened, 1);
      expect(find.text('screen today'), findsOneWidget);
      semantics.dispose();
    });
  }
}
