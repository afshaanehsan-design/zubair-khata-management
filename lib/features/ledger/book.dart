import 'dart:collection';

import '../../core/models.dart';

/// The account that a purchase share's FIFO cost and its recorded charge
/// meet in (see "Purchase sharing" in CLAUDE.md).
const shareCostAccount = 'purchase-share:cost';

/// Gas taken out before there was stock for it (a sale entered before its
/// purchase). It waits for the next stock and then takes its cost from it.
class _Demand {
  final Document document;
  final String account;
  int grams;
  _Demand(this.document, this.account, this.grams);
}

class Posting {
  final String document;
  final String date;
  final String account;
  final int debit;

  /// One of the pair that sets a party's two sides off against each other
  /// (see [Book.setOffs]). The pair adds nothing to the party's khata
  /// (`ar:` + `ap:`), so a khata statement leaves it out.
  final bool setOff;
  const Posting(
    this.document,
    this.date,
    this.account,
    this.debit, {
    this.setOff = false,
  });
}

class FifoAllocation {
  final String sale;
  final String lot;
  final int grams;
  final int cost;
  final String account;
  const FifoAllocation(
    this.sale,
    this.lot,
    this.grams,
    this.cost, {
    this.account = 'cogs',
  });
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
  final Set<String> verifyShares;
  final List<Document> documents = [];
  final List<Posting> postings = [];
  final Map<String, int> balances = {};
  final List<FifoAllocation> allocations = [];
  final List<StockLot> lots = [];
  final Map<String, int> full = {}, empty = {}, held = {};
  final Map<String, int> invoiceDue = {};
  final Map<String, List<(String, int)>> receiptAllocations = {};

  /// What each document set off between a party's two sides: document id →
  /// (party, amount), the amount taken off what the party owes you (`ar:`)
  /// and off what you owe it (`ap:`); negative when both went the other way
  /// (an advance on `ar:` against an overpaid `ap:`). After every document
  /// a party is owed on one side only, so a purchase from a customer who
  /// owes you lowers what he owes (asked for by the user on 17 November
  /// 2026). The server does the same in `khata_private.rebuild`.
  final Map<String, List<(String, int)>> setOffs = {};

  /// The bills a set-off settled, like [receiptAllocations]: document id →
  /// (invoice, amount).
  final Map<String, List<(String, int)>> setOffAllocations = {};

  /// Each party's `ar:` and `ap:` balance so far while documents are replayed.
  final Map<String, (int, int)> _sides = {};

  /// Grams of each document without a known cost: taken from a lot whose
  /// cost is unknown, or still waiting for stock (see [shortageGrams]).
  final Map<String, int> uncostedSales = {};

  /// The shared (at-cost) part of [uncostedSales], per purchase share.
  final Map<String, int> uncostedShares = {};

  /// The rest of [uncostedSales] (gas that is not a purchase share's) by
  /// where it stands: '' while it waits for stock (sold before its purchase
  /// was entered: negative stock), or the id of the lot of unknown cost it
  /// came from. Document id → source → grams. Profit counts these at the
  /// user's prices (`profit.dart`); nothing is posted for them.
  final Map<String, Map<String, int>> uncostedSources = {};

  /// FIFO cost of each purchase share's shared gas (negative on a credit
  /// note that returned it).
  final Map<String, int> shareCosts = {};
  int gasGrams = 0, cylinderSales = 0, extraBilling = 0, costOfSales = 0;

  /// Gas taken out before any stock covered it, waiting for the next stock.
  int shortageGrams = 0;
  final Queue<_Demand> _backorders = Queue();

  /// Live purchases by reference (the first in document order wins).
  final Map<String, Document> _purchaseByRef = {};

  /// Shares taken from a chosen purchase ([Document.sharePurchase]): the
  /// purchase each names, the KG it reserves there (that gas never enters
  /// our FIFO stock), that KG's part of the purchase bill, and any KG beyond
  /// what the purchase had left (taken by FIFO instead, see [shareExcess]).
  final Map<String, Document> _shareTarget = {};
  final Map<String, int> _reserved = {}, _reservedCost = {};
  final Map<String, List<String>> _purchaseShares = {};

