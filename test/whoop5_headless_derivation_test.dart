import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/sync/background_sync.dart';

BleEngine _engine(String? family) {
  final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
  engine.state.generation = family;
  return engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a WHOOP 5 BGTask defers its intermediate pass until all inputs land',
    () async {
      final engine = _engine('gen5');
      var lightPasses = 0;
      var deferred = false;

      await deriveAfterHeadlessDrain(
        engine,
        deferWhoop5Derivation: () => deferred = true,
        derive: () async => lightPasses++,
      );

      expect(
        lightPasses,
        0,
        reason: 'the BGTask derives once after the remaining sensors finish',
      );
      expect(deferred, isTrue);
    },
  );

  test('a WHOOP 5 restore wake still waits for its light pass', () async {
    final engine = _engine('gen5');
    final release = Completer<void>();
    var started = false;
    var finished = false;

    final work = deriveAfterHeadlessDrain(
      engine,
      derive: () async {
        started = true;
        await release.future;
      },
    ).then((_) => finished = true);
    await pumpEventQueue();
    expect(started, isTrue);
    expect(finished, isFalse);
    release.complete();
    await work;
    expect(finished, isTrue);
  });

  for (final family in <String?>['gen4', null]) {
    test('the existing $family path retains its light derivation', () async {
      var lightPasses = 0;
      await deriveAfterHeadlessDrain(
        _engine(family),
        deferWhoop5Derivation: () => fail('legacy path must use its light pass'),
        derive: () async => lightPasses++,
      );
      expect(lightPasses, 1);
    });
  }

  test(
    'a light-pass failure leaves the next WHOOP 5 wake able to process',
    () async {
      final engine = _engine('gen5');
      await deriveAfterHeadlessDrain(
        engine,
        derive: () async {
          throw StateError('compute unavailable');
        },
      );

      var retried = false;
      await deriveAfterHeadlessDrain(
        engine,
        derive: () async => retried = true,
      );
      expect(retried, isTrue);
    },
  );

  test('a failed deferral does not start another intermediate pass',
      () async {
    var lightPasses = 0;
    await deriveAfterHeadlessDrain(
      _engine('gen5'),
      deferWhoop5Derivation: () => throw StateError('execution budget ended'),
      derive: () async => lightPasses++,
    );
    expect(lightPasses, 0);
  });
}
