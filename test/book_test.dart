import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';

Record doc(
  String id,
  String type,
  Json data, {
  String date = '2026-11-07',
  int time = 1,
}) => Record(id, 'document', {
  'type': type,
  'date': date,
  'occurredAt': time,
  'party': 'p',
  ...data,
});
const party = Record('p', 'party', {
  'name': 'محمد علی',
  'customer': true,
  'supplier': true,
});
const cash = Record('cash', 'account', {'name': 'Cash'});
const bank = Record('b', 'account', {'name': 'HBL'});
void balanced(Book b) {
  for (final d in b.documents) {
    expect(
      b.postings
          .where((p) => p.document == d.id)
          .fold(0, (v, p) => v + p.debit),
      0,
      reason: d.id,
    );
  }
}

void main() {
  test('Receipts settle old opening debt before later invoices and advances retain their source', () {
    final b = Book([
      party,
      doc('opening', 'adjustment', {
        'target': 'ar:p',
        'amount': 100000,
      }, time: 0),
      doc('recover', 'receipt', {'cash': 50000}, time: 1),
      doc('invoice', 'sale', {
        'quantities': {'11800': 1},
        'rate': 460000,
        'customerOwned': true,
      }, time: 2),
    ]);
    expect(b.invoiceDue['invoice'], 460000);
    expect(b.receivable('p'), 510000);
    final advance = Book([
      party,
      doc('advance', 'receipt', {'cash': 500000}, time: 0),
      doc('invoice', 'sale', {
        'quantities': {'11800': 1},
        'rate': 460000,
        'customerOwned': true,
      }, time: 1),
    ]);
    expect(advance.invoiceDue['invoice'], 0);
    expect(advance.receiptAllocations['advance'], [('invoice', 460000)]);
    expect(advance.receivable('p'), -40000);
  });
  test('Credit note preserves collections, restores FIFO cost and leaves deposits as liabilities', () {
    final b = Book([
      party,
      cash,
      doc('lot', 'stockAdjustment', {
        'grams': 20000,
        'cost': 600000,
        'costKnown': true,
      }, time: 0),
      doc('invoice', 'sale', {
        'quantities': {'11800': 1},
        'returned': {'11800': 1},
        'rate': 460000,
        'cash': 560000,
        'depositCharge': 100000,
      }, time: 1),
      doc('credit', 'creditNote', {
        'sourceInvoice': 'invoice',
        'quantities': {'11800': 1},
        'rate': 460000,
        'stockReturned': true,
        'note': 'Gas returned',
      }, time: 2),
    ]);
    expect(b.money('cash'), 560000);
    expect(b.receivable('p'), -460000);
    expect(b.deposits('p'), 100000);
    expect(b.cylinderSales, 0);
    expect(b.costOfSales, 0);
    expect(b.gasGrams, 20000);
    expect(b.invoiceDue['invoice'], 0);
    balanced(b);
  });
  test('Credit note stock return requires established original cost', () {
    expect(
      () => Book([
        party,
        doc('invoice', 'sale', {
          'quantities': {'11800': 1},
          'rate': 460000,
        }, time: 1),
        doc('credit', 'creditNote', {
          'sourceInvoice': 'invoice',
          'quantities': {'11800': 1},
          'rate': 460000,
          'stockReturned': true,
        }, time: 2),
      ]),
      throwsFormatException,
    );
  });
  test('Decimal input is exact, including Urdu and signed amounts', () {
    expect(decimal('۱۲۳۴۵.۵۰', 2), 1234550);
    expect(decimal('-0.01', 2), -1);
    expect(decimal('1.18', 3), 1180);
    expect(() => decimal('1.234', 2), throwsFormatException);
    expect(() => decimal('NaN', 2), throwsFormatException);
    expect(() => decimal('999999999999999999999', 2), throwsFormatException);
    expect(
      multiplyDivide(9000000000000, 1000000000, 1000000000),
      9000000000000,
    );
  });
  test('Accepted fixture: extra KG is billed but excluded from stock and cylinder sales', () {
    final b = Book([
      party,
      cash,
      bank,
      doc('lot', 'stockAdjustment', {
        'grams': 20000,
        'cost': 600000,
        'costKnown': true,
      }, time: 0),
      doc('sale', 'sale', {
        'quantities': {'11800': 1},
        'returned': {'11800': 1},
        'extraGrams': 1180,
        'rate': 460000,
        'cash': 100000,
        'bank': 200000,
        'bankAccount': 'b',
      }),
    ]);
    expect(b.documents.last.bill, 506000);
    expect(b.cylinderSales, 460000);
    expect(b.extraBilling, 46000);
    expect(b.receivable('p'), 206000);
    expect(b.money('cash'), 100000);
    expect(b.money('b'), 200000);
    expect(b.gasGrams, 8200);
    expect(b.costOfSales, 354000);
    expect(b.profitIncomplete, isTrue);
    balanced(b);
  });
  test(
    'FIFO consumes oldest lot and rounding conserves complete lot costs',
    () {
      final b = Book([
        party,
        doc('l1', 'purchase', {
          'grams': 10000,
          'rate': 30000,
          'rateUnit': 1000,
        }, time: 0),
        doc('l2', 'purchase', {
          'grams': 10000,
          'rate': 32000,
          'rateUnit': 1000,
        }, time: 1),
        doc('s1', 'sale', {
          'quantities': {'11800': 1},
          'rate': 460000,
          'customerOwned': true,
        }, time: 2),
      ]);
      expect(b.costOfSales, 357600);
      expect(b.gasGrams, 8200);
      expect(b.grossProfit, 102400);
      expect(b.allocations.map((a) => a.lot), ['l1', 'l2']);
      expect(b.lots.last.cost, 262400);
      balanced(b);
    },
  );
  test(
    'Later purchase reserves deficit without reporting complete earlier profit',
    () {
      final b = Book([
        party,
        doc('sale', 'sale', {
          'quantities': {'11800': 1},
          'rate': 460000,
          'customerOwned': true,
        }, time: 0),
        doc('later', 'purchase', {
          'grams': 20000,
          'rate': 30000,
          'rateUnit': 1000,
        }, time: 1),
      ]);
      expect(b.gasGrams, 8200);
      expect(b.lots.single.grams, 8200);
      expect(b.lots.single.cost, 246000);
      expect(b.uncostedSales['sale'], 11800);
      expect(b.profitIncomplete, isTrue);
      balanced(b);
    },
  );
  test('Backdated lot resolves shortage deterministically', () {
    final b = Book([
      party,
      doc('sale', 'sale', {
        'quantities': {'11800': 1},
        'rate': 460000,
        'customerOwned': true,
      }, time: 3),
      doc('lot', 'purchase', {
        'grams': 20000,
        'rate': 30000,
        'rateUnit': 1000,
      }, time: 1),
    ]);
    expect(b.uncostedSales, isEmpty);
    expect(b.profitIncomplete, isFalse);
  });
  test('Transfers and bank expenses do not create cash income', () {
    final b = Book([
      cash,
      bank,
      doc('opening', 'adjustment', {'target': 'money:cash', 'amount': 1000000}),
      doc('deposit', 'transfer', {
        'account': 'cash',
        'toAccount': 'b',
        'amount': 300000,
      }, time: 2),
      doc('expense', 'expense', {
        'account': 'b',
        'category': 'Office',
        'amount': 50000,
      }, time: 3),
      doc('withdraw', 'transfer', {
        'account': 'b',
        'toAccount': 'cash',
        'amount': 100000,
      }, time: 4),
    ]);
    expect(b.money('cash'), 800000);
    expect(b.money('b'), 150000);
    expect(b.expenseTotal, 50000);
    balanced(b);
  });
  test('Supplier advances, purchases and refunds retain independent customer balance', () {
    final b = Book([
      party,
      cash,
      doc('advance', 'payment', {'supplierPayment': true, 'amount': 500000}),
      doc('purchase', 'purchase', {
        'grams': 10000,
        'rate': 30000,
        'rateUnit': 1000,
      }, time: 2),
      doc('refund', 'receipt', {
        'supplierRefund': true,
        'cash': 50000,
      }, time: 3),
      doc('loan', 'payment', {'amount': 100000}, time: 4),
      doc('recover', 'receipt', {'cash': 40000}, time: 5),
      doc('less', 'discount', {'amount': 10000}, time: 6),
    ]);
    expect(b.payable('p'), -150000);
    expect(b.receivable('p'), 50000);
    expect(b.money('cash'), -510000);
    balanced(b);
  });
  test('Discount is noncash and overpayment becomes customer credit', () {
    final b = Book([
      party,
      doc('s', 'sale', {
        'quantities': {'11800': 1},
        'rate': 460000,
        'cash': 500000,
        'customerOwned': true,
      }),
      doc('d', 'discount', {'amount': 10000}, time: 2),
    ]);
    expect(b.money('cash'), 500000);
    expect(b.receivable('p'), -50000);
    expect(b.invoiceDue['s'], 0);
    balanced(b);
  });
  test(
    'Exchanges, customer-owned refills and deposits are separate from revenue',
    () {
      final b = Book([
        party,
        doc('acq', 'cylinder', {'size': 11800, 'fullDelta': 10}, time: 0),
        doc('sale', 'sale', {
          'quantities': {'11800': 2},
          'returned': {'11800': 1},
          'rate': 460000,
          'depositCharge': 100000,
          'cash': 1020000,
        }, time: 1),
        doc('own', 'sale', {
          'quantities': {'11800': 1},
          'rate': 460000,
          'customerOwned': true,
        }, time: 2),
        doc('ret', 'cylinder', {
          'size': 11800,
          'emptyDelta': 1,
          'heldDelta': -1,
        }, time: 3),
        doc('refund', 'depositRefund', {'amount': 100000}, time: 4),
      ]);
      expect(b.full['11800'], 8);
      expect(b.empty['11800'], 2);
      expect(b.held['p:11800'], 0);
      expect(b.deposits('p'), 0);
      expect(b.cylinderSales, 1380000);
      balanced(b);
    },
  );
  test('Voids do not erase source and archives do not erase balances', () {
    final b = Book([
      Record(party.id, 'party', {...party.data, 'archived': true}),
      doc('old', 'receipt', {'cash': 100000, 'voided': true}),
      doc('new', 'receipt', {'cash': 200000, 'replaces': 'old'}, time: 2),
    ]);
    expect(b.receivable('p'), -200000);
    expect(b.documents.length, 1);
  });
  test(
    'Validation rejects malformed dates, negatives and overlapping summaries',
    () {
      expect(
        () => validateDocument(Document(doc('x', 'receipt', {'cash': -1})), [
          party,
          cash,
        ]),
        throwsFormatException,
      );
      expect(
        () => validateDocument(
          Document(
            doc('x', 'sale', {
              'quantities': {'11800': 1},
              'rate': 460000,
            }, date: '2026-02-31'),
          ),
          [party, cash],
        ),
        throwsFormatException,
      );
      expect(
        () => validateDocument(
          Document(
            doc('x', 'historicalSale', {'grams': 11800, 'amount': 460000}),
          ),
          [
            party,
            doc('sale', 'sale', {'rate': 460000}),
          ],
        ),
        throwsFormatException,
      );
    },
  );
}