  /// KG of a share beyond what its chosen purchase had left.
  final Map<String, int> shareExcess = {};
  final Map<String, StockLot> _lotOf = {};
  final Map<String, List<Document>> _waitingFor = {};

  static int _order(Document a, Document b) {
    final date = a.date.compareTo(b.date);
    if (date != 0) return date;
    final time = integer(a.data['occurredAt'])
        .compareTo(integer(b.data['occurredAt']));
    return time != 0 ? time : a.id.compareTo(b.id);
  }

  /// [verifyShares] names the documents being saved. A purchase share among
  /// them must be fully covered and charged exactly [shareChargeFor]; a
  /// purchase among them must not leave its shares short, nor be removed
  /// while shares still come from it.
  Book(this.records, {String? throughDate, this.verifyShares = const {}}) {
    final live =
        records
            .where((r) => r.kind == 'document')
            .map(Document.new)
            .where((d) => !d.voided)
            .toList()
          ..sort(_order);
    documents.addAll(
      live.where(
        (d) => throughDate == null || d.date.compareTo(throughDate) <= 0,
      ),
    );
    _reserveShares(live);
    for (final d in documents) {
      final start = postings.length;
      _project(d);
      _setOff(d, start);
    }
    // After every document: a share may take its stock from a later purchase.
    for (final id in verifyShares) {
      final r = records.where((r) => r.id == id).firstOrNull;
      if (r == null || r.kind != 'document') continue;
      final d = Document(r);
      if (d.type == EntryType.sale && d.bulkAtCost && !d.voided) {
        if (d.shareCharge != shareChargeFor(d)) {
          throw const FormatException(
            'Purchase-share cost changed; refresh the entry',
          );
        }
      } else if (d.type == EntryType.purchase && !d.voided) {
        if (shareExcess.keys.any((s) => _shareTarget[s]?.id == d.id)) {
          throw const FormatException('Shared KG exceed the selected purchase');
        }
      } else if (d.type == EntryType.purchase &&
          '${d.data['reference'] ?? ''}'.isNotEmpty &&
          !_purchaseByRef.containsKey(d.data['reference']) &&
          live.any(
            (s) =>
                s.type == EntryType.sale &&
                s.sharePurchase == d.data['reference'] &&
                !_returnedSales.contains(s.id),
          )) {
        throw const FormatException('Change the shares of this purchase first');
      }
    }
    _allocateReceipts();
    for (final p in postings) {
      balances.update(p.account, (v) => v + p.debit, ifAbsent: () => p.debit);
    }
  }

  /// Sales with a live credit note, and those whose gas it returned.
  final Set<String> _creditedSales = {}, _returnedSales = {};

  /// Decides, over every live document (not only those through a cut-off
  /// date, so a dated book agrees), how much each share reserves from its
  /// chosen purchase: shares in document order, each up to what is left.
  /// A share whose gas came back with a physical credit note reserves
  /// nothing (that gas is ours again). The cost of the reserved KG is the
  /// purchase bill split by KG, rounded on the running total so the shares
  /// and the rest of the purchase add up to its bill exactly.
  void _reserveShares(List<Document> live) {
    for (final d in live) {
      final reference = '${d.data['reference'] ?? ''}';
      if (d.type == EntryType.purchase && reference.isNotEmpty) {
        _purchaseByRef.putIfAbsent(reference, () => d);
      }
    }
    for (final d in live) {
      if (d.type != EntryType.creditNote) continue;
      _creditedSales.add('${d.data['sourceInvoice']}');
      if (d.data['stockReturned'] == true) {
        _returnedSales.add('${d.data['sourceInvoice']}');
      }
    }
    final taken = <String, int>{};
    for (final d in live) {
      if (d.type != EntryType.sale || d.sharePurchase.isEmpty) continue;
      if (_returnedSales.contains(d.id)) continue;
      final purchase = _purchaseByRef[d.sharePurchase];
      if (purchase == null) continue;
      _shareTarget[d.id] = purchase;
      final grams = purchase.value('grams'), used = taken[purchase.id] ?? 0;
      final left = grams - used > 0 ? grams - used : 0;
      final granted = d.extraGrams < left ? d.extraGrams : left;
      if (d.extraGrams > granted) shareExcess[d.id] = d.extraGrams - granted;
      if (granted <= 0) continue;
      taken[purchase.id] = used + granted;
      _reserved[d.id] = granted;
      _reservedCost[d.id] =
          multiplyDivide(purchase.purchaseBill, used + granted, grams) -
          multiplyDivide(purchase.purchaseBill, used, grams);
      _purchaseShares.putIfAbsent(purchase.id, () => []).add(d.id);
    }
  }

