import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/core/organizations.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/data/sync.dart';

class Server implements SyncTransport {
  String epoch = 'test-epoch';
  final records = <String, Record>{};
  final feed = <Json>[];
  final receipts = <String, Json>{};
  bool loseResponse = false;
  int accepted = 0;
  @override
  Future<Json> status() async => {
    'epoch': epoch,
    'protocol': 1,
    'sequence': feed.length,
  };
  @override
  Future<List<Json>> pull(String epoch, int after) async =>
      feed.where((j) => integer(j['sequence']) > after).toList();
  @override
  Future<Json> apply(Command c) async {
    if (receipts.containsKey(c.id)) return receipts[c.id]!;
    if (c.changes.any(
      (change) => (records[change.id]?.version ?? 0) != change.expectedVersion,
    )) {
      return receipts[c.id] = {
        'status': 'conflict',
        'message': 'Version conflict',
      };
    }
    final changed = <Json>[];
    for (final change in c.changes) {
      final record = Record(
        change.id,
        change.kind,
        change.data,
        version: change.expectedVersion + 1,
      );
      records[record.id] = record;
      changed.add(record.toJson());
    }
    accepted++;
    feed.add({
      'sequence': feed.length + 1,
      'command_id': c.id,
      'records': changed,
    });
    final result = receipts[c.id] = {
      'status': 'accepted',
      'sequence': feed.length,
    };
    if (loseResponse) {
      loseResponse = false;
      throw StateError('Response lost after commit');
    }
    return result;
  }

  int resets = 0;
  @override
  Future<Json> reset(String epoch) async {
    if (epoch != this.epoch) throw StateError('Dataset epoch mismatch');
    records.clear();
    feed.clear();
    receipts.clear();
    this.epoch = 'reset-${++resets}';
    return {'epoch': this.epoch, 'sequence': 0, 'protocol': 1};
  }
}

/// Like the real `sync_status`: a new account starts with the cash account
/// and the default business profile, delivered as the first change.
class NewAccount extends Server {
  @override
  Future<Json> status() async {
    if (feed.isEmpty) {
      final defaults = [
        const Record('cash', 'account', {
          'name': 'Cash',
          'bank': '',
          'category': 'Cash',
          'archived': false,
        }, version: 1),
        const Record('business', 'settings', {
          'name': AppController.defaultBusinessName,
          'phone': '',
          'address': '',
          'defaultRate': 0,
        }, version: 1),
      ];
      for (final r in defaults) {
        records[r.id] = r;
      }
      feed.add({
        'sequence': 1,
        'command_id': 'bootstrap',
        'records': defaults.map((r) => r.toJson()).toList(),
      });
    }
    return super.status();
  }
}

