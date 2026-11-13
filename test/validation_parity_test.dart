// The client must reject what the server's khata_private.validate_document
// rejects, so a bad entry is refused when it is typed instead of coming back
// from the cloud later as a rejected change.
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';

const ali = Record('ali', 'party', {'name': 'Ali', 'customer': true});
const pso = Record('pso', 'party', {'name': 'PSO', 'supplier': true});
const gone = Record('gone', 'party', {'name': 'Gone', 'deleted': true});
const cash = Record('cash', 'account', {'name': 'Cash'});
const hbl = Record('hbl', 'account', {'name': 'HBL', 'bank': 'HBL'});
const masters = [ali, pso, gone, cash, hbl];

Document doc(Json data) => Document(
  Record('d', 'document', {'date': '2026-11-12', 'occurredAt': 1, ...data}),
);

void accepts(Json data, [List<Record> extra = const []]) =>
    validateDocument(doc(data), [...masters, ...extra]);

void rejects(Json data, String message, [List<Record> extra = const []]) =>
    expect(
      () => validateDocument(doc(data), [...masters, ...extra]),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', message),
      ),
    );

const expense = {'type': 'expense', 'amount': 10000, 'account': 'cash'};

void main() {
  test(
    'Purchase sharing requires a typed nonnegative cost and bulk quantity',
    () {
      const share = {
        'type': 'sale',
        'party': 'ali',
        'quantities': <String, int>{},
        'extraGrams': 1000,
        'bulkAtCost': true,
        'bulkCost': 30000,
      };
      accepts(share);
      accepts({...share, 'bulkCost': 0});
      for (final data in [
        {...share, 'bulkAtCost': 'true'},
        {...share, 'bulkCost': -1},
        {...share, 'bulkCost': 1.5},
        {...share}..remove('bulkCost'),
        {...share, 'extraGrams': 0},
        {...share, 'depositCharge': 100},
      ]) {
        rejects(data, 'Choose a valid purchase-share quantity and cost');
      }
    },
  );

  test('A share\'s chosen purchase must be a live purchase reference', () {
    const purchase = Record('ju', 'document', {
      'type': 'purchase',
      'date': '2026-11-02',
      'party': 'pso',
      'grams': 20000,
      'rate': 572000,
      'rateUnit': 11800,
      'account': 'cash',
      'reference': 'TX-JU',
    });
    const voided = Record('old', 'document', {
      'type': 'purchase',
      'date': '2026-11-01',
      'party': 'pso',
      'grams': 20000,
      'rate': 572000,
      'rateUnit': 11800,
      'account': 'cash',
      'reference': 'TX-OLD',
      'voided': true,
    });
    const share = {
      'type': 'sale',
      'party': 'ali',
      'quantities': <String, int>{},
      'extraGrams': 1000,
      'bulkAtCost': true,
      'bulkCost': 48500,
      'sharePurchase': 'TX-JU',
    };
    accepts(share, [purchase]);
    for (final data in [
      {...share, 'sharePurchase': 7},
      {...share, 'sharePurchase': ''},
      {...share, 'sharePurchase': 'x' * 121},
      {...share, 'sharePurchase': 'TX-NONE'},
      {...share, 'sharePurchase': 'TX-OLD'},
      {
        ...share,
        'bulkAtCost': false,
        'rate': 572000,
      }..remove('bulkCost'),
    ]) {
      rejects(data, 'Choose a purchase to share from', [purchase, voided]);
    }
    // A credit note must name the same purchase as its invoice.
    const invoice = Record('inv', 'document', {
      ...share,
      'date': '2026-11-12',
    });
    final credit = {
      ...share,
      'type': 'creditNote',
      'sourceInvoice': 'inv',
      'note': 'Returned',
    };
    accepts(credit, [purchase, invoice]);
    rejects(
      {...credit}..remove('sharePurchase'),
      'Credit note must match the original invoice',
      [purchase, invoice],
    );
  });

  test('A cylinder movement cannot have a negative quantity', () {
    const movement = {
      'type': 'cylinder',
      'size': 11800,
      'fullDelta': 1,
      'note': 'Filled',
    };
    accepts({...movement, 'count': 1});
    rejects({
      ...movement,
      'count': -1,
    }, 'Amounts and quantities cannot be negative');
  });

  test('Dates run from 2000-01-01 to 2100-12-31', () {
    accepts({...expense, 'date': '2000-01-01'});
    accepts({...expense, 'date': '2100-12-31'});
    rejects({...expense, 'date': '1999-12-31'}, 'Choose a valid date');
    rejects({...expense, 'date': '2101-01-01'}, 'Choose a valid date');
  });

  test('Any entry that names a party must name one that exists', () {
    accepts({...expense, 'party': ''});
    accepts({...expense, 'party': 'ali'});
    rejects({...expense, 'party': 'nobody'}, 'Choose a party');
    rejects({
      'type': 'stockAdjustment',
      'grams': 1000,
      'party': 'nobody',
      'note': 'Count',
    }, 'Choose a party');
  });

  test('Money paid directly cannot go to a deleted party', () {
    const receipt = {'type': 'receipt', 'party': 'ali', 'direct': 50000};
    accepts({...receipt, 'directParty': 'pso'});
    rejects({
      ...receipt,
      'directParty': 'gone',
    }, 'Choose the party that was paid directly');
  });

  test('A credit note repeats the invoice exactly', () {
    const invoice = Record('inv', 'document', {
      'type': 'sale',
      'date': '2026-11-12',
      'occurredAt': 1,
      'party': 'ali',
      'quantities': {'11800': 1},
      'rate': 460000,
    });
    const note = {
      'type': 'creditNote',
      'party': 'ali',
      'sourceInvoice': 'inv',
      'note': 'Returned',
      'quantities': {'11800': 1},
      'rate': 460000,
    };
    accepts(note, [invoice]);
    // Rs 4,600.01 bills the same whole rupees as Rs 4,600, but it is not the
    // invoice's rate; neither is a different list of cylinder sizes.
    rejects(
      {...note, 'rate': 460001},
      'Credit note must match the original invoice',
      [invoice],
    );
    rejects(
      {
        ...note,
        'quantities': {'11800': 1, '15000': 0},
      },
      'Credit note must match the original invoice',
      [invoice],
    );
  });

  test('Allocations are an invoice-to-amount map or absent', () {
    const receipt = {'type': 'receipt', 'party': 'ali', 'cash': 10000};
    accepts(receipt);
    rejects({...receipt, 'allocations': null}, 'Invalid allocation');
    rejects({...receipt, 'allocations': []}, 'Invalid allocation');
  });
}