  /// What a purchase share should be charged: its chosen purchase's own
  /// rate for its KG (rounded to whole rupees like that purchase's bill),
  /// or, sharing oldest stock first, its FIFO cost rounded to whole rupees.
  /// Throws when that cannot be known yet.
  int shareChargeFor(Document d) {
    if (d.sharePurchase.isNotEmpty) {
      final purchase = _shareTarget[d.id] ?? _purchaseByRef[d.sharePurchase];
      if (purchase == null) {
        throw const FormatException('Choose a purchase to share from');
      }
      if (purchase.isDraft && purchase.rate == 0) {
        throw const FormatException('Enter stock cost');
      }
      if ((shareExcess[d.id] ?? 0) > 0) {
        throw const FormatException('Shared KG exceed the selected purchase');
      }
      return purchase.purchaseBillFor(d.extraGrams);
    }
    if ((uncostedShares[d.id] ?? 0) > 0) {
      throw const FormatException(
        'Enter dated stock and purchase cost before sharing gas',
      );
    }
    return roundRupees(shareCosts[d.id] ?? 0);
  }

  /// The live purchase with [reference], if any.
  Document? purchaseByReference(String reference) => _purchaseByRef[reference];

  /// KG of [purchase] not yet taken by shares, leaving out the share [except]
  /// (the entry being corrected).
  int purchaseFree(Document purchase, {String? except}) =>
      purchase.value('grams') -
      _shareTarget.entries
          .where((e) => e.value.id == purchase.id && e.key != except)
          .fold(
            0,
            (v, e) => v + (_reserved[e.key] ?? 0) + (shareExcess[e.key] ?? 0),
          );

  void _line(Document d, String account, int debit) {
    if (debit != 0) postings.add(Posting(d.id, d.date, account, debit));
  }

  void _pair(Document d, String debit, String credit, int amount) {
    _line(d, debit, amount);
    _line(d, credit, -amount);
  }

