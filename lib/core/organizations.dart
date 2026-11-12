import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/secure_auth.dart';
import 'controller.dart';
import 'models.dart';

/// One separate khata on this device: its own database file, and online its
/// own account. [name], [owner] and [email] are copies of what its database
/// and sign-in say, kept so the list can be shown without opening every file.
class Organization {
  /// The id of the first organization, whose database is the file that
  /// existed before organizations did.
  static const main = 'main';

  final String id;
  String name;

  /// The cloud account this organization is linked to, if any.
  String? owner;
  String? email;
  Organization(this.id, this.name, {this.owner, this.email});

  String get file =>
      id == main ? KhataDatabase.mainFile : 'khata-org-$id.sqlite';

  static final _added = RegExp(r'^khata-org-([0-9a-f]{8})\.sqlite$');

  /// The organization a database file belongs to, or null for any other file.
  /// Deliberately strict: manual copies such as `khata-v1.backup-….sqlite` sit
  /// in the same folder and are not organizations.
  static String? idOfFile(String name) =>
      name == KhataDatabase.mainFile ? main : _added.firstMatch(name)?.group(1);

  Json toJson() => {'id': id, 'name': name, 'owner': owner, 'email': email};
}

typedef DatabaseOpener = Future<KhataDatabase> Function(File file);

/// The organizations on this device and the one that is open.
///
/// Each organization is its own SQLite file with its own [AppController], so
/// nothing is shared between two khatas. Switching closes one and opens the
/// other. The list is saved in `organizations.json` beside the databases; it
/// holds device settings only (the list, the last one used and the language)
/// and is rebuilt from the database files if it is lost.
class Organizations extends ChangeNotifier {
  static const registryFile = 'organizations.json';

  final Directory directory;
  final DatabaseOpener _opener;
  final list = <Organization>[];
  late Organization current;

  /// The interface language, shared by every organization on the device.
  String? language;

  /// True while one organization is being closed and another opened.
  bool switching = false;

  /// Why no organization could be opened, when that happens.
  String? failure;
  AppController? _app;

  Organizations._(this.directory, this._opener);

  /// The controller of the open organization.
  AppController get app => _app!;
  bool get ready => _app != null;

  /// Opens the organization used last. [directory] and [opener] are for tests.
  static Future<Organizations> open({
    Directory? directory,
    DatabaseOpener? opener,
  }) async {
    final orgs = Organizations._(
      directory ?? await KhataDatabase.directory(),
      opener ?? (file) => KhataDatabase.open(p.basename(file.path), file.parent),
    );
    await orgs._load();
    await orgs._openCurrent();
    return orgs;
  }

  File _fileOf(Organization org, [String suffix = '']) =>
      File(p.join(directory.path, '${org.file}$suffix'));

  /// Reads the saved list and reconciles it with the database files that are
  /// really there: a file that is gone is dropped, a file that is not listed
  /// is added with the name its own business profile gives.
  Future<void> _load() async {
    var saved = <String, dynamic>{};
    final registry = File(p.join(directory.path, registryFile));
    try {
      if (registry.existsSync()) {
        saved = decodeObject(registry.readAsStringSync());
      }
    } catch (_) {
      // An unreadable list is rebuilt from the files below.
    }
    final known = <String, Map>{};
    if (saved['organizations'] is List) {
      for (final item in saved['organizations'] as List) {
        if (item is Map) known['${item['id']}'] = item;
      }
    }
    if (saved['language'] is String) language = saved['language'] as String;
    final found = <String>{};
    for (final file in directory.listSync().whereType<File>()) {
      final id = Organization.idOfFile(p.basename(file.path));
      if (id != null) found.add(id);
    }
    final unlisted = found.where((id) => !known.containsKey(id)).toList()
      ..sort(
        (a, b) => a == Organization.main
            ? -1
            : b == Organization.main
            ? 1
            : a.compareTo(b),
      );
    for (final id in [...known.keys.where(found.contains), ...unlisted]) {
      final item = known[id];
      final name = '${item?['name'] ?? ''}'.trim();
      list.add(
        item == null || name.isEmpty
            ? await _describe(id)
            : Organization(
                id,
                name,
                owner: item['owner'] is String ? item['owner'] as String : null,
                email: item['email'] is String ? item['email'] as String : null,
              ),
      );
    }
    if (list.isEmpty) {
      // A new installation starts with one organization.
      list.add(Organization(Organization.main, AppController.defaultBusinessName));
    }
    current = list.firstWhere(
      (o) => o.id == saved['current'],
      orElse: () => list.first,
    );
  }

  /// Reads an unlisted organization's name and account from its database.
  Future<Organization> _describe(String id) async {
    final org = Organization(id, AppController.defaultBusinessName);
    try {
      final db = await _opener(_fileOf(org));
      try {
        for (final r in await db.effective()) {
          if (r.id == 'business' && r.name.trim().isNotEmpty) {
            org.name = r.name;
          }
        }
        org.owner = await db.meta('owner');
      } finally {
        await db.close();
      }
    } catch (_) {
      // Still listed; opening it reports what is wrong with the file.
      org.name = org.file;
    }
    return org;
  }

