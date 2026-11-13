import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';

Record doc(String id, String type, Json data, {int time = 1}) =>
    Record(id, 'document', {
      'type': type,
      'date': '2026-11-12',
      'party': 'p',
      'occurredAt': time,
      ...data,
    });

Record stock(int grams, int cost) => doc('opening', 'stockAdjustment', {
  'grams': grams,
  'cost': cost,
  'costKnown': true,
}, time: 0);

void balanced(Book book) {
  for (final d in book.documents) {
    expect(
      book.postings
          .where((p) => p.document == d.id)
          .fold(0, (sum, p) => sum + p.debit),
      0,
      reason: d.id,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Bulk-only sale consumes FIFO stock without moving cylinders', () {
    final book = Book([
      stock(20000, 600000),
      doc('bulk', 'sale', {
        'extraGrams': 1180,
        'rate': 460000,
        'cash': 10000,
        'bank': 20000,
        'bankAccount': 'b',
      }),
    ]);
    expect(book.gasGrams, 18820);
    expect(book.costOfSales, 35400);
    expect(book.balance('inventory'), 564600);
    expect(book.cylinderSales, 0);
    expect(book.extraBilling, 46000);
    expect(book.grossProfit, 10600);
    expect(book.profitIncomplete, isFalse);
    expect(book.receivable('p'), 16000);
    expect(book.money('cash'), 10000);
    expect(book.money('b'), 20000);
    expect(book.full.values.every((n) => n == 0), isTrue);
    expect(book.empty.values.every((n) => n == 0), isTrue);
    expect(book.held.values.every((n) => n == 0), isTrue);
    expect(book.allocations.single.grams, 1180);
    final day = RoznamchaDay('2026-11-12', 0, book.documents);
    expect(day.gasOut, 1180);
    expect(day.dispatchGrams, 1180);
    expect(day.cylinderGrams, 0);
    expect(day.safi, book.money('cash'));
    balanced(book);
  });

  test(
    'Mixed sale consumes whole FIFO lots once and conserves rounded cost',
    () {
      final book = Book([
        stock(10000, 300001),
        doc('second', 'purchase', {
          'grams': 10000,
          'rate': 32000,
          'rateUnit': 1000,
        }, time: 1),
        doc('mixed', 'sale', {
          'quantities': {'11800': 1},
          'extraGrams': 8200,
          'rate': 460000,
          'customerOwned': true,
        }, time: 2),
      ]);
      expect(book.gasGrams, 0);
      expect(book.costOfSales, 620001);
      expect(book.balance('inventory'), 0);
      expect(book.allocations.map((a) => a.grams), [10000, 10000]);
      expect(book.allocations.map((a) => a.cost), [300001, 320000]);
      expect(book.grossProfit, book.documents.last.bill - 620001);
      expect(book.profitIncomplete, isFalse);
      balanced(book);
    },
  );

  for (final cylinders in [0, 1]) {
    test(
      'Physical return restores bulk and $cylinders cylinder with original cost',
      () {
        final quantity = {'11800': cylinders};
        final sale = {
          'quantities': quantity,
          'extraGrams': 1180,
          'rate': 460000,
          'cash': 10000,
          'customerOwned': true,
        };
        final credit = {
          'sourceInvoice': 'invoice',
          'quantities': quantity,
          'extraGrams': 1180,
          'rate': 460000,
          'stockReturned': true,
          'note': 'Full gas return',
        };
        final book = Book([
          stock(50000, 1500000),
          doc('invoice', 'sale', sale),
          doc('credit', 'creditNote', credit, time: 2),
        ]);
        expect(book.gasGrams, 50000);
        expect(book.balance('inventory'), 1500000);
        expect(book.costOfSales, 0);
        expect(book.grossProfit, 0);
        expect(book.receivable('p'), -10000);
        expect(book.money('cash'), 10000);
        expect(book.profitIncomplete, isFalse);
        final day = RoznamchaDay('2026-11-12', 0, book.documents);
        expect(day.gasOut, cylinders * 11800 + 1180);
        expect(day.gasIn, 50000 + cylinders * 11800 + 1180);
        balanced(book);

        final financialCredit = Book([
          stock(50000, 1500000),
          doc('invoice', 'sale', sale),
          doc('credit', 'creditNote', {
            ...credit,
            'stockReturned': false,
          }, time: 2),
        ]);
        expect(financialCredit.gasGrams, 50000 - cylinders * 11800 - 1180);
        expect(financialCredit.costOfSales, (cylinders * 11800 + 1180) * 30);
        balanced(financialCredit);
      },
    );
  }

  test(
    'A bulk sale entered before its purchase takes its cost from that purchase',
    () {
      final sale = doc('bulk', 'sale', {
        'extraGrams': 15000,
        'rate': 460000,
      }, time: 2);
      Record purchase(int time) => doc('purchase', 'purchase', {
        'grams': 10000,
        'rate': 30000,
        'rateUnit': 1000,
      }, time: time);
      final late = Book([stock(10000, 300000), sale, purchase(3)]);
      expect(late.gasGrams, 5000);
      expect(late.uncostedSales, isEmpty);
      expect(late.shortageGrams, 0);
      expect(late.costOfSales, 450000);
      expect(late.profitIncomplete, isFalse);
      // The cost is the sale's own, not a lump on the purchase.
      expect(
        late.allocations.map((a) => (a.sale, a.lot, a.grams, a.cost)),
        [('bulk', 'opening', 10000, 300000), ('bulk', 'purchase', 5000, 150000)],
      );
      int cogsOf(String id) => late.postings
          .where((p) => p.document == id && p.account.startsWith('cogs'))
          .fold(0, (v, p) => v + p.debit);
      expect(cogsOf('bulk'), 450000);
      expect(cogsOf('purchase'), 0);
      expect(late.balance('inventory'), 150000);
      balanced(late);
      // Before the purchase is in the books the sale is still waiting.
      final waiting = Book([stock(10000, 300000), sale]);
      expect(waiting.uncostedSales['bulk'], 5000);
      expect(waiting.shortageGrams, 5000);
      expect(waiting.profitIncomplete, isTrue);
      final corrected = Book([stock(10000, 300000), sale, purchase(1)]);
      expect(corrected.gasGrams, 5000);
      expect(corrected.costOfSales, 450000);
      expect(corrected.uncostedSales, isEmpty);
      expect(corrected.profitIncomplete, isFalse);
      balanced(corrected);
    },
  );

  test(
    'Reports, saved corrections and voids use the same bulk stock quantity',
    () async {
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      addTearDown(app.close);
      await app.saveMaster('party', {'name': 'Ali'});
      final party = app.partyByName('Ali')!.id;
      const first = '2026-11-11', second = '2026-11-12';
      await app.post({
        'type': 'stockAdjustment',
        'date': first,
        'occurredAt': 0,
        'grams': 50000,
        'cost': 1500000,
        'costKnown': true,
        'note': 'Opening stock',
      });
      await app.post({
        'type': 'sale',
        'date': first,
        'occurredAt': 1,
        'party': party,
        'quantities': {'11800': 1},
        'returned': {'11800': 1},
        'extraGrams': 8200,
        'rate': 460000,
        'cash': 10000,
      });
      await app.post({
        'type': 'sale',
        'date': second,
        'occurredAt': 1,
        'party': party,
        'extraGrams': 5000,
        'rate': 460000,
        'cash': 100000,
      });
      expect(app.bookAt(first).gasGrams, 30000);
      expect(app.book.gasGrams, 25000);
      final stockReport = buildReport(app, 'Gas stock', first, second);
      expect(stockReport.rows.first.last.numeric, 25);
      final sales = buildReport(app, 'Sales register', first, second);
      expect(sales.rows.take(2).map((r) => r[3].numeric), [20, 5]);
      expect(sales.rows.last[3].numeric, 25);
      final profit = buildReport(app, 'Profit report', first, second);
      num? amount(String label) =>
          profit.rows.firstWhere((r) => r[0].text == label)[1].numeric;
      expect(amount('Cost of gas sold'), 7500);
      expect(amount('Gross profit'), app.book.grossProfit / 100);
      expect(amount('Net profit'), app.book.grossProfit / 100);
      expect(profit.notes, isEmpty);
      final daily = buildReport(app, 'Daily roznamcha', second, second);
      expect(daily.rows.any((r) => r[2].text.contains('Bulk 5 kg')), isTrue);
      expect(
        daily.rows.any((r) => r[2].text.contains('Opening 30 + 0 − 5 = 25')),
        isTrue,
      );

      final bulk = app.book.documents.last;
      await app.post(
        {...bulk.data, 'extraGrams': 6000},
        replace: bulk,
        reason: 'Correct weight',
      );
      expect(app.book.gasGrams, 24000);
      expect(app.book.costOfSales, 780000);
      expect(app.book.money('cash'), 110000);
      await app.voidDocument(app.book.documents.last, 'Cancelled sale');
      expect(app.book.gasGrams, 30000);
      expect(app.book.costOfSales, 600000);
      expect(app.book.money('cash'), 10000);
      expect(app.book.receivable(party), app.book.documents.last.bill - 10000);
    },
  );
}
