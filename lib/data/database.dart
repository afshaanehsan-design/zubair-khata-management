import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

class KhataDatabase extends GeneratedDatabase {
  KhataDatabase(super.executor);

  /// The database of the first organization: the only file there was before
  /// organizations existed. It keeps its name so existing data stays in place.
  static const mainFile = 'khata-v1.sqlite';

  /// The folder that holds every organization's database and the list of them.
  static Future<Directory> directory() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  /// Opens one organization's database ([file] is a name inside [directory]).
  static Future<KhataDatabase> open([
    String file = mainFile,
    Directory? directory,
  ]) async {
    final dir = directory ?? await KhataDatabase.directory();
    final db = KhataDatabase(
      NativeDatabase.createInBackground(File(p.join(dir.path, file))),
    );
    await db.initialize();
    return db;
  }

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  Future<void> initialize() async {
    await customStatement('PRAGMA foreign_keys = ON');
    await customStatement(
      'CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, data TEXT NOT NULL, version INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS record_kind ON records(kind)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS commands (id TEXT PRIMARY KEY, payload TEXT NOT NULL, status TEXT NOT NULL, error TEXT, created INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    // Files from before 12 November 2026 also have a `drafts` table, no
    // longer used (composer drafts are kept in memory, like the Roznamcha
    // form's). It is left in place; [wipe] empties it with every other table.
  }

  Future<String?> meta(String key) async => (await customSelect(
    'SELECT value FROM metadata WHERE key = ?',
    variables: [Variable(key)],
  ).getSingleOrNull())?.read<String>('value');
  Future<void> setMeta(String key, String value) => customStatement(
    'INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  Future<List<Record>> confirmed() async =>
      // rowid order is the order records were first stored (an update keeps
      // its row), which the Parties page shows newest first.
      (await customSelect('SELECT * FROM records ORDER BY rowid').get())
          .map(
            (r) => Record(
              r.read<String>('id'),
              r.read<String>('kind'),
              decodeObject(r.read<String>('data')),
              version: r.read<int>('version'),
            ),
          )
          .toList();
  Future<List<Command>> commands() async =>
      (await customSelect('SELECT * FROM commands ORDER BY rowid').get())
          .map(
            (r) => Command.fromJson({
              ...decodeObject(r.read<String>('payload')),
              'status': r.read<String>('status'),
              'error': r.readNullable<String>('error'),
              'created': r.read<int>('created'),
            }),
          )
          .toList();
  Future<void> queue(Command c) => transaction(() async {
    await customStatement(
      'INSERT INTO commands(id,payload,status,error,created) VALUES(?,?,?,?,?)',
      [c.id, jsonEncode(c.payload), c.status, c.error, c.created],
    );
  });
  Future<void> commandState(String id, String state, [String? error]) =>
      customStatement('UPDATE commands SET status=?,error=? WHERE id=?', [
        state,
        error,
        id,
      ]);
  Future<List<Record>> effective() => transaction(() async {
    final result = {for (final r in await confirmed()) r.id: r};
    for (final c in await commands()) {
      if (!['queued', 'sending', 'accepted'].contains(c.status)) continue;
      for (final change in c.changes) {
        result[change.id] = Record(
          change.id,
          change.kind,
          change.data,
          version: change.expectedVersion + 1,
          pending: true,
        );
      }
    }
    return result.values.toList();
  });

  Future<void> applyBundles(List<Json> bundles, int cursor) =>
      transaction(() async {
        var previous = integer(await meta('cursor'));
        for (final bundle in bundles) {
          final seq = integer(bundle['sequence']);
          if (seq != previous + 1) throw StateError('Sync sequence gap');
          for (final item in bundle['records'] as List) {
            final r = Record.fromJson(Map<String, dynamic>.from(item as Map));
            await customStatement(
              'INSERT INTO records(id,kind,data,version) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,data=excluded.data,version=excluded.version',
              [r.id, r.kind, jsonEncode(r.data), r.version],
            );
          }
          await commandState('${bundle['command_id']}', 'synced');
          previous = seq;
        }
        if (cursor != previous) throw StateError('Invalid sync cursor');
        await setMeta('cursor', '$cursor');
      });

  /// The only metadata a reset keeps: which device this is, its language and
  /// its cloud connection (`owner` binds it to the signed-in account). Every
  /// other key is business data or sync state and is erased.
  static const keptOnWipe = {
    'device',
    'language',
    'supabase_url',
    'supabase_key',
    'owner',
  };

  /// Empties every table, including tables added in later versions, keeping
  /// only the [keptOnWipe] metadata. Used by `AppController.resetAll`.
  Future<void> wipe() => transaction(() async {
    final tables = await customSelect(
      r"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\_%' ESCAPE '\'",
    ).get();
    for (final row in tables) {
      final name = row.read<String>('name');
      if (name == 'metadata') {
        await customStatement(
          'DELETE FROM metadata WHERE key NOT IN (${List.filled(keptOnWipe.length, '?').join(',')})',
          keptOnWipe.toList(),
        );
      } else {
        await customStatement('DELETE FROM "${name.replaceAll('"', '""')}"');
      }
    }
  });
  Future<Json> exportData() => transaction(
    () async => {
      'schema': 1,
      'records': (await confirmed()).map((r) => r.toJson()).toList(),
      'commands': (await commands()).map((c) => c.toJson()).toList(),
      'metadata': {
        for (final r in await customSelect('SELECT * FROM metadata').get())
          r.read<String>('key'): r.read<String>('value'),
      },
    },
  );
  Future<void> restoreLocal(Json backup) => transaction(() async {
    await customStatement('DELETE FROM records');
    await customStatement('DELETE FROM commands');
    for (final item in backup['records'] as List) {
      final r = Record.fromJson(Map<String, dynamic>.from(item as Map));
      await customStatement('INSERT INTO records VALUES(?,?,?,?)', [
        r.id,
        r.kind,
        jsonEncode(r.data),
        r.version,
      ]);
    }
    for (final item in backup['commands'] as List) {
      final c = Command.fromJson(Map<String, dynamic>.from(item as Map));
      await customStatement('INSERT INTO commands VALUES(?,?,?,?,?)', [
        c.id,
        jsonEncode(c.payload),
        c.status == 'sending' ? 'queued' : c.status,
        c.error,
        c.created,
      ]);
    }
    await customStatement('DELETE FROM metadata');
    for (final entry in (backup['metadata'] as Map).entries) {
      await setMeta('${entry.key}', '${entry.value}');
    }
  });
}