  /// After [d] (whose postings start at [start]): every party whose two
  /// sides now point opposite ways, owing you on one and owed by you on the
  /// other, has the smaller set off against the larger, under [d] and on
  /// its date. The khata balance (`ar:` + `ap:`) does not change; only one
  /// side is left. Postings of other documents made while [d] was replayed
  /// (FIFO cost of gas that waited) never touch a party account.
  void _setOff(Document d, int start) {
    final moved = <String, (int, int)>{};
    for (final p in postings.skip(start)) {
      if (p.document != d.id) continue;
      final receivable = p.account.startsWith('ar:');
      if (!receivable && !p.account.startsWith('ap:')) continue;
      final party = p.account.substring(3);
      final (ar, ap) = moved[party] ?? (0, 0);
      moved[party] = receivable ? (ar + p.debit, ap) : (ar, ap + p.debit);
    }
    for (final MapEntry(key: party, value: (ar, ap)) in moved.entries) {
      var (receivable, payable) = _sides[party] ?? (0, 0);
      receivable += ar;
      payable += ap;
      // `payable` is the `ap:` balance itself: negative when you owe.
      final amount = receivable > 0 && payable < 0
          ? (receivable < -payable ? receivable : -payable)
          : receivable < 0 && payable > 0
          ? -(-receivable < payable ? -receivable : payable)
          : 0;
      if (amount != 0) {
        postings
          ..add(Posting(d.id, d.date, 'ap:$party', amount, setOff: true))
          ..add(Posting(d.id, d.date, 'ar:$party', -amount, setOff: true));
        setOffs.putIfAbsent(d.id, () => []).add((party, amount));
        receivable -= amount;
        payable += amount;
      }
      _sides[party] = (receivable, payable);
    }
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

  /// The money in every bank account together (the Money page's Total bank):
  /// every money account but cash, archived ones included, so the total for
  /// an earlier day counts an account archived since.
  int get bankMoney => balances.entries
      .where((e) => e.key.startsWith('money:') && e.key != 'money:cash')
      .fold(0, (v, e) => v + e.value);
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
  int get grossProfit => cylinderSales + extraBilling - costOfSales;
  bool get profitIncomplete =>
      documents.any((d) => d.isDraft) ||
      uncostedSales.isNotEmpty ||
      lots.any((l) => l.cost == null && l.grams > 0) ||
      documents.any((d) => d.type == EntryType.historicalSale);

  /// Lots before this one are used up for good (a lot only ever loses gas),
  /// so taking gas starts here instead of at the first purchase.
  int _firstLot = 0;

  /// Gives [d] [grams] of [lot] at [cost]: a FIFO allocation and its
  /// postings, always under [d]'s own id (so reports by entry count it with
  /// the sale), dated [date]: the sale's own date, or the day the stock came
  /// for gas that waited. A closed day's postings therefore never change.
  void _allocate(
    Document d,
    String date,
    String account,
    StockLot lot,
    int grams,
    int cost,
  ) {
    allocations.add(
      FifoAllocation(d.id, lot.id, grams, cost, account: account),
    );
    // A stock loss is an expense (posted below), not a cost of sales.
    final loss = d.type == EntryType.stockAdjustment;
    if (!loss && account == 'cogs') costOfSales += cost;
    if (account == shareCostAccount) {
      shareCosts.update(d.id, (v) => v + cost, ifAbsent: () => cost);
    }
    if (cost != 0) {
      postings
        ..add(Posting(d.id, date, loss ? 'expense:Stock loss' : account, cost))
        ..add(Posting(d.id, date, 'inventory', -cost));
    }
  }

  /// What the shared bulk of a new entry placed after every document would
  /// cost, read from the current lots without changing them (cylinders are
  /// taken first). Only valid while nothing waits for stock; throws when the
  /// lots cannot cover it at a known cost. The full projection gives the
  /// same number ([AppController.quoteBulkCost] uses this as a fast path).
  int quoteAtEnd(int cylinders, int bulk) {
    assert(shortageGrams == 0);
    var cylinderRemaining = cylinders, sharedRemaining = bulk, total = 0;
    for (final lot in lots.skip(_firstLot)) {
      if (sharedRemaining <= 0) break;
      if (lot.grams <= 0) continue;
      var grams = lot.grams, cost = lot.cost;
      final used = cylinderRemaining < grams ? cylinderRemaining : grams;
      if (used > 0) {
        if (cost != null) cost -= multiplyDivide(cost, used, grams);
        grams -= used;
        cylinderRemaining -= used;
      }
      if (grams > 0 && cylinderRemaining == 0) {
        if (cost == null) {
          throw const FormatException(
            'Enter dated stock and purchase cost before sharing gas',
          );
        }
        final shared = sharedRemaining < grams ? sharedRemaining : grams;
        total += multiplyDivide(cost, shared, grams);
        sharedRemaining -= shared;
      }
    }
    if (sharedRemaining > 0) {
      throw const FormatException(
        'Enter dated stock and purchase cost before sharing gas',
      );
    }
    return total;
  }

  /// [grams] of [d]'s gas have no known cost: they wait for stock, or came
  /// from the lot [source] of unknown cost.
  void _uncosted(Document d, String account, int grams, {String source = ''}) {
    uncostedSales.update(d.id, (v) => v + grams, ifAbsent: () => grams);
    if (account == shareCostAccount) {
      uncostedShares.update(d.id, (v) => v + grams, ifAbsent: () => grams);
    } else {
      _source(d.id, source, grams);
    }
  }

  void _source(String id, String source, int grams) {
    final sources = uncostedSources.putIfAbsent(id, () => {});
    final left = (sources[source] ?? 0) + grams;
    if (left == 0) {
      sources.remove(source);
    } else {
      sources[source] = left;
    }
    if (sources.isEmpty) uncostedSources.remove(id);
  }

  /// [grams] of [d]'s gas that waited for stock got their cost, or stopped
  /// waiting because a credit note returned them.
  void _costed(Document d, String account, int grams) {
    for (final map in [
      uncostedSales,
      if (account == shareCostAccount) uncostedShares,
    ]) {
      final left = map[d.id]! - grams;
      if (left == 0) {
        map.remove(d.id);
      } else {
        map[d.id] = left;
      }
    }
    if (account != shareCostAccount) _source(d.id, '', -grams);
  }

  void _stockOut(Document d, int grams, {String account = 'cogs'}) {
    gasGrams -= grams;
    var remaining = grams;
    while (_firstLot < lots.length && lots[_firstLot].grams <= 0) {
      _firstLot++;
    }
    for (final lot in lots.skip(_firstLot)) {
      if (remaining <= 0) break;
      if (lot.grams <= 0) continue;
      final used = remaining < lot.grams ? remaining : lot.grams;
      if (lot.cost == null) {
        _uncosted(d, account, used, source: lot.id);
      } else {
        final cost = multiplyDivide(lot.cost!, used, lot.grams);
        lot.cost = lot.cost! - cost;
        _allocate(d, d.date, account, lot, used, cost);
      }
      lot.grams -= used;
      remaining -= used;
    }
    if (remaining > 0) {
      // No stock yet: the gas waits for the next stock, oldest first.
      shortageGrams += remaining;
      _uncosted(d, account, remaining);
      _backorders.add(_Demand(d, account, remaining));
    }
  }

  void _stockIn(Document d, int grams, int? cost) {
    final lot = StockLot(d.id, d.date, grams, cost);
    lots.add(lot);
    // New stock first covers what went out before it arrived, oldest first,
    // at this lot's cost, the same way a later sale would take it. Gas from
    // a lot of unknown cost stays uncosted, but no longer waits.
    while (_backorders.isNotEmpty && lot.grams > 0) {
      final demand = _backorders.first;
      final used = demand.grams < lot.grams ? demand.grams : lot.grams;
      if (lot.cost != null) {
        final part = multiplyDivide(lot.cost!, used, lot.grams);
        lot.cost = lot.cost! - part;
        _allocate(demand.document, d.date, demand.account, lot, used, part);
        _costed(demand.document, demand.account, used);
      } else if (demand.account != shareCostAccount) {
        // Still without a cost, but now from this lot instead of waiting.
        _source(demand.document.id, '', -used);
        _source(demand.document.id, lot.id, used);
      }
      lot.grams -= used;
      demand.grams -= used;
      shortageGrams -= used;
      if (demand.grams == 0) _backorders.removeFirst();
    }
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
        if (d.bulkAtCost) _line(d, shareCostAccount, -d.shareCharge);
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
        if (d.bulkAtCost) {
          // Cylinders first, then the shared bulk from the stock after them.
          // A share without stock waits for the next stock like any sale;
          // only a share being saved must be covered (checked after all).
          _stockOut(d, d.cylinderGrams);
          final reserved = _reserved[d.id] ?? 0;
          if (reserved > 0) {
            gasGrams -= reserved;
            final purchase = _shareTarget[d.id]!;
            final lot = _lotOf[purchase.id];
            if (lot != null) {
              _allocate(
                d,
                d.date,
                shareCostAccount,
                lot,
                reserved,
                _reservedCost[d.id]!,
              );
            } else {
              // Its purchase comes later (or after this book's date).
              _uncosted(d, shareCostAccount, reserved);
              _waitingFor.putIfAbsent(purchase.id, () => []).add(d);
            }
          }
          _stockOut(d, d.extraGrams - reserved, account: shareCostAccount);
        } else {
          _stockOut(d, d.saleGrams);
        }
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
      case EntryType.purchase:
        _pair(d, 'inventory', 'ap:${d.party}', d.purchaseBill);
        _pair(d, 'ap:${d.party}', 'money:${d.account}', amount);
        gasGrams += d.value('grams');
        // KG reserved by shares from this purchase never become our stock.
        final shares = _purchaseShares[d.id] ?? const <String>[];
        _stockIn(
          d,
          d.value('grams') - shares.fold(0, (v, s) => v + _reserved[s]!),
          d.isDraft && d.rate == 0
              ? null
              : d.purchaseBill -
                    shares.fold(0, (v, s) => v + _reservedCost[s]!),
        );
        final lot = _lotOf[d.id] = lots.last;
        for (final share in _waitingFor.remove(d.id) ?? const <Document>[]) {
          _allocate(
            share,
            d.date,
            shareCostAccount,
            lot,
            _reserved[share.id]!,
            _reservedCost[share.id]!,
          );
          _costed(share, shareCostAccount, _reserved[share.id]!);
        }
      case EntryType.transfer:
        _pair(d, 'money:${d.data['toAccount']}', 'money:${d.account}', amount);
      case EntryType.discount:
        _pair(d, 'expense:Write-off', 'ar:${d.party}', amount);
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
        if (original.bulkAtCost) {
          _line(d, shareCostAccount, original.shareCharge);
        }
        _line(d, 'ar:${d.party}', -original.bill);
        final sourceCosts = allocations.where((a) => a.sale == original.id);
        final cost = sourceCosts.fold(0, (v, a) => v + a.cost);
        final sharedCost = sourceCosts
            .where((a) => a.account == shareCostAccount)
            .fold(0, (v, a) => v + a.cost);
        if (d.data['stockReturned'] == true) {
          // Gas of the invoice still waiting for stock comes back before any
          // stock covered it: it stops waiting and is not returned as a lot.
          var cancelled = 0;
          _backorders.removeWhere((demand) {
            if (demand.document.id != original.id) return false;
            cancelled += demand.grams;
            _costed(demand.document, demand.account, demand.grams);
            return true;
          });
          shortageGrams -= cancelled;
          // What is left uncosted came from stock of unknown cost.
          final unknownCost = uncostedSales.containsKey(original.id);
          if (unknownCost && !documents.any((d) => d.isDraft)) {
            throw const FormatException(
              'Record the missing purchase cost before returning stock',
            );
          }
          _pair(d, 'inventory', 'cogs', cost - sharedCost);
          _pair(d, 'inventory', shareCostAccount, sharedCost);
          if (original.bulkAtCost) shareCosts[d.id] = -sharedCost;
          costOfSales -= cost - sharedCost;
          gasGrams += original.saleGrams;
          if (original.saleGrams > cancelled) {
            _stockIn(
              d,
              original.saleGrams - cancelled,
              unknownCost ? null : cost,
            );
          }
        } else if (original.bulkAtCost) {
          // The charge is cancelled but the shared gas is gone: like any
          // financial credit note, its cost becomes our cost of gas sold.
          _pair(d, 'cogs', shareCostAccount, sharedCost);
          costOfSales += sharedCost;
          shareCosts[d.id] = -sharedCost;
        }
    }
  }

