import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'openstrap_whoop5_derive_paging_test.db';
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
    final db = await LocalDb.instance;
    final batch = db.batch();
    for (var i = 0; i < 251; i++) {
      for (final device in ['', 'paired', 'unverified']) {
        batch.insert('decoded_onehz', {
          'device_id': device,
          'ts_ms': (1700000000 + i) * 1000,
          'rec_ts': 1700000000 + i,
          // The strap reboots partway through, and device rows can share time.
          'counter': i < 120 ? i : i - 120 + (device == 'paired' ? 1000 : 0),
          'hr': i % 2 == 0 ? null : 61,
          'device_family': 'gen5',
          'source': device == 'unverified' ? 'unverified' : null,
        });
      }
    }
    await batch.commit(noResult: true);
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  Future<List<Map<String, dynamic>>> read({
    required bool seek,
    required int limit,
    int from = 1700000000,
    int? afterTs,
    int? afterCounter,
  }) => LocalDb.decodedOneHzBatchByRecTsRange(
    limit: limit,
    fromRecTs: from,
    toRecTs: 1700000250,
    afterRecTs: afterTs,
    afterCounter: afterCounter,
    seekFromCursor: seek,
  );

  test(
    'seek preserves each page through resets, device seams and NULL input',
    () async {
      int? ts;
      int? counter;
      var pages = 0;
      while (true) {
        final old = await read(
          seek: false,
          limit: 17,
          afterTs: ts,
          afterCounter: counter,
        );
        final seek = await read(
          seek: true,
          limit: 17,
          afterTs: ts,
          afterCounter: counter,
        );
        expect(seek, old, reason: 'page $pages must return the same rows');
        if (old.isEmpty) break;
        expect(old.any((r) => r['device_id'] == 'unverified'), isFalse);
        ts = (old.last['rec_ts'] as num).toInt();
        counter = (old.last['counter'] as num).toInt();
        pages++;
        expect(pages, lessThan(100), reason: 'cursor must always progress');
      }
      expect(pages, greaterThan(20));
    },
  );

  test('cursor before from cannot widen the original window', () async {
    final old = await read(
      seek: false,
      limit: 500,
      from: 1700000200,
      afterTs: 1700000050,
      afterCounter: 50,
    );
    final seek = await read(
      seek: true,
      limit: 500,
      from: 1700000200,
      afterTs: 1700000050,
      afterCounter: 50,
    );
    expect(seek, old);
    expect(seek.first['rec_ts'], 1700000200);
  });

  test(
    'initial, partial and exhausted cursors keep existing semantics',
    () async {
      for (final cursor in [
        (null, null),
        (1700000010, null),
        (null, 10),
        (1700000251, 0),
      ]) {
        expect(
          await read(
            seek: true,
            limit: 17,
            afterTs: cursor.$1,
            afterCounter: cursor.$2,
          ),
          await read(
            seek: false,
            limit: 17,
            afterTs: cursor.$1,
            afterCounter: cursor.$2,
          ),
        );
      }
    },
  );
}
