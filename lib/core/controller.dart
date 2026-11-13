import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/sync.dart';
import '../data/secure_auth.dart';
import '../features/ledger/book.dart';
import 'models.dart';
import 'organizations.dart';

const uuid = Uuid();

class AppController extends ChangeNotifier {
  final KhataDatabase db;

  /// The organizations on this device and the one this controller serves.
  /// Both are null when a controller is used on its own, as most tests do.
  final Organizations? organizations;
  final Organization? organization;

  /// The business name a new khata starts with (the server seeds the same).
  static const defaultBusinessName = 'Zubair Traders';
  List<Record> records = [];
  List<Command> commands = [];
  String language = 'en';
  String selectedDate = businessDate();
  String search = '';

  /// The page the workspace shows: one of the ids in `destinations`
  /// (`lib/ui/app.dart`). Not business data, so a reset leaves it alone.
  String page = 'roznamcha';

  /// Unsaved Roznamcha form values, kept while moving between pages.
  final rozDrafts = <String, Json>{};

  /// Unsaved values of a new entry in the general composer, by kind of
  /// entry. Like [rozDrafts] they last until the app or organization closes.
  final composerDrafts = <String, Json>{};

  /// Whether the database keeps the copy made just before the last backup
  /// restore or cloud reconnect (metadata `pre_restore`), see
  /// [preRestoreCopy].
  bool preRestoreSaved = false;

  /// Aamad table grouping ("Customer wise") like the original page.
  bool rozCustomerWise = false;
  String device = '';
  String? owner;
  String? lastError;

  /// Why the last sign-in was refused, so [signIn] can report it at once.
  String? _refusal;
  bool _disposed = false;
  Book? _book;
  final _datedBooks = <String, Book>{};
  final batchStarts = <String, int>{};
  SupabaseClient? client;

  /// The host of the cloud project this organization is connected to.
  String? cloudHost;
  SyncService? sync;
  Timer? _poll;
  StreamSubscription<AuthState>? _auth;
  AppController(this.db, {this.organizations, this.organization});

  // Work that was under way when the organization was closed may still finish.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get urdu => language == 'ur';
  bool get cloudConfigured => client != null;
  bool get signedIn => client?.auth.currentUser != null;

  /// Whether this khata belongs to a cloud account. Only then are queued
  /// changes waiting for anything: on a device that has never signed in,
  /// every entry stays in the queue for good, so it has no "pending" count.
  bool get cloudLinked => owner != null || signedIn;
  String get syncMessage =>
      sync?.message ?? (cloudConfigured ? 'Sign in to sync' : 'Local device');
  List<Record> ofKind(String kind, {bool archived = false}) => records
      .where((r) => r.kind == kind && !r.deleted && (archived || !r.archived))
      .toList();
  Record? record(String id) {
    for (final r in records) {
      if (r.id == id) return r;
    }
    return null;
  }

  String name(String id) => record(id)?.name ?? id;