void main() {
  test('Each organization syncs with its own account only', () async {
    final dir = Directory.systemTemp.createTempSync('khata-sync-orgs-');
    final orgs = await Organizations.open(
      directory: dir,
      opener: (file) async {
        final db = KhataDatabase(NativeDatabase(file));
        await db.initialize();
        return db;
      },
    );
    addTearDown(() async {
      await orgs.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    // Signed in: the controller syncs through an account's fake server.
    void signIn(String uid, Server server) {
      final app = orgs.app;
      app.owner = uid;
      app.sync = SyncService(app.db, server, () {});
    }

    // Saving starts a sync by itself; wait for it, then sync what is left.
    Future<void> synced() async {
      await orgs.app.sync!.idle;
      await orgs.app.syncNow();
    }

    final first = NewAccount(), second = NewAccount();
    signIn('owner-1', first);
    await orgs.app.saveMaster('party', {'name': 'First customer'});
    await synced();
    expect(orgs.app.pendingCount, 0);

    final added = await orgs.create('Ali Gas');
    signIn('owner-2', second);
    await orgs.app.saveMaster('party', {'name': 'Second customer'});
    await synced();
    expect(orgs.app.pendingCount, 0);
    expect(orgs.app.conflictCount, 0);

    Iterable<String> parties(Server s) =>
        s.records.values.where((r) => r.kind == 'party').map((r) => r.name);
    expect(parties(first), ['First customer']);
    expect(parties(second), ['Second customer']);
    // The new organization's name reached its account as an ordinary change.
    expect(first.records['business']!.name, AppController.defaultBusinessName);
    expect(second.records['business']!.name, 'Ali Gas');
    expect(second.records['business']!.version, 2);

    // Reset erases that account's cloud copy only, and the name comes back.
    await orgs.app.resetAll();
    await synced();
    expect(second.epoch, 'reset-1');
    expect(parties(second), isEmpty);
    expect(second.records['business']!.name, 'Ali Gas');
    expect(orgs.app.businessName, 'Ali Gas');
    expect(orgs.app.pendingCount, 0);
    expect(orgs.app.conflictCount, 0);
    expect(orgs.current.id, added.id);
    expect(first.epoch, 'test-epoch');
    expect(parties(first), ['First customer']);

    await orgs.switchTo(Organization.main);
    expect(orgs.app.ofKind('party').single.name, 'First customer');
  });

  final databases = <KhataDatabase>[],
      controllers = <AppController>[],
      services = <SyncService>[];
  Future<(AppController, SyncService)> device(Server server) async {
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    final service = SyncService(db, server, () {});
    databases.add(db);
    controllers.add(app);
    services.add(service);
    return (app, service);
  }

  tearDown(() async {
    for (final s in services) {
      s.dispose();
    }
    for (final a in controllers) {
      a.dispose();
    }
    for (final d in databases) {
      await d.close();
    }
    services.clear();
    controllers.clear();
    databases.clear();
  });
  test(
    'Two devices append offline entries without replacing the dataset',
    () async {
      final server = Server(), a = await device(Server());
      // Both services share the real fake transport below.
      a.$2.dispose();
      services.remove(a.$2);
      final sa = SyncService(a.$1.db, server, () {});
      services.add(sa);
      final b = await device(server);
      await a.$1.saveMaster('party', {'name': 'First'});
      await b.$1.saveMaster('party', {'name': 'Second'});
      await sa.synchronize();
      await b.$2.synchronize();
      await sa.synchronize();
      await a.$1.reload();
      await b.$1.reload();
      expect(a.$1.ofKind('party').length, 2);
      expect(b.$1.ofKind('party').length, 2);
      expect(server.accepted, 2);
    },
  );
  test(
    'Lost response retries a frozen payload and applies the document once',
    () async {
      final server = Server(), a = await device(Server());
      a.$2.dispose();
      services.remove(a.$2);
      final sync = SyncService(a.$1.db, server, () {});
      services.add(sync);
      await a.$1.saveMaster('party', {'name': 'Retry'});
      server.loseResponse = true;
      await sync.synchronize();
      expect(server.accepted, 1);
      final frozen = jsonEncode((await a.$1.db.commands()).single.payload);
      await sync.synchronize();
      await a.$1.reload();
      expect(server.accepted, 1);
      expect(a.$1.pendingCount, 0);
      expect(jsonEncode(a.$1.commands.single.payload), frozen);
    },
  );
  test('Stale edit becomes visible conflict while another independent edit proceeds', () async {
    final server = Server(), a = await device(Server());
    a.$2.dispose();
    services.remove(a.$2);
    final sa = SyncService(a.$1.db, server, () {});
    services.add(sa);
    final b = await device(server);
    await a.$1.saveMaster('party', {'name': 'Original'});
    await sa.synchronize();
    await b.$2.synchronize();
    await a.$1.reload();
    await b.$1.reload();
    final pa = a.$1.ofKind('party').single, pb = b.$1.ofKind('party').single;
    await a.$1.saveMaster('party', {'name': 'A edit'}, existing: pa);
    await b.$1.saveMaster('party', {'name': 'B edit'}, existing: pb);
    await b.$1.saveMaster('party', {'name': 'Independent'});
    await sa.synchronize();
    await b.$2.synchronize();
    await b.$1.reload();
    expect(b.$1.conflictCount, 1);
    expect(b.$1.name(pa.id), 'A edit');
    expect(b.$1.ofKind('party').length, 2);
  });
  test('Epoch changes preserve pending work and stop old writes', () async {
    final server = Server(), a = await device(Server());
    a.$2.dispose();
    services.remove(a.$2);
    final sync = SyncService(a.$1.db, server, () {});
    services.add(sync);
    await sync.synchronize();
    server.epoch = 'restored-cloud';
    await a.$1.saveMaster('party', {'name': 'Keep me'});
    await sync.synchronize();
    expect(sync.message, contains('Cloud recovery'));
    expect((await a.$1.db.commands()).single.status, 'queued');
    expect(server.accepted, 0);
  });
  test('Reset erases the cloud copy too and other devices must reconnect', () async {
    final server = Server();
    final a = await device(server), b = await device(server);
    await a.$1.saveMaster('party', {'name': 'Old customer'}, opening: 50000);
    await a.$2.synchronize();
    await b.$2.synchronize();
    await b.$1.saveMaster('party', {'name': 'Pending on B'});
    await b.$1.reload();
    expect(b.$1.ofKind('party').length, 2);
    expect(server.accepted, 1);

    // Signed in on A: its controller syncs through the shared fake server.
    a.$1.owner = 'owner';
    a.$1.sync = a.$2;
    await a.$1.resetAll();

    expect(server.records, isEmpty);
    expect(server.feed, isEmpty);
    expect(server.epoch, 'reset-1');
    expect(a.$1.ofKind('party'), isEmpty);
    expect(a.$1.commands, isEmpty);
    expect(await a.$1.db.meta('epoch'), 'reset-1');
    expect(a.$1.sync!.message, 'Up to date');

    // The old dataset cannot come back from another device.
    await b.$2.synchronize();
    expect(b.$2.message, contains('Cloud recovery'));
    expect(server.records, isEmpty);

    // A new start on A syncs (commit starts the sync); B reconnects onto it.
    await a.$1.saveMaster('party', {'name': 'Fresh start'});
    while (a.$1.sync!.running) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await a.$1.syncNow();
    expect(server.accepted, 2);
    expect(a.$1.pendingCount, 0);
    b.$1.owner = 'owner';
    b.$1.sync = b.$2;
    await b.$1.recoverCloud();
    expect(b.$1.ofKind('party').map((p) => p.name), ['Fresh start']);
    expect(b.$1.book.receivables, 0);
  });
}
