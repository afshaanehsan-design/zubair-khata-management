import '../../core/models.dart';

class Posting {
  final String document;
  final String date;
  final String account;
  final int debit;
  const Posting(this.document, this.date, this.account, this.debit);
}

class FifoAllocation {
  final String sale;
  final String lot;
  final int grams;
  final int cost;
  const FifoAllocation(this.sale, this.lot, this.grams, this.cost);
}

class StockLot {
  final String id;
  final String date;
  int grams;
  int? cost;
  StockLot(this.id, this.date, this.grams, this.cost);
}

/// A deterministic projection of source documents; never edit a stored balance.
class Book {
  final List<Record> records;
  final List<Document> documents = [];
  final List<Posting> postings = [];
  final Map<String, int> balances = {};
  final List<FifoAllocation> allocations = [];
  final List<StockLot> lots = [];
  final Map<String, int> full = {}, empty = {}, held = {};
  final Map<String, int> invoiceDue = {};
  final Map<String, List<(String, int)>> receiptAllocations = {};
  final Map<String, int> uncostedSales = {};
  int gasGrams = 0,
      cylinderSales = 0,
      extraBilling = 0,
      costOfSales = 0,
      expenseTotal = 0;
  int shortageGrams = 0;

  Book(this.records, {String? throughDate}) {
    documents.addAll(
      records
          .where((r) => r.kind == 'document')
          .map(Document.new)
          .where(
            (d) =>
                !d.voided &&
                (throughDate == null || d.date.compareTo(throughDate) <= 0),
          ),
    );
    documents.sort((a, b) {
      final date = a.date.compareTo(b.date);
      if (date != 0) return date;
      final time = integer(a.data['occurredAt'])
          .compareTo(integer(b.data['occurredAt']));
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    for (final d in documents) {
      _project(d);
    }
    _allocateReceipts();
    for (final p in postings) {
      balances.update(p.account, (v) => v + p.debit, ifAbsent: () => p.debit);
    }
  }

  void _line(Document d, String account, int debit) {
    if (debit != 0) postings.add(Posting(d.id, d.date, account, debit));
  }

  void _pair(Document d, String debit, String credit, int amount) {
    _line(d, debit, amount);
    _line(d, credit, -amount);
  }

  int balance(String account) => balances[account] ?? 0;
  int receivable(String party) => balance('ar:$party');
  int payable(String party) => -balance('ap:$party');

  /// What the party owes you net of what you owe it: both sides of its khata
  /// (`ar:` and `ap:`), the balance its ledger runs to. Negative when you owe
  /// the party, e.g. a customer entered with an opening payable or paid in
  /// advance. Refundable deposits are kept apart.
  int partyBalance(String party) => receivable(party) - payable(party);
  int deposits(String party) => -balance('deposit:$party');
  int money(String account) => balance('money:$account');
  int get receivables => records
      .where((r) => r.kind == 'party')
      .fold(0, (v, p) => v + (receivable(p.id) > 0 ? receivable(p.id) : 0));
  int get payables => records
      .where((r) => r.kind == 'party')
      .fold(
        0,
        (v, p) =>
            v +
            (payable(p.id) > 0 ? payable(p.id) : 0) +
            (receivable(p.id) < 0 ? -receivable(p.id) : 0),
      );
  int get grossProfit => cylinderSales - costOfSales;
  int get netProfit => grossProfit - expenseTotal;
  bool get profitIncomplete =>
      extraBilling != 0 ||
      uncostedSales.isNotEmpty ||
      lots.any((l) => l.cost == null && l.grams > 0) ||
      documents.any((d) => d.type == EntryType.historicalSale);

  void _stockOut(Document d, int grams) {
    gasGrams -= grams;
    var remaining = grams;
    for (final lot in lots) {
      if (remaining <= 0) break;
      if (lot.grams <= 0) continue;
      final used = remaining < lot.grams ? remaining : lot.grams;
      if (lot.cost == null) {
        uncostedSales.update(d.id, (v) => v + used, ifAbsent: () => used);
      } else {
        final cost = multiplyDivide(lot.cost!, used, lot.grams);
        lot.cost = lot.cost! - cost;
        allocations.add(FifoAllocation(d.id, lot.id, used, cost));
        if (d.type == EntryType.stockAdjustment) {
          expenseTotal += cost;
        } else {
          costOfSales += cost;
        }
        _pair(
          d,
          d.type == EntryType.stockAdjustment ? 'expense:Stock loss' : 'cogs',
          'inventory',
          cost,
        );
      }
      lot.grams -= used;
      remaining -= used;
    }
    if (remaining > 0) {
      shortageGrams += remaining;
      uncostedSales.update(
        d.id,
        (v) => v + remaining,
        ifAbsent: () => remaining,
      );
    }
  }

  void _stockIn(Document d, int grams, int? cost) {
    final covered = shortageGrams < grams ? shortageGrams : grams;
    final reserve = cost == null ? null : multiplyDivide(cost, covered, grams);
    if (reserve != null && covered > 0) {
      // A later lot covers the physical deficit, but earlier margin remains provisional.
      _pair(d, 'cogs:shortage', 'inventory', reserve);
      costOfSales += reserve;
    }
    shortageGrams -= covered;
    lots.add(
      StockLot(
        d.id,
        d.date,
        grams - covered,
        cost == null ? null : cost - reserve!,
      ),
    );
  }

  void _project(Document d) {
    final amount = d.value('amount');
    final cash = d.value('cash');
    switch (d.type) {
      case EntryType.sale:
        cylinderSales += d.cylinderRevenue;
        extraBilling += d.bulkRevenue;
        _line(d, 'ar:${d.party}', d.total);
        _line(d, 'revenue:gas', -d.cylinderRevenue);
        _line(d, 'revenue:bulk', -d.bulkRevenue);
        _line(d, 'deposit:${d.party}', -d.value('depositCharge'));
        _pair(d, 'money:cash', 'ar:${d.party}', cash);
        for (final l in d.bankLines) {
          _pair(
            d,
            l.direct ? 'ap:${l.party}' : 'money:${l.account}',
            'ar:${d.party}',
            l.amount,
          );
        }
        _stockOut(d, d.cylinderGrams);
        if (d.data['customerOwned'] != true) {
          for (final size in sizes) {
            final issued = integer((d.data['quantities'] as Map?)?['$size']);
            final returned = integer((d.data['returned'] as Map?)?['$size']);
            full.update('$size', (v) => v - issued, ifAbsent: () => -issued);
            empty.update(
              '$size',
              (v) => v + returned,
              ifAbsent: () => returned,
            );
            held.update(
              '${d.party}:$size',
              (v) => v + issued - returned,
              ifAbsent: () => issued - returned,
            );
          }
        }
      case EntryType.receipt:
        final credit = d.data['supplierRefund'] == true
            ? 'ap:${d.party}'
            : 'ar:${d.party}';
        _pair(d, 'money:cash', credit, cash);
        for (final l in d.bankLines) {
          _pair(
            d,
            l.direct ? 'ap:${l.party}' : 'money:${l.account}',
            l.direct ? 'ar:${d.party}' : credit,
            l.amount,
          );
        }
      case EntryType.payment:
        _pair(
          d,
          d.data['supplierPayment'] == true ? 'ap:${d.party}' : 'ar:${d.party}',
          'money:${d.account}',
          amount,
        );
      case EntryType.expense:
        _pair(
          d,
          'expense:${d.data['category'] ?? 'General'}',
          'money:${d.account}',
          amount,
        );
        expenseTotal += amount;
      case EntryType.purchase:
        _pair(d, 'inventory', 'ap:${d.party}', d.purchaseBill);
        _pair(d, 'ap:${d.party}', 'money:${d.account}', amount);
        gasGrams += d.value('grams');
        _stockIn(d, d.value('grams'), d.purchaseBill);
      case EntryType.transfer:
        _pair(d, 'money:${d.data['toAccount']}', 'money:${d.account}', amount);
      case EntryType.discount:
        _pair(d, 'expense:Write-off', 'ar:${d.party}', amount);
        expenseTotal += amount;
      case EntryType.adjustment:
        final target = '${d.data['target'] ?? 'ar:${d.party}'}';
        _pair(d, target, 'equity:opening', amount);
      case EntryType.stockAdjustment:
        final grams = d.value('grams');
        gasGrams += grams;
        final cost = d.data['costKnown'] == true ? d.value('cost') : null;
        if (grams > 0) {
          _stockIn(d, grams, cost);
          if (cost != null) _pair(d, 'inventory', 'equity:opening', cost);
        } else if (grams < 0) {
          gasGrams -= grams;
          _stockOut(d, -grams);
        }
      case EntryType.cylinder:
        final size = '${d.value('size')}';
        full.update(
          size,
          (v) => v + d.value('fullDelta'),
          ifAbsent: () => d.value('fullDelta'),
        );
        empty.update(
          size,
          (v) => v + d.value('emptyDelta'),
          ifAbsent: () => d.value('emptyDelta'),
        );
        if (d.party.isNotEmpty) {
          held.update(
            '${d.party}:$size',
            (v) => v + d.value('heldDelta'),
            ifAbsent: () => d.value('heldDelta'),
          );
        }
      case EntryType.deposit:
        _pair(d, 'money:${d.account}', 'deposit:${d.party}', amount);
      case EntryType.depositRefund:
        _pair(d, 'deposit:${d.party}', 'money:${d.account}', amount);
      case EntryType.historicalSale:
        cylinderSales += amount;
        _stockOut(d, d.value('grams'));
      case EntryType.creditNote:
        final original = documents
            .where((s) => s.id == d.data['sourceInvoice'])
            .firstOrNull;
        if (original == null) {
          throw const FormatException('Void the related credit note first');
        }
        cylinderSales -= original.cylinderRevenue;
        extraBilling -= original.bulkRevenue;
        _line(d, 'revenue:gas', original.cylinderRevenue);
        _line(d, 'revenue:bulk', original.bulkRevenue);
        _line(d, 'ar:${d.party}', -original.bill);
        if (d.data['stockReturned'] == true) {
          if (uncostedSales.containsKey(original.id)) {
            throw const FormatException(
              'Record the missing purchase cost before returning stock',
            );
          }
          final sourceCosts = allocations.where((a) => a.sale == original.id);
          final knownGrams = sourceCosts.fold(0, (v, a) => v + a.grams);
          final cost = sourceCosts.fold(0, (v, a) => v + a.cost);
          _pair(d, 'inventory', 'cogs', cost);
          costOfSales -= cost;
          gasGrams += original.cylinderGrams;
          if (original.cylinderGrams > 0) {
            _stockIn(
              d,
              original.cylinderGrams,
              knownGrams == original.cylinderGrams ? cost : null,
            );
          }
        }
    }
  }

  void _allocateReceipts() {
    final order = <String>[],
        due = <String, int>{},
        owners = <String, String>{},
        invoices = <String>{};
    final credits = <String, List<_Credit>>{};
    void reduce(String claim, int amount, String source) {
      due[claim] = due[claim]! - amount;
      if (invoices.contains(claim)) {
        invoiceDue[claim] = due[claim]!;
        receiptAllocations.putIfAbsent(source, () => []).add((claim, amount));
      }
    }

    void addClaim(String party, String id, int amount, {bool invoice = false}) {
      order.add(id);
      owners[id] = party;
      due[id] = amount;
      if (invoice) {
        invoices.add(id);
        invoiceDue[id] = amount;
      }
      for (final credit in credits[party] ?? <_Credit>[]) {
        final used = credit.remaining < due[id]! ? credit.remaining : due[id]!;
        if (used > 0) {
          reduce(id, used, credit.source);
          credit.remaining -= used;
        }
      }
    }

    void applyCredit(
      String party,
      String source,
      int amount, {
      Map? manual,
      String? preferred,
    }) {
      var remaining = amount;
      final candidates = [
        if (preferred != null && due.containsKey(preferred)) preferred,
        ...order.where((id) => id != preferred),
      ];
      for (final id in candidates) {
        if (remaining <= 0) break;
        if (owners[id] != party ||
            due[id]! <= 0 ||
            (manual != null && !manual.containsKey(id))) {
          continue;
        }
        var used = remaining < due[id]! ? remaining : due[id]!;
        if (manual != null && integer(manual[id]) < used) {
          used = integer(manual[id]);
        }
        if (used > 0) {
          reduce(id, used, source);
          remaining -= used;
        }
      }
      if (remaining > 0) {
        credits.putIfAbsent(party, () => []).add(_Credit(source, remaining));
      }
    }

    for (final d in documents) {
      final target = '${d.data['target'] ?? ''}';
      final party = d.type == EntryType.adjustment && target.startsWith('ar:')
          ? target.substring(3)
          : d.party;
      if (party.isEmpty) continue;
      if (d.type == EntryType.sale) {
        addClaim(party, d.id, d.total, invoice: true);
      }
      if (d.type == EntryType.payment && d.data['supplierPayment'] != true) {
        addClaim(party, d.id, d.value('amount'));
      }
      if (d.type == EntryType.adjustment && target.startsWith('ar:')) {
        if (d.value('amount') > 0) {
          addClaim(party, d.id, d.value('amount'));
        } else {
          applyCredit(party, d.id, -d.value('amount'));
        }
      }
      if (d.type == EntryType.creditNote) {
        applyCredit(
          party,
          d.id,
          d.bill,
          preferred: '${d.data['sourceInvoice']}',
        );
      }
      final amount = switch (d.type) {
        EntryType.sale ||
        EntryType.receipt => d.data['supplierRefund'] == true ? 0 : d.collected,
        EntryType.discount => d.value('amount'),
        _ => 0,
      };
      if (amount > 0) {
        applyCredit(party, d.id, amount, manual: d.data['allocations'] as Map?);
      }
    }
  }

  List<Posting> ledger(String account) =>
      postings.where((p) => p.account == account).toList();
  int dayMovement(String date, String account) =>
      ledger(account)
          .where((p) => p.date == date)
          .fold(0, (v, p) => v + p.debit);
  List<String> get warnings => [
    if (gasGrams < 0) 'Negative gas stock',
    if (profitIncomplete) 'Profit is incomplete',
    if (full.values.any((v) => v < 0) || empty.values.any((v) => v < 0))
      'Check cylinder counts',
  ];
}

void validateDocument(Document d, List<Record> records) {
  if ([
        EntryType.sale,
        EntryType.creditNote,
        EntryType.purchase,
      ].contains(d.type) &&
      d.total.abs() > 9000000000000) {
    throw const FormatException('Number exceeds supported range');
  }
  for (final key in [
    'amount',
    'cash',
    'bank',
    'direct',
    'rate',
    'extraGrams',
    'grams',
    'cost',
    'depositCharge',
    'fullDelta',
    'emptyDelta',
    'heldDelta',
    'count',
    'occurredAt',
  ]) {
    if (d.value(key).abs() > 9000000000000) {
      throw const FormatException('Number exceeds supported range');
    }
  }
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d.date) ||
      DateTime.tryParse(d.date) == null ||
      DateTime.parse(d.date).toIso8601String().substring(0, 10) != d.date) {
    throw const FormatException('Choose a valid date');
  }
  final parties = records
      .where((r) => r.kind == 'party')
      .map((r) => r.id)
      .toSet();
  final accounts = records
      .where((r) => r.kind == 'account')
      .map((r) => r.id)
      .toSet();
  if ([
        EntryType.sale,
        EntryType.receipt,
        EntryType.payment,
        EntryType.purchase,
        EntryType.discount,
        EntryType.deposit,
        EntryType.depositRefund,
        EntryType.creditNote,
      ].contains(d.type) &&
      !parties.contains(d.party)) {
    throw const FormatException('Choose a party');
  }
  for (final key in [
    'cash',
    'bank',
    'direct',
    'rate',
    'extraGrams',
    'depositCharge',
    'cost',
  ]) {
    if (d.value(key) < 0) {
      throw const FormatException('Amounts and quantities cannot be negative');
    }
  }
  for (final key in ['quantities', 'returned']) {
    for (final value in ((d.data[key] as Map?) ?? {}).values) {
      if (integer(value) < 0 || integer(value) > 100000) {
        throw const FormatException('Cylinder counts cannot be negative');
      }
    }
  }
  if (d.value('bank') > 0 &&
      (!accounts.contains(d.bankAccount) || d.bankAccount == 'cash')) {
    throw const FormatException('Choose a bank account');
  }
  final rawLines = d.data['bankLines'];
  if (rawLines != null) {
    if (rawLines is! List || rawLines.length > 20) {
      throw const FormatException('Invalid bank lines');
    }
    for (final l in rawLines) {
      if (l is! Map ||
          l.keys.any(
            (k) =>
                !const ['amount', 'account', 'party', 'bankName'].contains(k),
          ) ||
          l['amount'] is! int ||
          l['amount'] <= 0 ||
          l['amount'] > 9000000000000 ||
          (l.containsKey('account') && l['account'] is! String) ||
          (l.containsKey('party') && l['party'] is! String) ||
          ((l['account'] is String && (l['account'] as String).isNotEmpty) ==
              (l['party'] is String && (l['party'] as String).isNotEmpty)) ||
          (l.containsKey('bankName') &&
              (l['bankName'] is! String ||
                  (l['bankName'] as String).length > 120))) {
        throw const FormatException('Invalid bank lines');
      }
    }
    if (rawLines.isNotEmpty &&
        (![EntryType.sale, EntryType.receipt].contains(d.type) ||
            d.data['supplierRefund'] == true)) {
      throw const FormatException('Invalid bank lines');
    }
  }
  if ('${d.data['directBank'] ?? ''}'.length > 120) {
    throw const FormatException('Invalid bank lines');
  }
  // Keep the legacy direct error, including a missing destination.
  if (d.value('direct') > 0 &&
      (![EntryType.sale, EntryType.receipt].contains(d.type) ||
          d.data['supplierRefund'] == true ||
          '${d.data['directParty'] ?? ''}' == d.party ||
          !parties.contains(d.data['directParty']))) {
    throw const FormatException('Choose the party that was paid directly');
  }
  for (final l in d.bankLines) {
    if (!l.direct && (!accounts.contains(l.account) || l.account == 'cash')) {
      throw const FormatException('Choose a bank account');
    }
    if (l.direct &&
        (l.party == d.party ||
            !records.any(
              (r) => r.kind == 'party' && r.id == l.party && !r.deleted,
            ))) {
      throw const FormatException('Choose the party that was paid directly');
    }
  }
  if ([
        EntryType.payment,
        EntryType.expense,
        EntryType.transfer,
        EntryType.purchase,
        EntryType.deposit,
        EntryType.depositRefund,
      ].contains(d.type) &&
      !accounts.contains(d.account)) {
    throw const FormatException('Choose a money account');
  }
  if (d.type == EntryType.sale && (d.bill <= 0 || d.rate <= 0)) {
    throw const FormatException('Enter a quantity and rate');
  }
  if (d.type == EntryType.receipt && d.collected <= 0) {
    throw const FormatException('Enter a collection amount');
  }
  if ([
        EntryType.payment,
        EntryType.expense,
        EntryType.transfer,
        EntryType.discount,
        EntryType.deposit,
        EntryType.depositRefund,
        EntryType.historicalSale,
      ].contains(d.type) &&
      d.value('amount') <= 0) {
    throw const FormatException('Enter an amount greater than zero');
  }
  if (d.type == EntryType.purchase &&
      (d.value('grams') <= 0 ||
          d.rate <= 0 ||
          ![1000, 11800, 1000000].contains(d.value('rateUnit')) ||
          d.value('amount') < 0)) {
    throw const FormatException('Enter purchase weight and rate');
  }
  if (d.type == EntryType.transfer &&
      (d.account == d.data['toAccount'] ||
          !accounts.contains(d.data['toAccount']))) {
    throw const FormatException('Choose a different destination account');
  }
  if ([
        EntryType.adjustment,
        EntryType.stockAdjustment,
        EntryType.cylinder,
        EntryType.creditNote,
      ].contains(d.type) &&
      d.note.trim().isEmpty) {
    throw const FormatException('A reason is required');
  }
  if (d.type == EntryType.adjustment) {
    final target = '${d.data['target']}';
    final valid = target.startsWith('money:')
        ? accounts.contains(target.substring(6))
        : (target.startsWith('ar:') ||
                  target.startsWith('ap:') ||
                  target.startsWith('deposit:')) &&
              parties.contains(target.substring(target.indexOf(':') + 1));
    if (!valid || d.value('amount') == 0) {
      throw const FormatException('Choose a balance and nonzero correction');
    }
  }
  if (d.type == EntryType.stockAdjustment &&
      (d.value('grams') == 0 ||
          (d.value('grams') < 0 && d.value('cost') != 0))) {
    throw const FormatException('Enter a valid stock correction');
  }
  if (d.type == EntryType.cylinder &&
      (!sizes.contains(d.value('size')) ||
          (d.value('fullDelta') == 0 &&
              d.value('emptyDelta') == 0 &&
              d.value('heldDelta') == 0))) {
    throw const FormatException('Enter cylinder count changes');
  }
  if (d.type == EntryType.cylinder &&
      d.value('heldDelta') != 0 &&
      !parties.contains(d.party)) {
    throw const FormatException('Choose a party');
  }
  if (d.data['allocations'] is Map) {
    var sum = 0;
    for (final entry in (d.data['allocations'] as Map).entries) {
      final invoice = records
          .where((r) => r.id == entry.key && r.kind == 'document')
          .firstOrNull;
      if (invoice == null ||
          invoice.data['type'] != 'sale' ||
          invoice.data['party'] != d.party ||
          invoice.data['voided'] == true ||
          integer(entry.value) < 0) {
        throw const FormatException('Invalid allocation');
      }
      sum += integer(entry.value);
    }
    if (sum > d.collected) {
      throw const FormatException('Allocation exceeds collection');
    }
  }
  if (d.type == EntryType.historicalSale &&
      (d.value('grams') <= 0 ||
          records
              .where((r) => r.kind == 'document' && r.id != d.id)
              .map(Document.new)
              .any(
                (v) =>
                    !v.voided &&
                    v.date == d.date &&
                    [EntryType.sale, EntryType.historicalSale].contains(v.type),
              ))) {
    throw const FormatException(
      'Historical summaries cannot overlap detailed sales',
    );
  }
  if (d.type == EntryType.creditNote) {
    final source = records
        .where((r) => r.id == d.data['sourceInvoice'] && r.kind == 'document')
        .firstOrNull;
    if (source == null ||
        source.data['type'] != 'sale' ||
        source.data['voided'] == true ||
        source.data['party'] != d.party ||
        d.date.compareTo('${source.data['date']}') < 0 ||
        records.any(
          (r) =>
              r.kind == 'document' &&
              r.id != d.id &&
              r.data['type'] == 'creditNote' &&
              r.data['voided'] != true &&
              r.data['sourceInvoice'] == source.id,
        )) {
      throw const FormatException(
        'Choose an invoice without an existing credit note',
      );
    }
    final original = Document(source);
    if (d.bill != original.bill ||
        d.cylinderGrams != original.cylinderGrams ||
        d.extraGrams != original.extraGrams) {
      throw const FormatException(
        'Credit note must match the original invoice',
      );
    }
  }
  if (d.type == EntryType.sale &&
      records
          .where((r) => r.kind == 'document')
          .map(Document.new)
          .any(
            (v) =>
                !v.voided &&
                v.date == d.date &&
                v.type == EntryType.historicalSale,
          )) {
    throw const FormatException(
      'Void the historical summary before adding detailed sales',
    );
  }
}

class _Credit {
  final String source;
  int remaining;
  _Credit(this.source, this.remaining);
}