  static String nameKey(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// A party with this name (case and spacing ignored), archived ones
  /// included. Deleted parties are gone, so their name is free again.
  Record? partyByName(String name) {
    final key = nameKey(name);
    if (key.isEmpty) return null;
    for (final r in records) {
      if (r.kind == 'party' && !r.deleted && nameKey(r.name) == key) return r;
    }
    return null;
  }

  /// Whether any live (not voided) entry belongs to this party, or names it
  /// as the party a customer paid directly.
  bool partyHasEntries(String id) =>
      records.any((r) => _entryOf(r, id) && r.data['voided'] != true);

  static bool _entryOf(Record r, String party) =>
      r.kind == 'document' &&
      (r.data['party'] == party || Document(r).directParties.contains(party));

  /// Removes a party that has no entries. Voided entries do not count: they
  /// no longer affect any balance.
  Future<void> deleteParty(Record party) async {
    if (party.kind != 'party') throw const FormatException('Choose a party');
    if (partyHasEntries(party.id)) {
      throw const FormatException(
        'This party has entries and cannot be deleted',
      );
    }
    await commit([
      Change(party.id, 'party', {
        ...party.data,
        'deleted': true,
      }, party.version),
    ]);
  }

  Book get book => _book ??= Book(records);
  Book bookAt(String date) {
    // Through the last day that has entries (usually today) it is [book].
    final all = book.documents;
    if (all.isEmpty || all.last.date.compareTo(date) <= 0) return book;
    if (_datedBooks.length > 40) _datedBooks.clear();
    return _datedBooks.putIfAbsent(
      date,
      () => Book(records, throughDate: date),
    );
  }

  Json get settings => record('business')?.data ?? {};
  String get businessName => '${settings['name'] ?? defaultBusinessName}';
  int get pendingCount => commands
      .where((c) => ['queued', 'sending', 'accepted'].contains(c.status))
      .length;
  int get conflictCount => commands
      .where((c) => ['conflict', 'rejected', 'quarantined'].contains(c.status))
      .length;

  Future<void> initialize() async {
    device = await db.meta('device') ?? uuid.v4().substring(0, 8);
    await db.setMeta('device', device);
    owner = await db.meta('owner');
    // The language belongs to the device, not to one organization.
    final shared = organizations?.language;
    language = shared ?? await db.meta('language') ?? 'en';
    if (shared != null) await db.setMeta('language', language);
    organizations?.setLanguage(language);
    if (await db.meta('initialized') == null) await _seedDefaults();
    await reload();
    const envUrl = String.fromEnvironment('SUPABASE_URL');
    const envKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    final url = envUrl.isEmpty ? await db.meta('supabase_url') ?? '' : envUrl;
    final key = envKey.isEmpty ? await db.meta('supabase_key') ?? '' : envKey;
    if (url.isNotEmpty && key.isNotEmpty) {
      try {
        await configureCloud(url, key);
      } catch (e) {
        lastError = '$e';
      }
    }
    notifyListeners();
  }

  static const _defaultProfile = <String, dynamic>{
    'name': defaultBusinessName,
    'phone': '',
    'address': '',
    'defaultRate': 0,
  };

  /// The cash account and business profile every new khata starts with: the
  /// same two records the server creates for a new account.
  ///
  /// An organization with a name of its own also gets that name, as an
  /// ordinary queued change to the profile. Offline it simply applies; once
  /// the organization is linked it is sent like any other change, so the
  /// name also survives the server's defaults.
  Future<void> _seedDefaults() => db.transaction(() async {
    for (final r in [
      const Record('cash', 'account', {
        'name': 'Cash',
        'bank': '',
        'category': 'Cash',
        'archived': false,
      }, version: 1),
      const Record('business', 'settings', _defaultProfile, version: 1),
    ]) {
      await db.customStatement(
        'INSERT OR IGNORE INTO records VALUES(?,?,?,?)',
        [r.id, r.kind, jsonEncode(r.data), r.version],
      );
    }
    await db.setMeta('initialized', '1');
    final name = organization?.name.trim() ?? '';
    if (name.isNotEmpty && name != defaultBusinessName) {
      await _enqueue([
        Change('business', 'settings', {..._defaultProfile, 'name': name}, 1),
      ]);
    }
  });

  /// Appends a command to the queue. Only [commit] and [_seedDefaults] use
  /// it: everything else must go through [commit], which validates first.
  Future<void> _enqueue(
    List<Change> changes, {
    String action = 'save',
    String reason = '',
  }) async => db.queue(
    Command(
      id: uuid.v4(),
      device: device,
      epoch: await db.meta('epoch') ?? '',
      action: action,
      reason: reason,
      changes: changes,
      created: DateTime.now().microsecondsSinceEpoch,
    ),
  );

  Future<void> reload() async {
    if (_disposed) return;
    records = await db.effective();
    if (_disposed) return;
    commands = await db.commands();
    if (_disposed) return;
    // Before 12 November 2026 a "Khata Saaf" was kept in this device's
    // metadata (`batch:<date>`), which never synced; it is now stored on the
    // snapshot it saves. Both are read, and the latest one wins.
    final batches = await db
        .customSelect("SELECT key,value FROM metadata WHERE key LIKE 'batch:%'")
        .get();
    if (_disposed) return;
    final saved = await db
        .customSelect("SELECT 1 FROM metadata WHERE key='pre_restore'")
        .get();
    if (_disposed) return;
    preRestoreSaved = saved.isNotEmpty;
    batchStarts.clear();
    void batch(String date, int at) {
      if (at > (batchStarts[date] ?? 0)) batchStarts[date] = at;
    }

    for (final r in batches) {
      batch(
        r.read<String>('key').substring(6),
        integer(r.read<String>('value')),
      );
    }
    for (final s in records.where((r) => r.kind == 'snapshot')) {
      if (s.data['batchAt'] != null) {
        batch('${s.data['date']}', integer(s.data['batchAt']));
      }
    }
    _book = null;
    _datedBooks.clear();
    _quoteKey = null;
    organizations?.mirror(this);
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    language = code;
    await db.setMeta('language', code);
    organizations?.setLanguage(code);
    notifyListeners();
  }

  void setDate(String date) {
    selectedDate = date;
    notifyListeners();
  }

  /// Shows another page of the workspace ([page] is a `destinations` id).
  void go(String id) {
    if (id == page) return;
    page = id;
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  Future<void> configureCloud(String url, String key) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        parsed.scheme != 'https' ||
        parsed.host.isEmpty ||
        key.trim().isEmpty) {
      throw const FormatException(
        'Enter the Supabase project URL and publishable key',
      );
    }
    if (client != null) {
      throw StateError('Restart the app to change the cloud project');
    }
    await Supabase.initialize(
      url: url.trim(),
      publishableKey: key.trim(),
      authOptions: FlutterAuthClientOptions(
        // Each organization keeps its own sign-in.
        localStorage: SecureAuthStorage(
          parsed.host,
          organization?.id ?? Organization.main,
        ),
      ),
    );
    client = Supabase.instance.client;
    cloudHost = parsed.host;
    await db.setMeta('supabase_url', url.trim());
    await db.setMeta('supabase_key', key.trim());
    _auth = client!.auth.onAuthStateChange.listen((state) {
      unawaited(_onAuth());
    });
    await _onAuth();
    notifyListeners();
  }

