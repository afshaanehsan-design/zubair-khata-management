import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';

void main() {
  late KhataDatabase db;
  late AppController app;
  setUp(() async {
    db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    app = AppController(db);
    await app.initialize();
  });
  tearDown(() async {
    app.dispose();
    await db.close();
  });
  test(
    'Fresh setup has no invented balances and queue survives reload',
    () async {
      expect(app.book.money('cash'), 0);
      expect(app.pendingCount, 0);
      await app.saveMaster('party', {
        'name': 'احمد',
        'customer': true,
      }, opening: 100000);
      expect(app.pendingCount, 1);
      expect(app.book.receivables, 100000);
      await app.reload();
      expect(app.book.receivables, 100000);
    },
  );
  test('Audited correction is atomic and original remains queryable', () async {
    await app.saveMaster('party', {'name': 'Ali', 'customer': true});
    final p = app.ofKind('party').single.id;
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': p,
      'cash': 10000,
    });
    final original = app.book.documents.single;
    await app.post(
      {...original.data, 'cash': 20000},
      replace: original,
      reason: 'Correct cash',
    );
    expect(app.book.money('cash'), 20000);
    expect(app.record(original.id)!.data['voided'], true);
    final command = app.commands.last;
    expect(command.changes.length, 2);
    expect(command.reason, 'Correct cash');
  });
  test(
    'Cylinder over-return and deposit over-refund leave no queued command',
    () async {
      await app.saveMaster('party', {'name': 'Ali'});
      final p = app.ofKind('party').single.id;
      final count = app.commands.length;
      await expectLater(
        app.post({
          'type': 'cylinder',
          'date': app.selectedDate,
          'party': p,
          'size': 11800,
          'emptyDelta': 1,
          'heldDelta': -1,
          'note': 'Return',
        }),
        throwsFormatException,
      );
      await expectLater(
        app.post({
          'type': 'depositRefund',
          'date': app.selectedDate,
          'party': p,
          'amount': 10000,
        }),
        throwsFormatException,
      );
      expect(app.commands.length, count);
    },
  );
  test('Backup checksums detect tampering before mutation', () async {
    final backup = await app.backup();
    (backup['data'] as Map)['schema'] = 99;
    await expectLater(app.restoreBackup(backup), throwsFormatException);
    expect(app.book.money('cash'), 0);
  });
  test('A cursor gap rolls back records and cursor together', () async {
    await expectLater(
      db.applyBundles([
        {'sequence': 2, 'command_id': 'x', 'records': []},
      ], 2),
      throwsStateError,
    );
    expect(await db.meta('cursor'), null);
  });
  test('Snapshot restoration retains history and restores balances', () async {
    await app.saveMaster('party', {'name': 'Ali'});
    final p = app.ofKind('party').single.id;
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': p,
      'cash': 10000,
    });
    await app.saveSnapshot();
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': p,
      'cash': 20000,
    });
    await app.restoreSnapshot(
      app.ofKind('snapshot').single,
      'Restore saved day',
    );
    expect(app.book.money('cash'), 10000);
    expect(app.ofKind('document').length, 3);
  });
  test('Reset erases every kind of data and keeps only the device setup', () async {
    final device = app.device;
    await app.setLanguage('ur');
    await app.saveMaster('account', {'name': 'HBL', 'bank': 'HBL'});
    await app.saveMaster('party', {'name': 'Ali'}, opening: 50000);
    final p = app.partyByName('Ali')!.id;
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': p,
      'cash': 10000,
    });
    await app.startBatch(); // a snapshot that carries the Khata Saaf time
    await app.commit([
      Change('business', 'settings', {
        'name': 'Ali Gas',
        'phone': '0300',
        'address': 'Lahore',
        'defaultRate': 460000,
      }, 1),
    ]);
    app.composerDrafts['context:purchase'] = {'amount': '5'};
    // What an older version kept on the device: a Khata Saaf in metadata
    // and composer drafts in their own table.
    await db.setMeta('batch:2026-01-01', '1767225600000');
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS drafts (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    );
    await db.customStatement(
      "INSERT INTO drafts VALUES ('composer', '{\"amount\":\"5\"}')",
    );
    await db.setMeta('pre_restore', '{"old":"copy"}');
    await db.setMeta('cursor', '7');
    await db.setMeta('epoch', 'old-epoch');
    // A table added by a later version is emptied too.
    await db.customStatement('CREATE TABLE future_data (x TEXT)');
    await db.customStatement("INSERT INTO future_data VALUES ('kept?')");
    app.rozDrafts['sale'] = {'amount': '9'};
    // A saved draft (the Draft button), kept in metadata `entry_drafts`.
    await app.saveEntryDraft(
      source: EntryDraft.roznamcha,
      tab: 'aamad',
      date: '2026-01-02',
      data: {'party': 'Ali', 'q11800': '2'},
    );
    expect(await db.meta('entry_drafts'), isNotNull);
    app.setDate('2026-01-02');
    expect(app.pendingCount, greaterThan(0));
    expect(app.batchStarts, isNotEmpty);

    await app.resetAll();

    expect(app.records.map((r) => r.id).toSet(), {'cash', 'business'});
    expect(app.businessName, 'Zubair Traders');
    expect(app.commands, isEmpty);
    expect(app.book.documents, isEmpty);
    expect(app.book.money('cash'), 0);
    expect(app.book.receivables, 0);
    expect(app.batchStarts, isEmpty);
    expect(app.rozDrafts, isEmpty);
    expect(app.selectedDate, businessDate());
    expect(app.composerDrafts, isEmpty);
    expect(app.entryDrafts, isEmpty);
    expect(app.preRestoreSaved, isFalse);
    final oldDrafts = await db
        .customSelect('SELECT COUNT(*) AS n FROM drafts')
        .getSingle();
    expect(oldDrafts.read<int>('n'), 0);
    final future = await db
        .customSelect('SELECT COUNT(*) AS n FROM future_data')
        .getSingle();
    expect(future.read<int>('n'), 0);
    final meta = {
      for (final r in await db.customSelect('SELECT * FROM metadata').get())
        r.read<String>('key'): r.read<String>('value'),
    };
    expect(meta, {'device': device, 'language': 'ur', 'initialized': '1'});
    expect(app.language, 'ur');

    // The fresh khata works like a new install.
    await app.saveMaster('party', {'name': 'Ali'});
    expect(app.ofKind('party').single.name, 'Ali');
    await app.reload();
    expect(app.ofKind('party').length, 1);
  });
  test('A cloud-linked device that is signed out refuses to reset', () async {
    await app.saveMaster('party', {'name': 'Ali'});
    app.owner = 'cloud-owner';
    await expectLater(app.resetAll(), throwsStateError);
    await app.reload();
    expect(app.ofKind('party').single.name, 'Ali');
    expect(app.pendingCount, 1);
  });
}