  void _allocateReceipts() {
    // Each party's claims in the order they arose. What is due on a claim
    // only ever goes down, so the claims before `firstOpen[party]` are
    // settled for good and a payment starts at the first open one. (Looking
    // through every party's claims for each payment made a save take
    // minutes once a khata held tens of thousands of entries.)
    final claims = <String, List<String>>{};
    final firstOpen = <String, int>{};
    final due = <String, int>{},
        owners = <String, String>{},
        invoices = <String>{};
    // Each party's advances that still have money left, oldest first.
    final credits = <String, List<_Credit>>{};
    void reduce(String claim, int amount, String source, bool setOff) {
      due[claim] = due[claim]! - amount;
      if (invoices.contains(claim)) {
        invoiceDue[claim] = due[claim]!;
        (setOff ? setOffAllocations : receiptAllocations)
            .putIfAbsent(source, () => [])
            .add((claim, amount));
      }
    }

    void addClaim(String party, String id, int amount, {bool invoice = false}) {
      claims.putIfAbsent(party, () => []).add(id);
      owners[id] = party;
      due[id] = amount;
      if (invoice) {
        invoices.add(id);
        invoiceDue[id] = amount;
      }
      final open = credits[party];
      if (open == null) return;
      for (final credit in open) {
        final used = credit.remaining < due[id]! ? credit.remaining : due[id]!;
        if (used > 0) {
          reduce(id, used, credit.source, credit.setOff);
          credit.remaining -= used;
        }
      }
      open.removeWhere((c) => c.remaining <= 0);
    }

    void applyCredit(
      String party,
      String source,
      int amount, {
      Map? manual,
      String? preferred,
      bool setOff = false,
    }) {
      var remaining = amount;
      void settle(String id) {
        if (owners[id] != party ||
            due[id]! <= 0 ||
            (manual != null && !manual.containsKey(id))) {
          return;
        }
        var used = remaining < due[id]! ? remaining : due[id]!;
        if (manual != null && integer(manual[id]) < used) {
          used = integer(manual[id]);
        }
        if (used > 0) {
          reduce(id, used, source, setOff);
          remaining -= used;
        }
      }

      if (preferred != null && due.containsKey(preferred) && remaining > 0) {
        settle(preferred);
      }
      final list = claims[party] ?? const <String>[];
      var start = firstOpen[party] ?? 0;
      while (start < list.length && due[list[start]]! <= 0) {
        start++;
      }
      firstOpen[party] = start;
      for (var i = start; i < list.length && remaining > 0; i++) {
        if (list[i] != preferred) settle(list[i]);
      }
      if (remaining > 0) {
        credits
            .putIfAbsent(party, () => [])
            .add(_Credit(source, remaining, setOff: setOff));
      }
    }

    void own(Document d) {
      final target = '${d.data['target'] ?? ''}';
      final party = d.type == EntryType.adjustment && target.startsWith('ar:')
          ? target.substring(3)
          : d.party;
      if (party.isEmpty) return;
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

    for (final d in documents) {
      own(d);
      // A set-off pays the party's oldest bills like a collection; one the
      // other way (an advance used up against an overpaid company) is a
      // claim like a payment to the customer.
      for (final (party, amount) in setOffs[d.id] ?? const <(String, int)>[]) {
        if (amount > 0) {
          applyCredit(party, d.id, amount, setOff: true);
        } else {
          addClaim(party, '${d.id}#set-off:$party', -amount);
        }
      }
    }
  }

  List<Posting> ledger(String account) =>
      postings.where((p) => p.account == account).toList();

  /// The documents this book replayed, by id (built when first asked).
  late final Map<String, Document> byId = {for (final d in documents) d.id: d};

  /// Each document's postings, in order (built when first asked): what it
  /// posted itself and, for gas that waited, the cost the stock gave it.
  late final Map<String, List<Posting>> postingsOf = () {
    final map = <String, List<Posting>>{};
    for (final p in postings) {
      map.putIfAbsent(p.document, () => []).add(p);
    }
    return map;
  }();

  int dayMovement(String date, String account) =>
      ledger(account)
          .where((p) => p.date == date)
          .fold(0, (v, p) => v + p.debit);
  List<String> get warnings => [
    if (gasGrams < 0) 'Negative gas stock',
    if (profitIncomplete) 'Profit is incomplete',
    if (uncostedShares.isNotEmpty)
      'Shared gas is waiting for purchase stock'
    // A share's charge is its cost rounded to whole rupees, and proportional
    // rounding moves a FIFO cost by a few paisa when an earlier entry
    // changes: only a difference of a rupee or more on one share is a
    // change worth a warning (the Purchase shares report shows them all).
    else if (documents.any(
      (d) =>
          d.type == EntryType.sale &&
          d.bulkAtCost &&
          !_creditedSales.contains(d.id) &&
          ((shareCosts[d.id] ?? 0) - d.shareCharge).abs() >= 100,
    ))
      'Purchase share cost changed; review purchase shares',
    // No warning for negative full/empty counts: the business buys and
    // sells gas by KG and never records fills, so those counts always go
    // negative and mean nothing (hidden from the UI on 13 November 2026).
  ];
}

void validateDocument(Document d, List<Record> records) {
  if ((d.data.containsKey('bulkAtCost') && d.data['bulkAtCost'] is! bool) ||
      (d.data.containsKey('bulkCost') &&
          (d.data['bulkCost'] is! int || d.value('bulkCost') < 0)) ||
      (d.bulkAtCost &&
          (![EntryType.sale, EntryType.creditNote].contains(d.type) ||
              d.extraGrams <= 0 ||
              d.data['bulkCost'] is! int ||
              (d.cylinderGrams == 0 && d.value('depositCharge') != 0)))) {
    throw const FormatException(
      'Choose a valid purchase-share quantity and cost',
    );
  }
  // The purchase a share comes from, by its reference: a live purchase when
  // a sale is saved (a credit note copies its invoice's, checked below).
  if (d.data.containsKey('sharePurchase')) {
    final reference = d.data['sharePurchase'];
    if (reference is! String ||
        reference.isEmpty ||
        reference.length > 120 ||
        !d.bulkAtCost ||
        (d.type == EntryType.sale &&
            !records.any(
              (r) =>
                  r.kind == 'document' &&
                  r.data['type'] == 'purchase' &&
                  r.data['voided'] != true &&
                  r.data['reference'] == reference,
            ))) {
      throw const FormatException('Choose a purchase to share from');
    }
  }
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
    'bulkCost',
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
  // The server accepts the same years (khata_private.validate_document).
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d.date) ||
      DateTime.tryParse(d.date) == null ||
      DateTime.parse(d.date).toIso8601String().substring(0, 10) != d.date ||
      d.date.compareTo('2000-01-01') < 0 ||
      d.date.compareTo('2100-12-31') > 0) {
    throw const FormatException('Choose a valid date');
  }
  final parties = records
      .where((r) => r.kind == 'party')
      .map((r) => r.id)
      .toSet();
  final liveParties = records
      .where((r) => r.kind == 'party' && !r.deleted)
      .map((r) => r.id)
      .toSet();
  final accounts = records
      .where((r) => r.kind == 'account')
      .map((r) => r.id)
      .toSet();
  // Any entry that names a party must name one that exists.
  if ((d.party.isNotEmpty ||
          [
            EntryType.sale,
            EntryType.receipt,
            EntryType.payment,
            EntryType.purchase,
            EntryType.discount,
            EntryType.deposit,
            EntryType.depositRefund,
            EntryType.creditNote,
          ].contains(d.type)) &&
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
    'count',
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
          !liveParties.contains(d.data['directParty']))) {
    throw const FormatException('Choose the party that was paid directly');
  }
  for (final l in d.bankLines) {
    if (!l.direct && (!accounts.contains(l.account) || l.account == 'cash')) {
      throw const FormatException('Choose a bank account');
    }
    if (l.direct && (l.party == d.party || !liveParties.contains(l.party))) {
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
  if (d.type == EntryType.sale &&
      (d.saleGrams <= 0 ||
          (!d.purchaseShare && (d.bill <= 0 || d.rate <= 0)))) {
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
  if (d.data.containsKey('allocations') && d.data['allocations'] is! Map) {
    throw const FormatException('Invalid allocation');
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
    // The same cylinders, rate and extra KG as the invoice, as the server
    // checks them.
    final original = Document(source);
    if (canonicalJson(d.data['quantities']) !=
            canonicalJson(source.data['quantities']) ||
        d.rate != original.rate ||
        d.extraGrams != original.extraGrams ||
        d.bulkAtCost != original.bulkAtCost ||
        // The raw fields, as the server compares them.
        d.value('bulkCost') != original.value('bulkCost') ||
        '${d.data['sharePurchase'] ?? ''}' !=
            '${source.data['sharePurchase'] ?? ''}') {
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
  final bool setOff;
  int remaining;
  _Credit(this.source, this.remaining, {this.setOff = false});
}
