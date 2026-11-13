// Roznamcha Save, Agla Din and Khata Saaf keep the day as a snapshot record.
import 'dart:convert';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';

Future<AppController> open() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return app;
}

Future<void> receipt(AppController app, int cash) async {
  if (app.partyByName('Ali') == null) {
    await app.saveMaster('party', {'name': 'Ali', 'customer': true});
  }
  await app.post({
    'type': 'receipt',
    'date': app.selectedDate,
    'party': app.partyByName('Ali')!.id,
    'cash': cash,
  });
}

void main() {
  test('A day that has not changed is not saved again', () async {
    final app = await open();
    await receipt(app, 10000);
    await app.saveSnapshot(); // Roznamcha Save
    await app.saveSnapshot(); // and again
    await app.saveSnapshot(); // Agla Din saves the day first
    expect(app.ofKind('snapshot').length, 1);

    await receipt(app, 20000);
    await app.saveSnapshot();
    expect(app.ofKind('snapshot').length, 2);

    // An archived snapshot is hidden from Day history, so the same day is
    // saved again rather than left with nothing to show.
    final latest = app
        .ofKind('snapshot')
        .reduce(
          (a, b) => '${a.data['savedAt']}'.compareTo('${b.data['savedAt']}') > 0
              ? a
              : b,
        );
    await app.commit([
      Change(latest.id, 'snapshot', {
        ...latest.data,
        'archived': true,
      }, latest.version),
    ]);
    await app.saveSnapshot();
    expect(app.ofKind('snapshot').length, 2);
    expect(app.ofKind('snapshot', archived: true).length, 3);
    await app.db.close();
  });

  test('Khata Saaf is stored on its snapshot, so it syncs', () async {
    final app = await open();
    final date = app.selectedDate;
    await receipt(app, 10000);
    final before = DateTime.now().millisecondsSinceEpoch;
    await app.startBatch();
    final batch = app.ofKind('snapshot').single;
    expect(integer(batch.data['batchAt']), greaterThanOrEqualTo(before));
    expect(app.batchStarts[date], batch.data['batchAt']);
    expect(await app.db.meta('batch:$date'), isNull);
    // A second Khata Saaf on an unchanged day still records its own time.
    await app.startBatch();
    expect(app.ofKind('snapshot').length, 2);
    final latest = app
        .ofKind('snapshot')
        .map((s) => integer(s.data['batchAt']));
    expect(app.batchStarts[date], latest.reduce(max));

    // Another device that receives the snapshots knows about the batch.
    final db2 = KhataDatabase(NativeDatabase.memory());
    await db2.initialize();
    final other = AppController(db2);
    await other.initialize();
    for (final s in app.ofKind('snapshot')) {
      await db2.customStatement('INSERT INTO records VALUES(?,?,?,?)', [
        s.id,
        s.kind,
        jsonEncode(s.data),
        1,
      ]);
    }
    await other.reload();
    expect(other.batchStarts, app.batchStarts);

    // A Khata Saaf that an older version kept in this device's metadata
    // still counts, and the latest of the two wins.
    await app.db.setMeta('batch:2026-01-01', '42');
    await app.db.setMeta('batch:$date', '1');
    await app.reload();
    expect(app.batchStarts['2026-01-01'], 42);
    expect(app.batchStarts[date], latest.reduce(max));
    await app.db.close();
    await db2.close();
  });
}
