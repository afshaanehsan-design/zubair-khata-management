// Several organizations on one device: each is its own database file, and
// the list of them is rebuilt from those files if it is lost.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/core/organizations.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/data/secure_auth.dart';
import 'package:zubair_khata_management/ui/export_ui.dart';

/// Opens a database file in this isolate (the app uses a background one).
Future<KhataDatabase> fileDatabase(File file) async {
  final db = KhataDatabase(NativeDatabase(file));
  await db.initialize();
  return db;
}

void main() {
  late Directory dir;
  Organizations? orgs;

  Future<Organizations> open() async =>
      orgs = await Organizations.open(directory: dir, opener: fileDatabase);
  Future<void> close() async {
    await orgs?.close();
    orgs = null;
  }

  File inDir(String name) => File(p.join(dir.path, name));
  Json registry() =>
      decodeObject(inDir(Organizations.registryFile).readAsStringSync());

  Future<void> receipt(AppController app, String party, int paisa) async {
    await app.saveMaster('party', {'name': party, 'customer': true});
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': app.partyByName(party)!.id,
      'cash': paisa,
    });
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('khata-orgs-'));
  tearDown(() async {
    await close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'A database from before organizations opens as the first one, unchanged',
    () async {
      // What a device holds before this version: one file, no list.
      final old = await fileDatabase(inDir(KhataDatabase.mainFile));
      final before = AppController(old);
      await before.initialize();
      await before.setLanguage('ur');
      await before.commit([
        Change('business', 'settings', {
          'name': 'Old Traders',
          'phone': '0300',
          'address': 'Lahore',
          'defaultRate': 460000,
        }, 1),
      ]);
      await before.saveMaster('party', {
        'name': 'Ali',
        'customer': true,
      }, opening: 50000);
      await before.post({
        'type': 'receipt',
        'date': before.selectedDate,
        'party': before.partyByName('Ali')!.id,
        'cash': 10000,
      });
      final cash = before.book.money('cash'),
          receivables = before.book.receivables,
          commands = before.commands.map((c) => c.id).toList(),
          device = before.device;
      before.dispose();
      await old.close();
      // A manual copy beside it, as made before a live-data fix.
      inDir(KhataDatabase.mainFile).copySync(
        inDir('khata-v1.backup-2026-11-10-before-fix.sqlite').path,
      );

      final o = await open();
      expect(o.list.map((x) => (x.id, x.name)), [
        (Organization.main, 'Old Traders'),
      ]);
      expect(o.current.file, KhataDatabase.mainFile);
      expect(o.language, 'ur');
      final app = o.app;
      expect(app.language, 'ur');
      expect(app.device, device);
      expect(app.businessName, 'Old Traders');
      expect(app.settings['defaultRate'], 460000);
      expect(app.book.money('cash'), cash);
      expect(app.book.receivables, receivables);
      // Nothing was added to the queue by the upgrade.
      expect(app.commands.map((c) => c.id), commands);
      expect(registry()['current'], Organization.main);
    },
  );

  test('A new installation starts with one organization', () async {
    final o = await open();
    expect(o.list.single.id, Organization.main);
    expect(o.app.businessName, AppController.defaultBusinessName);
    expect(o.app.commands, isEmpty);
    expect(inDir(KhataDatabase.mainFile).existsSync(), true);
  });

  test('Organizations keep separate books and the last one reopens', () async {
    var o = await open();
    await receipt(o.app, 'Ali', 10000);
    final first = o.app;

    final added = await o.create('  Ali Gas ');
    expect(added.name, 'Ali Gas');
    expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(added.id), true);
    expect(inDir(added.file).existsSync(), true);
    expect(o.current, added);
    expect(o.app, isNot(first));
    expect(o.app.businessName, 'Ali Gas');
    expect(o.app.ofKind('party'), isEmpty);
    expect(o.app.book.money('cash'), 0);
    expect(o.app.device, isNot(first.device));
    await receipt(o.app, 'Bilal', 7000);

    await o.switchTo(Organization.main);
    expect(o.app.businessName, AppController.defaultBusinessName);
    expect(o.app.ofKind('party').map((r) => r.name), ['Ali']);
    expect(o.app.book.money('cash'), 10000);

    await o.switchTo(added.id);
    expect(o.app.ofKind('party').map((r) => r.name), ['Bilal']);
    expect(o.app.book.money('cash'), 7000);

    // Closing and starting again opens the one used last.
    await close();
    o = await open();
    expect(o.current.id, added.id);
    expect(o.list.map((x) => x.name), [
      AppController.defaultBusinessName,
      'Ali Gas',
    ]);
    expect(o.app.businessName, 'Ali Gas');
    expect(o.app.book.money('cash'), 7000);
  });

  test('A name is needed and cannot be used twice', () async {
    final o = await open();
    await o.create('Ali Gas');
    await expectLater(o.create('  '), throwsFormatException);
    await expectLater(o.create('ali   gas'), throwsFormatException);
    await expectLater(
      o.create(AppController.defaultBusinessName),
      throwsFormatException,
    );
    expect(o.list.length, 2);
    expect(o.current.name, 'Ali Gas');
    await expectLater(o.switchTo('nothing'), throwsStateError);
    expect(o.current.name, 'Ali Gas');
  });

  test('Reset erases only the open organization and keeps its name', () async {
    final o = await open();
    await receipt(o.app, 'Ali', 10000);
    await o.create('Ali Gas');
    await receipt(o.app, 'Bilal', 7000);

    await o.app.resetAll();

    expect(o.app.businessName, 'Ali Gas');
    expect(o.current.name, 'Ali Gas');
    expect(o.app.records.map((r) => r.id).toSet(), {'cash', 'business'});
    expect(o.app.book.documents, isEmpty);
    // Only the queued change that carries the name is left.
    expect(o.app.commands.single.changes.single.id, 'business');
    expect(o.list.length, 2);

    await o.switchTo(Organization.main);
    expect(o.app.ofKind('party').map((r) => r.name), ['Ali']);
    expect(o.app.book.money('cash'), 10000);
    // The first organization has the default name, so its reset adds nothing.
    await o.app.resetAll();
    expect(o.app.commands, isEmpty);
    expect(o.app.businessName, AppController.defaultBusinessName);
  });

  test('Each organization is reset on its own, completely', () async {
    String hash(String file) =>
        sha256.convert(inDir(file).readAsBytesSync()).toString();
    Future<Map<String, String>> meta(AppController app) async => {
      for (final r in await app.db.customSelect('SELECT * FROM metadata').get())
        r.read<String>('key'): r.read<String>('value'),
    };
    // Everything a khata can hold besides entries: a bank account, a saved
    // day and its batch, a draft, a recovery copy and sync state.
    Future<void> fill(AppController app, String party) async {
      await app.saveMaster('account', {'name': 'HBL', 'bank': 'HBL'});
      await receipt(app, party, 10000);
      await app.startBatch();
      app.composerDrafts['context:purchase'] = {'amount': '5'};
      await app.db.setMeta('pre_restore', '{"old":"copy"}');
      await app.db.setMeta('cursor', '7');
      app.rozDrafts['sale'] = {'amount': '9'};
      app.setDate('2026-01-02');
    }

    final o = await open();
    await fill(o.app, 'Ali');
    final first = Organization.main;
    final second = await o.create('Ali Gas');
    await fill(o.app, 'Bilal');
    final third = await o.create('Third Traders');
    await fill(o.app, 'Chand');
    final device = o.app.device;

    // Reset the third. The other two are closed files: not one byte changes.
    final before = {first: hash(o.list[0].file), second.id: hash(second.file)};
    await o.app.resetAll();
    expect(hash(o.list[0].file), before[first]);
    expect(hash(second.file), before[second.id]);
    expect(o.current, third);
    expect(o.list.map((x) => x.name), [
      AppController.defaultBusinessName,
      'Ali Gas',
      'Third Traders',
    ]);
    expect(o.app.businessName, 'Third Traders');
    expect(o.app.records.map((r) => r.id).toSet(), {'cash', 'business'});
    expect(o.app.book.documents, isEmpty);
    expect(o.app.book.money('cash'), 0);
    expect(o.app.batchStarts, isEmpty);
    expect(o.app.rozDrafts, isEmpty);
    expect(o.app.selectedDate, businessDate());
    expect(o.app.composerDrafts, isEmpty);
    expect(await meta(o.app), {
      'device': device,
      'language': 'en',
      'initialized': '1',
    });

    // The other two still hold everything stored. (Form drafts are kept in
    // memory and end with each organization's session.)
    for (final (id, party) in [(first, 'Ali'), (second.id, 'Bilal')]) {
      await o.switchTo(id);
      expect(o.app.ofKind('party').map((r) => r.name), [party]);
      expect(o.app.ofKind('account').map((r) => r.name), ['Cash', 'HBL']);
      expect(o.app.book.money('cash'), 10000);
      expect(o.app.ofKind('snapshot').length, 1);
      expect(o.app.batchStarts, isNotEmpty);
      expect(await o.app.db.meta('pre_restore'), '{"old":"copy"}');
      expect(await o.app.db.meta('cursor'), '7');
    }

    // Now reset the second: the first and the already empty third stay as
    // they are.
    final third0 = hash(third.file), first0 = hash(o.list[0].file);
    await o.app.resetAll();
    expect(hash(third.file), third0);
    expect(hash(o.list[0].file), first0);
    expect(o.app.businessName, 'Ali Gas');
    expect(o.app.ofKind('party'), isEmpty);
    await o.switchTo(first);
    expect(o.app.book.money('cash'), 10000);

    // A cloud-linked organization that is signed out refuses to reset, and
    // that stops only itself.
    await o.switchTo(third.id);
    await receipt(o.app, 'Dawood', 3000);
    o.app.owner = 'account-3';
    await expectLater(o.app.resetAll(), throwsStateError);
    await o.app.reload();
    expect(o.app.book.money('cash'), 3000);
    await o.switchTo(first);
    await o.app.resetAll();
    expect(o.app.ofKind('party'), isEmpty);
    await o.switchTo(third.id);
    expect(o.app.book.money('cash'), 3000);
  });

  test('Cached copies of shared files are deleted per organization', () async {
    // What Android's cache holds: a folder per organization, plus copies
    // written by versions from before organizations existed.
    final cache = Directory(p.join(dir.path, 'cache'));
    File at(String path) => File(p.join(cache.path, path));
    final files = [
      'exports/main/ZubairKhata_Backup.json',
      'exports/1a2b3c4d/ZubairKhata_Ali_Gas_Backup.json',
      'exports/1a2b3c4d/ZubairKhata.pdf',
      'exports/9f8e7d6c/ZubairKhata_Stock.xlsx',
      'exports/old-backup.json',
      'older-report.csv',
      'not-ours.txt',
    ];
    for (final f in files) {
      at(f)
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    List<String> left() => files.where((f) => at(f).existsSync()).toList();
    expect(
      p.equals(
        exportCopiesFolder(cache, '1a2b3c4d').path,
        at('exports/1a2b3c4d').path,
      ),
      true,
    );

    await deleteExportCopies(cache, '1a2b3c4d');
    expect(left(), [
      'exports/main/ZubairKhata_Backup.json',
      'exports/9f8e7d6c/ZubairKhata_Stock.xlsx',
      'exports/old-backup.json',
      'older-report.csv',
      'not-ours.txt',
    ]);
    // Nothing there: nothing happens.
    await deleteExportCopies(cache, '1a2b3c4d');
    await deleteExportCopies(cache, '00000000');
    expect(left().length, 5);

    // The first organization also owns the copies from before organizations.
    await deleteExportCopies(cache, Organization.main);
    expect(left(), ['exports/9f8e7d6c/ZubairKhata_Stock.xlsx', 'not-ours.txt']);
  });

  test('Renaming the business renames the organization in the list', () async {
    final o = await open();
    await o.create('Ali Gas');
    await o.app.commit([
      Change('business', 'settings', {
        ...o.app.settings,
        'name': 'Ali LPG',
      }, o.app.record('business')!.version),
    ]);
    expect(o.current.name, 'Ali LPG');
    final saved = (registry()['organizations'] as List).cast<Map>();
    expect(saved.map((x) => x['name']), [
      AppController.defaultBusinessName,
      'Ali LPG',
    ]);
  });

  test('A lost or damaged list is rebuilt from the database files', () async {
    var o = await open();
    final added = await o.create('Ali Gas');
    await receipt(o.app, 'Bilal', 7000);
    await close();
    inDir(KhataDatabase.mainFile).copySync(
      inDir('khata-v1.backup-2026-11-10-before-fix.sqlite').path,
    );
    inDir('khata-org-notanid.sqlite').writeAsStringSync('');

    for (final damage in [
      () => inDir(Organizations.registryFile).deleteSync(),
      () => inDir(Organizations.registryFile).writeAsStringSync('{not json'),
      () => inDir(Organizations.registryFile).writeAsStringSync('[]'),
    ]) {
      damage();
      o = await open();
      expect(o.list.map((x) => (x.id, x.name)), [
        (Organization.main, AppController.defaultBusinessName),
        (added.id, 'Ali Gas'),
      ]);
      await o.switchTo(added.id);
      expect(o.app.book.money('cash'), 7000);
      await close();
    }

    // A listed organization whose file is gone is dropped, not recreated.
    inDir(added.file).deleteSync();
    o = await open();
    expect(o.list.single.id, Organization.main);
    expect(inDir(added.file).existsSync(), false);
  });

  test('Removing deletes only that organization and the last one stays', () async {
    final o = await open();
    await receipt(o.app, 'Ali', 10000);
    final added = await o.create('Ali Gas');
    await receipt(o.app, 'Bilal', 7000);

    await o.removeCurrent();

    expect(o.list.single.id, Organization.main);
    expect(o.current.id, Organization.main);
    expect(o.app.book.money('cash'), 10000);
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      expect(inDir('${added.file}$suffix').existsSync(), false);
    }
    expect((registry()['organizations'] as List).length, 1);
    await expectLater(o.removeCurrent(), throwsStateError);
    expect(inDir(KhataDatabase.mainFile).existsSync(), true);
    expect(o.app.book.money('cash'), 10000);

    // The first organization can go too, once there is another.
    final second = await o.create('Second');
    await o.switchTo(Organization.main);
    await o.removeCurrent();
    expect(o.list.single.id, second.id);
    expect(inDir(KhataDatabase.mainFile).existsSync(), false);
    await close();
    final again = await open();
    expect(again.list.single.name, 'Second');
  });

  test('One account cannot be linked to two organizations', () async {
    final o = await open();
    // As after signing in: the account is stored and copied to the list.
    await o.app.db.setMeta('owner', 'uid-1');
    o.app.owner = 'uid-1';
    await o.app.reload();
    expect(o.current.owner, 'uid-1');
    expect(o.ownerUsedElsewhere('uid-1', o.current), false);

    final added = await o.create('Ali Gas');
    expect(o.app.owner, null);
    expect(o.ownerUsedElsewhere('uid-1', added), true);
    expect(o.ownerUsedElsewhere('uid-2', added), false);

    // Each keeps its own sign-in; the first keeps the key it always had.
    const host = 'abc.supabase.co';
    expect(const SecureAuthStorage(host).key, 'khata.session.$host');
    expect(
      const SecureAuthStorage(host, Organization.main).key,
      'khata.session.$host',
    );
    expect(
      SecureAuthStorage(host, added.id).key,
      'khata.session.$host.${added.id}',
    );
  });

  test('The language and the cloud project are shared with a new one', () async {
    final o = await open();
    await o.app.setLanguage('ur');
    // Not https, so the connection is refused before any network is used.
    await o.app.db.setMeta('supabase_url', 'http://project.example');
    await o.app.db.setMeta('supabase_key', 'publishable');

    await o.create('Ali Gas');
    expect(o.app.language, 'ur');
    expect(await o.app.db.meta('language'), 'ur');
    expect(await o.app.db.meta('supabase_url'), 'http://project.example');
    expect(await o.app.db.meta('supabase_key'), 'publishable');
    expect(o.app.cloudConfigured, false);

    await o.app.setLanguage('en');
    await o.switchTo(Organization.main);
    expect(o.app.language, 'en');
    expect(jsonDecode(inDir(Organizations.registryFile).readAsStringSync())
        ['language'], 'en');
  });

  test('A backup says which business it belongs to', () async {
    final o = await open();
    await o.create('Ali Gas');
    final backup = await o.app.backup();
    expect(AppController.backupBusinessName(backup), 'Ali Gas');
    await o.switchTo(Organization.main);
    expect(
      AppController.backupBusinessName(await o.app.backup()),
      AppController.defaultBusinessName,
    );
    expect(AppController.backupBusinessName({'data': 'broken'}), null);
  });
}
