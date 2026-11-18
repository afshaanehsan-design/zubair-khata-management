import 'package:uuid/uuid.dart';

import '../../core/models.dart';
import 'book.dart';

/// Saved drafts use the ordinary accounting projection. Only supplied,
/// usable values are included; a missing price is never guessed. The source
/// records and draft form values are left untouched.
class DraftProjection {
  final List<Record> records;
  final _parties = <String, Record>{};
  final _accounts = <String, Record>{};
  final _extra = <String, Record>{};
  final _documents = <Record>[];
  final _draftPartyNames = <String, String>{};
  static const _uuid = Uuid();

  DraftProjection(List<Record> posted, List<EntryDraft> drafts)
    : records = [...posted] {
    for (final r in posted) {
      if (r.kind == 'party' && !r.deleted) _parties[_key(r.name)] = r;
      if (r.kind == 'account' && !r.deleted) _accounts[r.id] = r;
    }
    final ids = posted.map((r) => r.id).toSet();
    final credits = <Record>[];
    // Resolve a composer selection of a party first named in another
    // draft, regardless of which draft was most recently saved.
    void remember(dynamic name) {
      final text = '${name ?? ''}'.trim();
      if (text.isNotEmpty) {
        _draftPartyNames[_uuid.v5(
              Namespace.url.value,
              'khata-draft-party:${_key(text)}',
            )] =
            text;
      }
    }

    for (final d in drafts) {
      if (d.source == EntryDraft.roznamcha) {
        remember(d.data['party']);
        remember(d.data['directParty']);
        if (d.data['extraBanks'] is List) {
          for (final line in (d.data['extraBanks'] as List).whereType<Map>()) {
            remember(line['company']);
          }
        }
      }
      if (d.data['draftParties'] is Map) {
        for (final entry in (d.data['draftParties'] as Map).entries) {
          if (entry.value is Map) {
            _draftPartyNames['${entry.key}'] =
                '${(entry.value as Map)['name'] ?? ''}';
          }
        }
      }
    }
    // Oldest first also makes roles and unnamed-party identities stable.
    for (final d in drafts.reversed) {
      if (ids.contains(d.id) || !_date(d.date)) continue;
      final data = d.source == EntryDraft.roznamcha
          ? _roznamcha(d)
          : _composer(d);
      if (data == null) continue;
      final record = Record(d.id, 'document', {
        ...data,
        'date': d.date,
        'occurredAt':
            d.data['draftOccurredAt'] ?? data['occurredAt'] ?? d.savedAt,
        'reference':
            data['reference'] ??
            '${data['type'] == 'sale' ? 'INV' : 'TX'}-'
                '${d.date.replaceAll('-', '')}-${d.id.substring(0, d.id.length.clamp(0, 8)).toUpperCase()}',
      }, draftId: d.id);
      (data['type'] == 'creditNote' ? credits : _documents).add(record);
    }
    records.addAll([..._extra.values, ..._documents]);
    // A credit note needs its original live invoice. An unfinished or stale
    // credit-note draft must never make every balance/report fail to open.
    for (final credit in credits) {
      final source = records
          .where(
            (r) =>
                r.kind == 'document' &&
                r.id == credit.data['sourceInvoice'] &&
                r.data['type'] == 'sale' &&
                r.data['voided'] != true,
          )
          .firstOrNull;
      if (source == null ||
          '${source.data['date']}'.compareTo(credit.data['date']) > 0 ||
          records.any(
            (r) =>
                r.kind == 'document' &&
                r.data['type'] == 'creditNote' &&
                r.data['voided'] != true &&
                r.data['sourceInvoice'] == source.id,
          )) {
        continue;
      }
      try {
        final normalized = _creditFor(credit, source);
        Book([...records, normalized]);
        records.add(normalized);
      } on FormatException {
        // The original stock cost may still be missing.
      }
    }
    if (_documents.any((r) => r.data['bulkAtCost'] == true)) {
      final priced = Book(records);
      for (var i = 0; i < records.length; i++) {
        final r = records[i];
        if (r.draftId == null ||
            r.kind != 'document' ||
            r.data['type'] != 'sale' ||
            r.data['bulkAtCost'] != true) {
          continue;
        }
        var cost = 0;
        try {
          cost = priced.shareChargeFor(Document(r));
        } on FormatException {
          // Collections and quantities still count while cost is unknown.
        }
        records[i] = Record(r.id, r.kind, {
          ...r.data,
          'bulkCost': cost,
        }, draftId: r.draftId);
      }
    }
    // A draft invoice's share may have just been priced. Its draft credit
    // note must display the same quantities and charge as that invoice.
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      if (r.draftId != null &&
          r.kind == 'document' &&
          r.data['type'] == 'creditNote') {
        final source = records.firstWhere(
          (s) => s.id == r.data['sourceInvoice'],
        );
        records[i] = _creditFor(r, source);
      }
    }
  }

  static Record _creditFor(Record credit, Record source) {
    const fields = [
      'quantities',
      'rate',
      'extraGrams',
      'bulkAtCost',
      'bulkCost',
      'sharePurchase',
    ];
    final data = {...credit.data}
      ..removeWhere((key, _) => fields.contains(key));
    return Record(credit.id, 'document', {
      ...data,
      'party': source.data['party'],
      for (final key in fields)
        if (source.data.containsKey(key)) key: source.data[key],
    }, draftId: credit.draftId);
  }

  static String _key(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static bool _date(String date) {
    final parsed = DateTime.tryParse(date);
    return parsed != null && parsed.toIso8601String().substring(0, 10) == date;
  }

  static int _number(dynamic value, [int? places]) {
    try {
      final n = places == null
          ? integer(value)
          : decimal('${value ?? ''}', places);
      return n.abs() <= 9000000000000 ? n : 0;
    } on FormatException {
      return 0;
    }
  }

  static int _positive(dynamic value, [int? places]) {
    final n = _number(value, places);
    return n > 0 ? n : 0;
  }

  String _party(EntryDraft d, String name, String role) {
    final key = _key(name);
    final found = key.isEmpty ? null : _parties[key];
    if (found != null) {
      if (found.draftId != null && found.data[role] != true) {
        final updated = Record(found.id, 'party', {
          ...found.data,
          role: true,
        }, draftId: found.draftId);
        _parties[key] = updated;
        _extra[updated.id] = updated;
      }
      return found.id;
    }
    final id = key.isEmpty
        ? 'draft-party:${d.id}:$role'
        : _uuid.v5(Namespace.url.value, 'khata-draft-party:$key');
    final r = Record(id, 'party', {
      'name': key.isEmpty
          ? 'Unassigned party'
          : name.trim().replaceAll(RegExp(r'\s+'), ' '),
      'customer': role == 'customer',
      'supplier': role == 'supplier',
      'udhari': role == 'udhari',
      'archived': false,
      if (key.isEmpty) 'unassignedDraft': true,
    }, draftId: d.id);
    if (key.isNotEmpty) _parties[key] = r;
    _extra[id] = r;
    return id;
  }

  String _account(EntryDraft d, dynamic value, {bool cash = false}) {
    final id = '${value ?? ''}';
    if (_accounts.containsKey(id) && (cash || id != 'cash')) return id;
    if (cash && id.isEmpty) return 'cash';
    const unknown = 'draft-bank';
    _extra.putIfAbsent(
      unknown,
      () => Record(unknown, 'account', {
        'name': 'Unassigned bank',
        'category': 'Bank',
        'unassignedDraft': true,
      }, draftId: d.id),
    );
    return unknown;
  }

  String _partyId(EntryDraft d, dynamic value, String role) {
    final id = '${value ?? ''}';
    if (records.any((r) => r.id == id && r.kind == 'party' && !r.deleted)) {
      return id;
    }
    return _party(d, _draftPartyNames[id] ?? '', role);
  }

  Json? _roznamcha(EntryDraft d) {
    final s = d.data;
    int money(String key) => _positive(s[key], 2);
    final base = <String, dynamic>{
      'note': '${s['note'] ?? ''}',
      'vehicle': '${s['vehicle'] ?? ''}',
    };
    String party([String role = 'customer']) =>
        _party(d, '${s['party'] ?? ''}', role);
    switch (d.tab) {
      case 'aamad':
        final q = {
          for (final size in sizes) '$size': _positive(s['q$size'], 0),
        };
        final bulk = _positive(s['bulk'], 3);
        final sale = q.values.any((n) => n > 0) || bulk > 0;
        final pid = party();
        final lines = <Json>[];
        void bank(
          dynamic amount,
          dynamic account,
          bool direct,
          dynamic company,
          dynamic bankName,
        ) {
          final n = _positive(amount, 2);
          if (n == 0) return;
          lines.add({
            'amount': n,
            if (direct) ...{
              'party': _party(d, '${company ?? ''}', 'supplier'),
              'bankName': '${bankName ?? ''}',
            } else
              'account': _account(d, account),
          });
        }
        bank(
          s['bank'],
          s['account'],
          s['bankDirect'] == true,
          s['directParty'],
          s['directBank'],
        );
        if (s['extraBanks'] is List) {
          for (final l in (s['extraBanks'] as List).whereType<Map>()) {
            bank(
              l['amount'],
              l['account'],
              l['direct'] == true,
              l['company'],
              l['bankName'],
            );
          }
        }
        return {
          ...base,
          'type': sale ? 'sale' : 'receipt',
          'form': 'aamad',
          'party': pid,
          'cash': money('cash'),
          'bankLines': lines,
          if (sale) ...{
            'quantities': q,
            'returned': {
              for (final size in sizes)
                '$size': s['customerOwned'] == true
                    ? 0
                    : s['returnedEdited'] is List &&
                          (s['returnedEdited'] as List)
                              .map(integer)
                              .contains(size)
                    ? _positive(s['r$size'], 0)
                    : q['$size'],
            },
            'rate': money('rate'),
            'extraGrams': bulk,
            if (bulk > 0 && s['bulkAtCost'] != false) 'bulkAtCost': true,
            if (bulk > 0 &&
                s['bulkAtCost'] != false &&
                '${s['sharePurchase'] ?? ''}'.isNotEmpty)
              'sharePurchase': s['sharePurchase'],
            'customerOwned': s['customerOwned'] == true,
            'depositCharge': s['customerOwned'] == true ? 0 : money('deposit'),
            'dueDate': '${s['dueDate'] ?? ''}',
          },
        };
      case 'kharcha' || 'office':
        final kind = '${s['kind'] ?? 'cash'}';
        final account = s['payBank'] == true
            ? _account(d, s['account'])
            : 'cash';
        if (d.tab == 'office' || kind == 'cash') {
          return {
            ...base,
            'type': 'expense',
            'form': d.tab,
            'amount': money('amount'),
            'account': account,
            'category': d.tab == 'office' ? 'Office' : 'General',
          };
        }
        if (kind == 'bankJama') {
          return {
            ...base,
            'type': 'transfer',
            'form': 'bankJama',
            'amount': money('amount'),
            'account': 'cash',
            'toAccount': _account(d, s['account']),
          };
        }
        final company = kind == 'company', udhar = kind == 'udharWapsi';
        return {
          ...base,
          'type': 'payment',
          'amount': money('amount'),
          'party': party(
            company
                ? 'supplier'
                : udhar
                ? 'udhari'
                : 'customer',
          ),
          'account': account,
          'supplierPayment': company || udhar,
          'form': company
              ? 'companyPay'
              : udhar
              ? 'udharWapsi'
              : 'customerPay',
          'branch': '${s['branch'] ?? ''}',
          'customerNote': '${s['customerNote'] ?? ''}',
        };
      case 'nikali':
        return {
          ...base,
          'type': 'transfer',
          'form': 'nikali',
          'amount': money('amount'),
          'account': _account(d, s['account']),
          'toAccount': 'cash',
        };
      case 'less':
        final mode = '${s['lessMode'] ?? 'discount'}';
        if (mode == 'cashIn' || mode == 'cashOut') {
          return {
            ...base,
            'type': 'adjustment',
            'target': 'money:cash',
            'amount': mode == 'cashOut' ? -money('amount') : money('amount'),
          };
        }
        return {
          ...base,
          'party': party(),
          'form': 'less',
          if (mode == 'bank') ...{
            'type': 'receipt',
            'bank': money('amount'),
            'bankAccount': _account(d, s['account']),
          } else ...{
            'type': 'discount',
            'amount': money('amount'),
          },
        };
      case 'companyIn':
        return {
          ...base,
          'type': 'receipt',
          'form': 'companyIn',
          'party': party('supplier'),
          'supplierRefund': true,
          'cash': money('cash'),
          'bank': money('bank'),
          'bankAccount': money('bank') > 0 ? _account(d, s['account']) : '',
        };
      default:
        return null;
    }
  }

  Json? _composer(EntryDraft d) {
    final type = EntryType.values.where((v) => v.name == d.tab).firstOrNull;
    if (type == null) return null;
    final s = d.data;
    final data = cleanDocumentData({...s, 'type': type.name});
    for (final key in [
      'amount',
      'cash',
      'bank',
      'direct',
      'rate',
      'cost',
      'bulkCost',
      'depositCharge',
      'extraGrams',
      'grams',
      'rateUnit',
      'size',
      'count',
    ]) {
      if (s.containsKey(key)) data[key] = _positive(s[key]);
    }
    for (final key in ['fullDelta', 'emptyDelta', 'heldDelta']) {
      if (s.containsKey(key)) data[key] = _number(s[key]);
    }
    if (type == EntryType.adjustment) data['amount'] = _number(s['amount']);
    if (type == EntryType.stockAdjustment) data['grams'] = _number(s['grams']);
    for (final key in ['quantities', 'returned']) {
      if (s[key] is Map) {
        data[key] = {
          for (final size in sizes)
            '$size': _positive((s[key] as Map)['$size']),
        };
      } else {
        data.remove(key);
      }
    }
    // Composer parties are record ids, unlike the Roznamcha's typed names.
    if ([
          EntryType.sale,
          EntryType.receipt,
          EntryType.payment,
          EntryType.purchase,
          EntryType.discount,
          EntryType.deposit,
          EntryType.depositRefund,
        ].contains(type) ||
        (type == EntryType.cylinder && _number(data['heldDelta']) != 0)) {
      data['party'] = _partyId(
        d,
        s['party'],
        type == EntryType.purchase ||
                s['supplierPayment'] == true ||
                s['supplierRefund'] == true
            ? 'supplier'
            : 'customer',
      );
    }
    if ([
      EntryType.payment,
      EntryType.expense,
      EntryType.purchase,
      EntryType.transfer,
      EntryType.deposit,
      EntryType.depositRefund,
    ].contains(type)) {
      data['account'] = _account(
        d,
        s['account'],
        cash: type != EntryType.transfer,
      );
    }
    if (_positive(data['bank']) > 0) {
      data['bankAccount'] = _account(d, s['bankAccount']);
    }
    if (_positive(data['direct']) > 0) {
      data['directParty'] = _partyId(d, s['directParty'], 'supplier');
    }
    if (s['bankLines'] is List) {
      data['bankLines'] = [
        for (final l in (s['bankLines'] as List).whereType<Map>())
          if (_positive(l['amount']) > 0)
            {
              'amount': _positive(l['amount']),
              if ('${l['party'] ?? ''}'.isNotEmpty) ...{
                'party': _partyId(d, l['party'], 'supplier'),
                'bankName': '${l['bankName'] ?? ''}',
              } else
                'account': _account(d, l['account']),
            },
      ];
    }
    if (type == EntryType.transfer) {
      data['toAccount'] = _account(d, s['toAccount']);
    }
    if (type == EntryType.adjustment && '${s['target'] ?? ''}'.isEmpty) {
      return null;
    }
    if (type == EntryType.cylinder && !sizes.contains(data['size'])) {
      return null;
    }
    // Empty or malformed allocation hints must not settle unrelated bills.
    if (data['allocations'] is! Map) data.remove('allocations');
    return data;
  }
}