  Future<void> _openCurrent({Map<String, String> meta = const {}}) async {
    final db = await _opener(_fileOf(current));
    final app = AppController(db, organizations: this, organization: current);
    try {
      for (final entry in meta.entries) {
        await db.setMeta(entry.key, entry.value);
      }
      await app.initialize();
    } catch (_) {
      await app.close();
      rethrow;
    }
    _app = app;
    _save();
  }

  void _save() {
    try {
      final file = File(p.join(directory.path, registryFile));
      final temp = File('${file.path}.tmp');
      temp.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'current': current.id,
          'language': language,
          'organizations': [for (final o in list) o.toJson()],
        }),
        flush: true,
      );
      temp.renameSync(file.path);
    } catch (_) {
      // The list is rebuilt from the database files when it cannot be read,
      // so failing to save it must not stop the khata from working.
    }
  }

  /// Closes the open organization and opens [target]. If [target] cannot be
  /// opened, the previous one is opened again and the error is rethrown.
  Future<void> _replace(
    Organization target, {
    Map<String, String> meta = const {},
  }) async {
    if (switching) throw StateError('Wait for the organization to open');
    final previous = current, old = _app;
    switching = true;
    failure = null;
    notifyListeners();
    try {
      _app = null;
      try {
        await old?.close();
      } catch (_) {
        // A database that will not close cleanly must not block the next one.
      }
      current = target;
      try {
        await _openCurrent(meta: meta);
      } catch (_) {
        current = previous;
        await _openCurrent();
        _app!.lastError = 'Could not open the organization';
        rethrow;
      }
    } catch (e) {
      if (_app == null) failure = '$e';
      rethrow;
    } finally {
      switching = false;
      notifyListeners();
    }
  }

  Future<void> switchTo(String id) async {
    if (id == current.id) return;
    final target = list.where((o) => o.id == id).firstOrNull;
    if (target == null) throw StateError('Organization not found');
    await _replace(target);
  }

  /// Adds an empty organization called [name] and opens it. It takes over the
  /// cloud project of the open organization, so it only has to sign in, with
  /// an email of its own.
  Future<Organization> create(String name) async {
    name = name.trim();
    if (name.isEmpty) throw const FormatException('Enter a name');
    final key = AppController.nameKey(name);
    if (list.any((o) => AppController.nameKey(o.name) == key)) {
      throw const FormatException('This name already exists');
    }
    Organization org;
    do {
      org = Organization(uuid.v4().substring(0, 8), name);
    } while (list.any((o) => o.id == org.id) || _fileOf(org).existsSync());
    final meta = <String, String>{};
    if (_app != null) {
      for (final key in ['supabase_url', 'supabase_key']) {
        final value = await app.db.meta(key);
        if (value != null) meta[key] = value;
      }
    }
    list.add(org);
    try {
      await _replace(org, meta: meta);
    } catch (_) {
      list.remove(org);
      _delete(org);
      _save();
      rethrow;
    }
    return org;
  }

  /// Removes the open organization from this device and opens another one.
  /// Only this device's copy is deleted; a cloud copy stays under its email.
  Future<void> removeCurrent() async {
    if (list.length < 2) {
      throw StateError('The only organization cannot be removed');
    }
    final gone = current, host = _app?.cloudHost;
    await _replace(list.firstWhere((o) => o.id != gone.id));
    _delete(gone);
    list.remove(gone);
    _save();
    if (host != null) {
      try {
        await SecureAuthStorage.forget(host, gone.id);
      } catch (_) {
        // The stored sign-in is useless without the organization.
      }
    }
    notifyListeners();
  }

  void _delete(Organization org) {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final file = _fileOf(org, suffix);
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Whether another organization on this device is linked to this account.
  /// Two organizations on one account would mix their books in the cloud.
  bool ownerUsedElsewhere(String uid, Organization? org) =>
      list.any((o) => !identical(o, org) && o.owner == uid);

  /// Copies the name and account of [app]'s organization into the list.
  /// Called whenever that organization's data is reloaded.
  void mirror(AppController app) {
    final org = app.organization;
    if (org == null || !list.contains(org)) return;
    final name = app.businessName, owner = app.owner;
    final email = owner == null
        ? null
        : app.client?.auth.currentUser?.email ?? org.email;
    if (org.name == name && org.owner == owner && org.email == email) return;
    org
      ..name = name
      ..owner = owner
      ..email = email;
    _save();
  }

  void setLanguage(String code) {
    if (language == code) return;
    language = code;
    _save();
  }

  /// Closes the open organization (when the app or a test ends).
  Future<void> close() async {
    final app = _app;
    _app = null;
    await app?.close();
  }
}
