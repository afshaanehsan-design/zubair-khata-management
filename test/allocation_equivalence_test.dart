// Book settles receipts against invoices per party, starting at the first
// unpaid claim, so a save no longer slows down with the square of the khata's
// size. This checks that it settles exactly what the original algorithm
// (kept below as the reference) settled, on many random khatas.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';

class _Credit {
  final String source;
  int remaining;
  _Credit(this.source, this.remaining);
}

/// The allocation as it was before 12 November 2026: every payment looked
/// through every party's claims.
(Map<String, int>, Map<String, List<(String, int)>>) reference(
  List<Document> documents,
) {
  final invoiceDue = <String, int>{};
  final receiptAllocations = <String, List<(String, int)>>{};
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
      applyCredit(party, d.id, d.bill, preferred: '${d.data['sourceInvoice']}');
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
  return (invoiceDue, receiptAllocations);
}

/// A random khata: a few customers, sales paid in part, in full or not at
/// all, receipts (some split by hand over invoices), payouts, opening
/// balances either way, discounts and credit notes.
List<Record> randomKhata(Random r) {
  final parties = [for (var i = 0; i < 1 + r.nextInt(4); i++) 'p$i'];
  final records = <Record>[
    for (final p in parties) Record(p, 'party', {'name': p}),
    const Record('cash', 'account', {'name': 'Cash'}),
    const Record('b', 'account', {'name': 'HBL', 'bank': 'HBL'}),
  ];
  final sales = <String, List<Json>>{};
  final credited = <String>{};
  for (var i = 0; i < 20 + r.nextInt(80); i++) {
    final party = parties[r.nextInt(parties.length)];
    final id = 'd${i.toString().padLeft(3, '0')}';
    final base = {
      'date': '2026-11-0${1 + r.nextInt(5)}',
      'occurredAt': r.nextInt(4) == 0 ? 0 : 1 + r.nextInt(1000),
      'party': party,
    };
    final Json data;
    final kind = r.nextInt(9);
    final open = (sales[party] ?? [])
        .where((s) => !credited.contains(s['id']))
        .toList();
    if (kind <= 2) {
      final count = 1 + r.nextInt(3);
      data = {
        'type': 'sale',
        'quantities': {'11800': count},
        'rate': 460000,
        'cash': [0, 100000, count * 460000, count * 600000][r.nextInt(4)],
        if (r.nextInt(4) == 0) ...{'bank': 50000, 'bankAccount': 'b'},
      };
      sales.putIfAbsent(party, () => []).add({'id': id, ...data});
    } else if (kind == 3 || (kind == 8 && open.isEmpty)) {
      final cash = (1 + r.nextInt(30)) * 50000;
      final hand = sales[party] ?? [];
      data = {
        'type': 'receipt',
        'cash': cash,
        if (r.nextInt(3) == 0 && hand.isNotEmpty)
          'allocations': {
            for (final s in hand.reversed.take(1 + r.nextInt(2)))
              s['id']: r.nextInt(cash + 1),
          },
      };
    } else if (kind == 4) {
      data = {
        'type': 'payment',
        'amount': (1 + r.nextInt(10)) * 20000,
        'account': 'cash',
      };
    } else if (kind == 5 || kind == 6) {
      data = {
        'type': 'adjustment',
        'target': 'ar:$party',
        'amount': (r.nextBool() ? 1 : -1) * (1 + r.nextInt(10)) * 100000,
        'note': 'Opening balance',
      };
    } else if (kind == 7) {
      data = {'type': 'discount', 'amount': (1 + r.nextInt(5)) * 10000};
    } else {
      final source = open[r.nextInt(open.length)];
      credited.add('${source['id']}');
      data = {
        'type': 'creditNote',
        'sourceInvoice': source['id'],
        'quantities': source['quantities'],
        'rate': source['rate'],
        'note': 'Returned',
      };
    }
    records.add(Record(id, 'document', {...base, ...data}));
  }
  return records;
}

void main() {
  test('Settles exactly what the original algorithm settled', () {
    var settled = 0, manual = 0, notes = 0;
    for (var seed = 0; seed < 300; seed++) {
      final book = Book(randomKhata(Random(seed)));
      final (due, allocations) = reference(book.documents);
      expect(book.invoiceDue, due, reason: 'seed $seed');
      expect(book.receiptAllocations, allocations, reason: 'seed $seed');
      settled += allocations.length;
      manual += book.documents
          .where((d) => d.data['allocations'] != null)
          .length;
      notes += book.documents
          .where((d) => d.type == EntryType.creditNote)
          .length;
    }
    // The khatas really exercised every path.
    expect(settled, greaterThan(3000));
    expect(manual, greaterThan(200));
    expect(notes, greaterThan(200));
  });
}