  Future<void> _onAuth() async {
    final uid = client?.auth.currentUser?.id;
    if (uid == null) {
      sync?.dispose();
      sync = null;
      _poll?.cancel();
      notifyListeners();
      return;
    }
    if (owner != null && owner != uid) {
      lastError = _refusal = 'This organization belongs to another account. Sign in with the original email.';
      await client!.auth.signOut(scope: SignOutScope.local);
      notifyListeners();
      return;
    }
    // One account holds one organization's books. Two organizations signed in
    // with the same email would be merged in the cloud.
    if (organizations?.ownerUsedElsewhere(uid, organization) == true) {
      lastError = _refusal = 'This email is already used by another organization on this device. Use a separate email for each organization.';
      await client!.auth.signOut(scope: SignOutScope.local);
      notifyListeners();
      return;
    }
    owner = uid;
    await db.setMeta('owner', uid);
    organizations?.mirror(this);
    sync ??= SyncService(db, SupabaseTransport(client!), () {
      unawaited(reload());
    });
    _poll ??= Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(syncNow());
    });
    unawaited(syncNow());
  }

  Future<void> signIn(String email, String password) async {
    if (client == null) throw StateError('Configure cloud first');
    _refusal = null;
    await client!.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    await _onAuth();
    if (_refusal != null) throw StateError(_refusal!);
    lastError = null;
  }

  Future<void> register(String email, String password) async {
    if (client == null) throw StateError('Configure cloud first');
    await client!.auth.signUp(email: email.trim(), password: password);
  }

  Future<void> signOut() async {
    await syncNow();
    await client?.auth.signOut(scope: SignOutScope.local);
  }

  Future<void> syncNow() async {
    if (sync == null) return;
    await sync?.synchronize();
    await reload();
  }

  Future<void> commit(
    List<Change> changes, {
    String action = 'save',
    String reason = '',
  }) async {
    if (changes.isEmpty) return;
    if (['correct', 'void', 'restore', 'close', 'reopen'].contains(action) &&
        reason.trim().isEmpty) {
      throw const FormatException('A reason is required');
    }
    final next = {for (final r in records) r.id: r};
    for (final c in changes) {
      final old = next[c.id];
      if (['party', 'account', 'settings'].contains(c.kind) &&
          '${c.data['name'] ?? ''}'.trim().isEmpty) {
        throw const FormatException('Enter a name');
      }
      if (old == null && c.kind == 'document' && c.data['voided'] == true) {
        throw const FormatException('New document cannot be void');
      }
      if (old != null && old.kind != c.kind) {
        throw const FormatException('Record kind cannot change');
      }
      if (c.id == 'cash' && c.data['archived'] == true) {
        throw const FormatException('Cash account must remain available');
      }
      if (old?.kind == 'document') {
        final previous = {...old!.data}
          ..removeWhere(
            (k, v) => ['voided', 'voidReason', 'replacement'].contains(k),
          );
        final proposed = {...c.data}
          ..removeWhere(
            (k, v) => ['voided', 'voidReason', 'replacement'].contains(k),
          );
        if (!['correct', 'void', 'restore'].contains(action) ||
            old.data['voided'] == true ||
            c.data['voided'] != true ||
            canonicalJson(previous) != canonicalJson(proposed)) {
          throw const FormatException(
            'Posted documents require an audited reversal',
          );
        }
        if (isClosed('${old.data['date']}')) {
          throw StateError('Reopen this day before changing it');
        }
      }
      if (c.data['deleted'] == true && c.kind != 'party') {
        throw const FormatException('Only a party can be deleted');
      }
      if (old != null && old.deleted && c.data['deleted'] != true) {
        throw const FormatException('A deleted party cannot be restored');
      }
      if ((old?.version ?? 0) != c.expectedVersion) {
        throw StateError('This record changed. Reopen it before saving.');
      }
      next[c.id] = Record(c.id, c.kind, c.data, version: c.expectedVersion + 1);
    }
    // A party can only be deleted while it has no live entries, and a deleted
    // party takes no new ones (the server checks the same).
    for (final c in changes) {
      if (c.kind == 'party' && c.data['deleted'] == true) {
        if (next.values.any(
          (r) => _entryOf(r, c.id) && r.data['voided'] != true,
        )) {
          throw const FormatException(
            'This party has entries and cannot be deleted',
          );
        }
      } else if (c.kind == 'document' && c.data['voided'] != true) {
        final party = next['${c.data['party'] ?? ''}'];
        if (party != null && party.deleted) {
          throw const FormatException('Choose a party');
        }
        for (final id in Document(next[c.id]!).directParties) {
          if (next[id]?.deleted == true) {
            throw const FormatException(
              'Choose the party that was paid directly',
            );
          }
        }
      }
    }
    for (final c in changes.where(
      (c) => c.kind == 'document' && c.data['voided'] != true,
    )) {
      final d = Document(next[c.id]!);
      validateDocument(d, next.values.where((r) => r.id != d.id).toList());
      if (isClosed(d.date)) {
        throw StateError('Reopen this day before changing it');
      }
    }
    final projected = Book(
      next.values.toList(),
      verifyShares: {
        for (final c in changes)
          if (c.kind == 'document') c.id,
      },
    );
    if (projected.held.values.any((v) => v < 0)) {
      throw const FormatException(
        'Cylinder returns exceed this party’s outstanding cylinders',
      );
    }
    if (next.values
        .where((r) => r.kind == 'party')
        .any((r) => projected.deposits(r.id) < 0)) {
      throw const FormatException('Refund exceeds the refundable deposit');
    }
    await _enqueue(changes, action: action, reason: reason);
    await reload();
    unawaited(syncNow());
  }

  Future<void> saveMaster(
    String kind,
    Json data, {
    Record? existing,
    String? newId,
    int opening = 0,
    int supplierOpening = 0,
    String? openingDate,
  }) async {
    final id = existing?.id ?? newId ?? uuid.v4();
    // The day the opening balances are entered on (default: the page's date).
    final openedOn = openingDate == null || openingDate.isEmpty
        ? selectedDate
        : openingDate;
    if ('${data['name'] ?? ''}'.trim().isEmpty) {
      throw const FormatException('Enter a name');
    }
    final normalized = nameKey('${data['name']}');
    if (records.any(
      (r) =>
          r.kind == kind &&
          r.id != id &&
          !r.deleted &&
          nameKey(r.name) == normalized,
    )) {
      throw const FormatException('This name already exists');
    }
    final changes = [
      Change(id, kind, {...?existing?.data, ...data}, existing?.version ?? 0),
    ];
    if (existing == null) {
      for (final item in [
        (opening, kind == 'party' ? 'ar:$id' : 'money:$id'),
        (-supplierOpening, 'ap:$id'),
      ]) {
        if (item.$1 == 0) continue;
        changes.add(
          Change(uuid.v4(), 'document', {
            'type': 'adjustment',
            'date': openedOn,
            'occurredAt': 0,
            'party': kind == 'party' ? id : '',
            'target': item.$2,
            'amount': item.$1,
            'note': openingBalanceNote,
            'reference': nextReference('OP', date: openedOn),
          }, 0),
        );
      }
    }
    await commit(changes);
  }

  String nextReference(String prefix, {String? date}) =>
      '$prefix-${(date ?? selectedDate).replaceAll('-', '')}-${device.substring(0, 4).toUpperCase()}-${uuid.v4().substring(0, 8).toUpperCase()}';

  String? _quoteKey;
  int? _quoteCost;
  Object? _quoteError;

  /// What the shared bulk in [data] is charged, as [Book.shareChargeFor]
  /// will check it: from a chosen purchase ([Document.sharePurchase]), that
  /// purchase's rate for the KG if it has them left; otherwise its FIFO cost
  /// in the whole projection with this entry in place (replacing [replace]),
  /// so stock entered later (a purchase after its sales) counts too, rounded
  /// to whole rupees. Throws when that cannot be known. The last quote is
  /// kept until the next [reload], as the forms ask again on every rebuild.
  int quoteBulkCost(
    Json data, {
    Document? replace,
    String id = '~share-quote',
  }) {
    final candidate = <String, dynamic>{
      'type': 'sale',
      'date': selectedDate,
      ...data,
      // A new entry is saved now, after what is already on its date.
      'occurredAt': data['occurredAt'] ?? 9000000000000,
      'bulkAtCost': true,
      'bulkCost': 0,
    };
    final key = canonicalJson([
      id,
      replace?.id,
      candidate['date'],
      candidate['occurredAt'],
      candidate['quantities'],
      candidate['extraGrams'],
      candidate['sharePurchase'],
    ]);
    if (key != _quoteKey) {
      _quoteKey = key;
      _quoteCost = null;
      _quoteError = null;
      try {
        final current = book, last = current.documents.lastOrNull;
        final entry = Document(Record(id, 'document', candidate));
        final atEnd =
            last == null ||
            switch (last.date.compareTo(entry.date)) {
              < 0 => true,
              > 0 => false,
              _ =>
                last.value('occurredAt') < entry.value('occurredAt') ||
                    (last.value('occurredAt') == entry.value('occurredAt') &&
                        last.id.compareTo(id) < 0),
            };
        if (entry.sharePurchase.isNotEmpty) {
          final purchase = current.purchaseByReference(entry.sharePurchase);
          if (purchase == null) {
            throw const FormatException('Choose a purchase to share from');
          }
          if (entry.extraGrams >
              current.purchaseFree(purchase, except: replace?.id)) {
            throw const FormatException(
              'Shared KG exceed the selected purchase',
            );
          }
          _quoteCost = purchase.purchaseBillFor(entry.extraGrams);
        } else {
          // A new entry after everything, with nothing waiting for stock,
          // takes the current lots as they are: no replay of the whole khata.
          _quoteCost = replace == null && atEnd && current.shortageGrams == 0
              ? roundRupees(
                  current.quoteAtEnd(entry.cylinderGrams, entry.extraGrams),
                )
              : _shareCharges([
                  for (final r in records)
                    if (r.id != replace?.id && r.id != id) r,
                  entry.record,
                ], {id})[id]!;
        }
      } catch (e) {
        _quoteError = e;
      }
    }
    if (_quoteError != null) throw _quoteError!;
    return _quoteCost!;
  }

  /// [Book.shareChargeFor] for each share in [ids] when the books hold
  /// [state]. A share's charge does not change FIFO or what a purchase has
  /// left, so one projection prices them all at once.
  Map<String, int> _shareCharges(List<Record> state, Set<String> ids) {
    final projected = Book(state);
    return {
      for (final r in state)
        if (ids.contains(r.id)) r.id: projected.shareChargeFor(Document(r)),
    };
  }

  /// Sets `bulkCost` on every new purchase share in [changes] (a daily rate
  /// change, a restored day) to its charge in the state they produce, so
  /// each passes the exact-charge check in [commit] as the server applies it.
  void _priceShares(List<Change> changes) {
    final shares = {
      for (final c in changes)
        if (c.kind == 'document' &&
            c.data['voided'] != true &&
            c.data['type'] == 'sale' &&
            c.data['bulkAtCost'] == true)
          c.id,
    };
    if (shares.isEmpty) return;
    final state = {for (final r in records) r.id: r};
    for (final c in changes) {
      state[c.id] = Record(c.id, c.kind, c.data);
    }
    final charges = _shareCharges(state.values.toList(), shares);
    for (final c in changes) {
      if (shares.contains(c.id)) c.data['bulkCost'] = charges[c.id];
    }
  }

  /// The purchase a share's bulk was chosen from, as "Supplier · DD-MM-YYYY",
  /// or '' when it shares the oldest stock first (FIFO) or is not a share.
  String shareSource(Document d) {
    if (d.sharePurchase.isEmpty) return '';
    final p = book.purchaseByReference(d.sharePurchase);
    return p == null
        ? d.sharePurchase
        : '${name(p.party)} · ${p.date.split('-').reversed.join('-')}';
  }

  /// Purchases a share dated [date] can come from: from 60 days before to
  /// 7 days after it, newest first, each with the KG it still has for
  /// sharing (not counting the share [replace] being corrected). The one
  /// already [selected] is kept even outside that window.
  List<(Document, int)> sharePurchaseOptions(
    String date, {
    Document? replace,
    String selected = '',
  }) {
    final day = DateTime.parse(date);
    String shifted(int days) =>
        day.add(Duration(days: days)).toIso8601String().substring(0, 10);
    final from = shifted(-60), to = shifted(7);
    final current = book;
    return [
      for (final p in current.documents.reversed)
        if (p.type == EntryType.purchase &&
            '${p.data['reference'] ?? ''}'.isNotEmpty &&
            current.purchaseByReference('${p.data['reference']}')?.id == p.id &&
            ((p.date.compareTo(from) >= 0 && p.date.compareTo(to) <= 0) ||
                p.data['reference'] == selected))
          (p, current.purchaseFree(p, except: replace?.id)),
    ];
  }

  /// Posts a document. [before] holds master records (such as a party typed
  /// for the first time) committed atomically with it.
  Future<void> post(
    Json data, {
    Document? replace,
    String reason = '',
    List<Change> before = const [],
  }) async {
    data = cleanDocumentData(data);
    if (replace != null && (replace.voided || isClosed(replace.date))) {
      throw StateError('Reopen this day before correcting the entry');
    }
    final newId = uuid.v4();
    data = {
      ...data,
      'occurredAt': data['occurredAt'] ?? DateTime.now().millisecondsSinceEpoch,
    };
    if (data['type'] == 'sale' && data['bulkAtCost'] == true) {
      data['bulkCost'] = quoteBulkCost(data, replace: replace, id: newId);
      if (Document(Record(newId, 'document', data)).purchaseShare) {
        data['rate'] = 0;
      }
    }
    await commit(
      [
        ...before,
        if (replace != null)
          Change(replace.id, 'document', {
            ...replace.data,
            'voided': true,
            'voidReason': reason,
            'replacement': newId,
          }, replace.record.version),
        Change(newId, 'document', {
          ...data,
          'occurredAt':
              data['occurredAt'] ?? DateTime.now().millisecondsSinceEpoch,
          'reference':
              replace?.reference ??
              data['reference'] ??
              nextReference(
                data['type'] == 'sale'
                    ? 'INV'
                    : data['type'] == 'creditNote'
                    ? 'CN'
                    : 'TX',
              ),
          if (replace != null) 'replaces': replace.id,
        }, 0),
      ],
      action: replace == null ? 'save' : 'correct',
      reason: reason,
    );
  }

  Future<void> voidDocument(Document doc, String reason) async {
    if (reason.trim().isEmpty) {
      throw const FormatException('A reason is required');
    }
    if (isClosed(doc.date)) {
      throw StateError('Reopen this day before changing it');
    }
    await commit(
      [
        Change(doc.id, 'document', {
          ...doc.data,
          'voided': true,
          'voidReason': reason,
        }, doc.record.version),
      ],
      action: 'void',
      reason: reason,
    );
  }

  bool isClosed(String date) => records.any(
    (r) =>
        r.kind == 'close' &&
        '${r.data['date']}'.compareTo(date) >= 0 &&
        r.data['closed'] == true,
  );

  /// Saves the day's entries as a snapshot (Roznamcha Save, Agla Din,
  /// Khata Saaf). A day that has not changed since its latest snapshot is
  /// not stored again, so pressing Agla Din or Save repeatedly adds nothing.
  /// [batchAt] marks a Khata Saaf: that snapshot is always stored, and the
  /// time syncs with it.
  Future<void> saveSnapshot({int? batchAt}) async {
    final documents = book.documents
        .where((d) => d.date == selectedDate)
        .map((d) => d.record.toJson())
        .toList();
    final latest =
        (ofKind('snapshot')
                .where((s) => s.data['date'] == selectedDate)
                .toList()
              ..sort(
                (a, b) =>
                    '${a.data['savedAt']}'.compareTo('${b.data['savedAt']}'),
              ))
            .lastOrNull;
    if (batchAt == null &&
        latest != null &&
        canonicalJson(latest.data['documents']) == canonicalJson(documents)) {
      return;
    }
    await commit([
      Change(uuid.v4(), 'snapshot', {
        'date': selectedDate,
        'name': selectedDate,
        'savedAt': DateTime.now().toIso8601String(),
        'documents': documents,
        'batchAt': ?batchAt,
      }, 0),
    ]);
  }

  Future<void> restoreSnapshot(Record snapshot, String reason) async {
    final date = '${snapshot.data['date']}';
    if (reason.trim().isEmpty || isClosed(date)) {
      throw StateError('Reopen the day and enter a restoration reason');
    }
    final original = (snapshot.data['documents'] as List)
        .map((v) => Record.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    final ids = {for (final r in original) r.id: uuid.v4()};
    final changes = <Change>[];
    for (final d in book.documents.where((d) => d.date == date)) {
      changes.add(
        Change(d.id, 'document', {
          ...d.data,
          'voided': true,
          'voidReason': reason,
        }, d.record.version),
      );
    }
    for (final r in original) {
      changes.add(
        Change(ids[r.id]!, 'document', {
          ...r.data,
          'voided': false,
          'restoredFrom': r.id,
          if (r.data['sourceInvoice'] != null)
            'sourceInvoice':
                ids[r.data['sourceInvoice']] ?? r.data['sourceInvoice'],
          if (r.data['allocations'] is Map)
            'allocations': {
              for (final e in (r.data['allocations'] as Map).entries)
                ids[e.key] ?? e.key: e.value,
            },
        }, 0),
      );
    }
    // Restored shares are saved again, so they take today's FIFO cost.
    _priceShares(changes);
    await commit(changes, action: 'restore', reason: reason);
  }

  /// Khata Saaf: entries of the day made so far are counted in the opening
  /// from now on ([batchStarts]).
  Future<void> startBatch() =>
      saveSnapshot(batchAt: DateTime.now().millisecondsSinceEpoch);

  Future<void> closeDay({bool reopen = false, required String reason}) async {
    if (!signedIn) throw StateError('Connect and sign in before closing a day');
    await syncNow();
    if (pendingCount != 0 ||
        conflictCount != 0 ||
        sync!.message != 'Up to date') {
      throw StateError('Resolve pending changes before closing');
    }
    if (reason.trim().isEmpty) {
      throw const FormatException('A reason is required');
    }
    final existing = record('close:$selectedDate');
    await commit(
      [
        Change('close:$selectedDate', 'close', {
          'date': selectedDate,
          'closed': !reopen,
          'name': selectedDate,
          'reason': reason,
          'expected_sequence': integer(await db.meta('cursor')),
        }, existing?.version ?? 0),
      ],
      action: reopen ? 'reopen' : 'close',
      reason: reason,
    );
    await syncNow();
    if (conflictCount > 0) throw StateError('Review changes');
  }

  Future<void> applyDailyRate(int rate, String reason) async {
    if (rate <= 0 || reason.trim().isEmpty) {
      throw const FormatException('Enter a rate and reason');
    }
    if (isClosed(selectedDate)) throw StateError('Reopen the day first');
    final changes = <Change>[];
    for (final d in book.documents.where(
      // Sales already at this rate need no audited correction.
      (d) =>
          d.date == selectedDate &&
          d.type == EntryType.sale &&
          !d.purchaseShare &&
          d.rate != rate,
    )) {
      final id = uuid.v4();
      changes.add(
        Change(d.id, 'document', {
          ...d.data,
          'voided': true,
          'voidReason': reason,
          'replacement': id,
        }, d.record.version),
      );
      changes.add(
        Change(id, 'document', {...d.data, 'rate': rate, 'replaces': d.id}, 0),
      );
    }
    // A mixed entry's shared bulk keeps its place, but as a newly saved share
    // it must match today's FIFO cost (normally unchanged, or a few paisa).
    _priceShares(changes);
    await commit(changes, action: 'correct', reason: reason);
  }

  Future<void> dismissConflict(Command command) async {
    await db.commandState(command.id, 'dismissed');
    await reload();
  }

  Future<void> recoverCloud() async {
    if (sync == null || sync!.running) {
      throw StateError('Connect and sign in to recover');
    }
    final transport = sync!.transport;
    final state = await transport.status();
    final epoch = '${state['epoch']}';
    final bundles = <Json>[];
    var cursor = 0;
    while (true) {
      final page = await transport.pull(epoch, cursor);
      if (page.isEmpty) break;
      bundles.addAll(page);
      cursor = integer(page.last['sequence']);
      if (page.length < 100) break;
    }
    final recovery = await backup();
    sync!.dispose();
    await db.transaction(() async {
      await db.customStatement('DELETE FROM records');
      await db.setMeta('cursor', '0');
      await db.applyBundles(bundles, cursor);
      await db.setMeta('epoch', epoch);
      await db.customStatement(
        "UPDATE commands SET status='quarantined',error='Review after cloud recovery' WHERE status IN ('queued','sending','accepted','conflict','rejected')",
      );
      await db.setMeta('pre_restore', jsonEncode(recovery));
    });
    sync = SyncService(db, transport, () {
      unawaited(reload());
    });
    await reload();
    await syncNow();
  }

  /// Settings → Reset all data. Erases every party, account, entry, closed
  /// day, snapshot, batch, pending or rejected change, draft and recovery copy
  /// of the open organization, then starts again with only the default cash
  /// account and business profile (an organization keeps its name, see
  /// [_seedDefaults]). Other organizations on the device are separate files
  /// and are not touched. A device linked to a cloud account erases the cloud dataset
  /// first (otherwise the next sync would download it all again); the new
  /// epoch makes other devices stop and "Reconnect to cloud". Kept: the device
  /// id, language, cloud connection and sign-in ([KhataDatabase.keptOnWipe]).
  ///
  /// Anything new that holds business data must be cleared here too. A new
  /// SQLite table is emptied automatically and a new metadata key is erased
  /// unless it is added to `keptOnWipe`; new in-memory state (like [rozDrafts])
  /// and new server tables are not, so reset them below and in
  /// `public.reset_dataset`.
  Future<void> resetAll() async {
    final cloud = owner == null ? null : sync;
    if (owner != null) {
      if (cloud == null) {
        throw StateError('Sign in first so the cloud copy is erased too');
      }
      if (cloud.running) throw StateError('Wait for the sync to finish');
      cloud.dispose();
    }
    try {
      String? epoch;
      if (cloud != null) {
        final state = await cloud.transport.status();
        final fresh = await cloud.transport.reset('${state['epoch']}');
        epoch = '${fresh['epoch']}';
      }
      await db.transaction(() async {
        await db.wipe();
        // Before the defaults: an organization's name is queued with them.
        if (epoch != null) await db.setMeta('epoch', epoch);
        await _seedDefaults();
      });
    } finally {
      if (cloud != null) {
        sync = SyncService(db, cloud.transport, () {
          unawaited(reload());
        });
      }
    }
    try {
      // Also drop the erased rows from the file on disk.
      await db.customStatement('VACUUM');
    } catch (_) {}
    rozDrafts.clear();
    composerDrafts.clear();
    selectedDate = businessDate();
    lastError = null;
    await reload();
    await syncNow();
  }

  /// The backup made just before the last restore or cloud reconnect, which
  /// can itself be restored to undo that step; null when there is none.
  Future<Json?> preRestoreCopy() async {
    final text = await db.meta('pre_restore');
    return text == null ? null : decodeObject(text);
  }

  Future<Json> backup() async {
    final data = await db.exportData();
    (data['metadata'] as Map).remove('pre_restore');
    return {
      'app': 'zubair-khata',
      'version': 1,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'data': data,
      'sha256': sha256.convert(utf8.encode(jsonEncode(data))).toString(),
    };
  }

  /// The business name inside a backup file, or null when it has none. Shown
  /// before restoring, so a backup of one organization is not restored into
  /// another by mistake.
  static String? backupBusinessName(Json backup) {
    try {
      final data = backup['data'] as Map;
      String? name;
      for (final item in data['records'] as List) {
        final r = Record.fromJson(Map<String, dynamic>.from(item as Map));
        if (r.id == 'business') name = r.name;
      }
      for (final item in data['commands'] as List) {
        final c = Command.fromJson(Map<String, dynamic>.from(item as Map));
        if (!['queued', 'sending', 'accepted'].contains(c.status)) continue;
        for (final change in c.changes) {
          if (change.id == 'business') name = '${change.data['name'] ?? ''}';
        }
      }
      return name == null || name.trim().isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  Future<void> restoreBackup(Json backup) async {
    if (backup['app'] != 'zubair-khata' ||
        integer(backup['version']) != 1 ||
        backup['data'] is! Map) {
      throw const FormatException('Invalid backup');
    }
    final data = Map<String, dynamic>.from(backup['data'] as Map);
    if (integer(data['schema']) != 1) {
      throw const FormatException('Unsupported backup version');
    }
    if (sha256.convert(utf8.encode(jsonEncode(data))).toString() !=
        backup['sha256']) {
      throw const FormatException('Backup checksum failed');
    }
    final meta = Map<String, dynamic>.from(data['metadata'] as Map);
    if (owner != null && meta['owner'] != owner) {
      throw const FormatException('Backup belongs to a different owner');
    }
    // Stage and validate the complete effective dataset before mutation.
    final staged = <String, Record>{};
    for (final item in data['records'] as List) {
      final r = Record.fromJson(Map<String, dynamic>.from(item as Map));
      staged[r.id] = r;
    }
    for (final item in data['commands'] as List) {
      final c = Command.fromJson(Map<String, dynamic>.from(item as Map));
      if (['queued', 'sending', 'accepted'].contains(c.status)) {
        for (final change in c.changes) {
          staged[change.id] = Record(
            change.id,
            change.kind,
            change.data,
            version: change.expectedVersion + 1,
          );
        }
      }
    }
    for (final r in staged.values.where(
      (r) => r.kind == 'document' && r.data['voided'] != true,
    )) {
      validateDocument(
        Document(r),
        staged.values.where((other) => other.id != r.id).toList(),
      );
    }
    Book(staged.values.toList());
    final recovery = await this.backup();
    await db.setMeta('pre_restore', jsonEncode(recovery));
    if (owner != null) {
      // Cloud-confirmed records remain authoritative. Recover only missing commands.
      final known = commands.map((c) => c.id).toSet();
      for (final item in data['commands'] as List) {
        final c = Command.fromJson(Map<String, dynamic>.from(item as Map));
        if (!known.contains(c.id) &&
            ['queued', 'sending', 'accepted'].contains(c.status)) {
          await db.queue(c);
        }
      }
    } else {
      await db.restoreLocal(data);
      await db.setMeta('device', device);
      owner = meta['owner'] as String?;
    }
    await db.setMeta('pre_restore', jsonEncode(recovery));
    await reload();
    await syncNow();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sync?.dispose();
    _poll?.cancel();
    _auth?.cancel();
    super.dispose();
  }

  /// Stops this controller and closes its database and cloud client, so that
  /// another organization can be opened. Nothing is signed out.
  Future<void> close() async {
    final running = sync?.idle;
    dispose();
    // A synchronization under way still writes to this database.
    await running;
    if (client != null) {
      client = null;
      try {
        await Supabase.instance.dispose();
      } catch (_) {
        // The next organization starts its own client either way.
      }
    }
    await db.close();
  }
}
