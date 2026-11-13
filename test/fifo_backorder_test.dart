import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';

// Sales entered before the purchase they came from (the business's daily
// pattern: the day's sales first, the supplier's purchase later) wait for
// that stock and take their cost from it, under their own date.

const day = '2026-11-02';

Record doc(String id, String type, Json data, {String date = day, int t = 1}) =>
    Record(id, 'document', {
      'type': type,
      'date': date,
      'occurredAt': t,
      'party': 'p',
      ...data,
    });

Record cylinderSale(String id, int count, {String date = day, int t = 1}) =>
    doc(id, 'sale', {
      'quantities': {'11800': count},
      'customerOwned': true,
      'rate': 577000,
    }, date: date, t: t);

/// Rs 5,720 per 11.8 kg, like the JU Gas purchase in the live khata.
Record purchase(String id, int grams, {String date = day, int t = 9}) =>
    doc(id, 'purchase', {
      'grams': grams,
      'rate': 572000,
      'rateUnit': 11800,
    }, date: date, t: t);

void balanced(Book book) {
  for (final d in book.documents) {
    expect(
      book.postings
          .where((p) => p.document == d.id)
          .fold(0, (v, p) => v + p.debit),
      0,
      reason: d.id,
    );
  }
}

int costOf(Book book, String id) => book.allocations
    .where((a) => a.sale == id)
    .fold(0, (v, a) => v + a.cost);

Future<AppController> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  addTearDown(app.close);
  app.setDate(day);
  await app.saveMaster('party', {'name': 'JU Gas'});
  await app.saveMaster('party', {'name': 'Sadiq'});
  await app.saveMaster('party', {'name': 'Ali'});
  return app;
}

String id(AppController app, String name) => app.partyByName(name)!.id;

Json sale(AppController app, int count, {int t = 1, String date = day}) => {
  'type': 'sale',
  'date': date,
  'occurredAt': t,
  'party': id(app, 'Ali'),
  'quantities': {'11800': count},
  'customerOwned': true,
  'rate': 577000,
};

Json juPurchase(AppController app, int grams, {int t = 9, String date = day}) =>
    {
      'type': 'purchase',
      'date': date,
      'occurredAt': t,
      'party': id(app, 'JU Gas'),
      'grams': grams,
      'rate': 572000,
      'rateUnit': 11800,
      'account': 'cash',
    };

Json bulk(AppController app, int grams, {int t = 5, bool share = true}) => {
  'type': 'sale',
  'date': day,
  'occurredAt': t,
  'party': id(app, 'Sadiq'),
  'quantities': <String, int>{},
  'extraGrams': grams,
  if (share) 'bulkAtCost': true else 'rate': 572000,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('The day\'s sales, a stock loss and a share before the purchase are all costed from it', () {
    final book = Book([
      doc('loss', 'stockAdjustment', {
        'grams': -440000,
        'cost': 0,
        'costKnown': false,
        'note': 'unknown',
      }, date: '2026-11-01'),
      cylinderSale('s1', 3, t: 1),
      cylinderSale('s2', 2, t: 2),
      doc('share', 'sale', {
        'quantities': <String, int>{},
        'extraGrams': 14500000,
        'bulkAtCost': true,
        'bulkCost': 0,
      }, t: 3),
      purchase('ju', 29695000, t: 9),
    ]);
    final bill = book.documents.last.purchaseBill;
    expect(bill, 1439452500);
    expect(book.uncostedSales, isEmpty);
    expect(book.shortageGrams, 0);
    expect(book.profitIncomplete, isFalse);
    expect(book.gasGrams, 29695000 - 440000 - 5 * 11800 - 14500000);
    // Oldest first: the stock loss, the two sales, then the share.
    expect(book.allocations.map((a) => a.sale), ['loss', 's1', 's2', 'share']);
    expect(book.allocations.every((a) => a.lot == 'ju'), isTrue);
    expect(
      [for (final a in book.allocations) a.grams],
      [440000, 3 * 11800, 2 * 11800, 14500000],
    );
    // The share costs exactly its part of the purchase, to the paisa.
    expect(book.shareCosts['share'], multiplyDivide(
      bill - costOf(book, 'loss') - costOf(book, 's1') - costOf(book, 's2'),
      14500000,
      29695000 - 440000 - 5 * 11800,
    ));
    // Each cost is posted under its own document, dated the day the stock
    // came (so a closed day never changes), none on the purchase itself.
    final loss = book.postings.where((p) => p.document == 'loss');
    expect(loss.map((p) => (p.date, p.account)), [
      (day, 'expense:Stock loss'),
      (day, 'inventory'),
    ]);
    expect(book.postings.where((p) => p.document == 'ju' && p.account.startsWith('cogs')), isEmpty);
    expect(book.postings.any((p) => p.account == 'cogs:shortage'), isFalse);
    // The purchase's value is conserved: what was taken plus what is left.
    final taken = book.allocations.fold(0, (v, a) => v + a.cost);
    expect(taken + book.lots.single.cost!, bill);
    expect(book.balance('inventory'), book.lots.single.cost);
    balanced(book);
  });

  test('Many small sales before one purchase conserve its cost to the paisa', () {
    final book = Book([
      for (var i = 0; i < 37; i++) cylinderSale('s$i', 1, t: i),
      doc('odd', 'purchase', {
        'grams': 37 * 11800,
        'rate': 333333,
        'rateUnit': 11800,
      }, t: 100),
    ]);
    final bill = book.documents.last.purchaseBill;
    expect(book.allocations.fold(0, (v, a) => v + a.cost), bill);
    expect(book.costOfSales, bill);
    expect(book.balance('inventory'), 0);
    expect(book.lots.single.grams, 0);
    expect(book.lots.single.cost, 0);
    expect(book.profitIncomplete, isFalse);
    balanced(book);
  });

  test('A mixed entry waiting for stock is covered cylinders first, then the share', () {
    final book = Book([
      doc('mixed', 'sale', {
        'quantities': {'11800': 1},
        'customerOwned': true,
        'rate': 577000,
        'extraGrams': 5000,
        'bulkAtCost': true,
        'bulkCost': 0,
      }, t: 1),
      purchase('first', 12000, t: 2),
      purchase('second', 10000, t: 3),
    ]);
    expect(
      book.allocations.map((a) => (a.lot, a.account, a.grams)),
      [
        ('first', 'cogs', 11800),
        ('first', 'purchase-share:cost', 200),
        ('second', 'purchase-share:cost', 4800),
      ],
    );
    expect(book.uncostedShares, isEmpty);
    balanced(book);
  });

  test('Stock of unknown cost covers the gas but leaves its cost unknown', () {
    final book = Book([
      cylinderSale('sale', 1, t: 1),
      doc('found', 'stockAdjustment', {
        'grams': 20000,
        'cost': 0,
        'costKnown': false,
        'note': 'Found stock',
      }, t: 2),
    ]);
    expect(book.shortageGrams, 0);
    expect(book.gasGrams, 8200);
    expect(book.uncostedSales['sale'], 11800);
    expect(book.profitIncomplete, isTrue);
    balanced(book);
  });

  test('Converting a bulk sale entered before its purchase into a share prices it from that purchase', () async {
    final app = await start();
    await app.post(sale(app, 2, t: 1));
    await app.post(bulk(app, 14500000, t: 5, share: false));
    await app.post(juPurchase(app, 29695000, t: 9));
    final old = app.book.documents.firstWhere((d) => d.extraGrams > 0);
    expect(old.bulkAtCost, isFalse);
    expect(app.book.uncostedSales, isEmpty);
    final cost = costOf(app.book, old.id), expected = roundRupees(cost);
    await app.post(
      {...old.data, 'bulkAtCost': true},
      replace: old,
      reason: 'Share at purchase cost',
    );
    final share = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(share.value('occurredAt'), 5);
    expect(share.shareCharge, expected);
    expect(share.rate, 0);
    expect(app.book.shareCosts[share.id], cost);
    expect(app.book.balance('purchase-share:cost'), cost - expected);
    expect(app.book.partyBalance(id(app, 'Sadiq')), expected);
    expect(app.book.extraBilling, 0);
    expect(app.book.warnings, isEmpty);
    balanced(app.book);
  });

  test('Entries before an existing share are still accepted; the share then waits or is repriced visibly', () async {
    final app = await start();
    await app.post(juPurchase(app, 20000, t: 1));
    await app.post(bulk(app, 15000, t: 5));
    final share = app.book.documents.last;
    expect(
      share.shareCharge,
      roundRupees(
        multiplyDivide(app.book.documents.first.purchaseBill, 15000, 20000),
      ),
    );
    expect(share.shareCharge, 727100); // 7,271.25 in whole rupees
    // Back-entered sale earlier the same day takes stock the share was using.
    await app.post(sale(app, 1, t: 2));
    expect(app.book.uncostedShares[share.id], 6800);
    expect(app.book.warnings, contains('Shared gas is waiting for purchase stock'));
    // The share's recorded charge does not change by itself.
    expect(app.book.documents.firstWhere((d) => d.id == share.id).shareCharge, share.shareCharge);
    // The next purchase covers the waiting part; any price difference shows.
    await app.post(juPurchase(app, 10000, t: 20));
    expect(app.book.uncostedShares, isEmpty);
    expect(app.book.uncostedSales, isEmpty);
    // Same Rs/kg, but each purchase bill rounds to whole rupees on its own:
    // 8.2 kg of the first lot plus 6.8 kg of the second cost 7,270.91.
    expect(app.book.shareCosts[share.id], 727091);
    expect(app.book.balance('purchase-share:cost'), -9);
    // Under a rupee: shown in the Purchase shares report, not as a warning.
    expect(app.book.warnings, isEmpty);
    final report = buildReport(app, 'Purchase shares', day, day);
    expect(report.rows.first[6].numeric, -0.09);
    balanced(app.book);
  });

  test('Voiding the purchase under a share is allowed and the books still build', () async {
    final app = await start();
    await app.post(juPurchase(app, 20000, t: 1));
    final lot = app.book.documents.single;
    await app.post(bulk(app, 15000, t: 5));
    await app.voidDocument(lot, 'Wrong supplier');
    expect(app.book.uncostedShares.values.single, 15000);
    expect(app.book.gasGrams, -15000);
    expect(
      app.book.warnings,
      containsAll(['Negative gas stock', 'Shared gas is waiting for purchase stock']),
    );
    expect(() => buildReport(app, 'Purchase shares', day, day), returnsNormally);
    expect(() => buildReport(app, 'FIFO allocations', day, day), returnsNormally);
  });

  test('A new share with no stock now or later is refused', () async {
    final app = await start();
    await app.post(sale(app, 1, t: 1));
    expect(
      () => app.quoteBulkCost(bulk(app, 1000)),
      throwsA(isA<FormatException>()),
    );
    await expectLater(app.post(bulk(app, 1000)), throwsFormatException);
    expect(app.book.documents.length, 1);
  });

  test('Physical return of a sale covered by a later purchase restores its exact cost', () async {
    final app = await start();
    await app.post(sale(app, 1, t: 1));
    await app.post(juPurchase(app, 20000, t: 2));
    final invoice = app.book.documents.first;
    final cost = costOf(app.book, invoice.id);
    expect(cost, isNot(0));
    await app.post({
      ...invoice.data,
      'type': 'creditNote',
      'occurredAt': 3,
      'sourceInvoice': invoice.id,
      'stockReturned': true,
      'note': 'Returned full',
    });
    expect(app.book.gasGrams, 20000);
    expect(app.book.balance('inventory'), app.book.documents[1].purchaseBill);
    expect(app.book.costOfSales, 0);
    balanced(app.book);
  });

  test('Daily rate change re-quotes a mixed share after a purchase-cost correction', () async {
    final app = await start();
    await app.post(juPurchase(app, 50000, t: 1));
    await app.post({
      ...bulk(app, 5000, t: 5),
      'quantities': {'11800': 1},
      'customerOwned': true,
      'rate': 577000,
    });
    final lot = app.book.documents.first;
    await app.post(
      {...lot.data, 'rate': 600000},
      replace: lot,
      reason: 'Supplier price corrected',
    );
    expect(app.book.warnings, contains('Purchase share cost changed; review purchase shares'));
    await app.applyDailyRate(580000, 'New rate');
    final mixed = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(mixed.rate, 580000);
    expect(mixed.shareCharge, roundRupees(app.book.shareCosts[mixed.id]!));
    expect(
      app.book.balance('purchase-share:cost'),
      app.book.shareCosts[mixed.id]! - mixed.shareCharge,
    );
  });

  test('Returning an invoice whose gas still waits cancels the wait; no later stock covers it', () {
    final records = [
      purchase('first', 10000, t: 0),
      cylinderSale('invoice', 1, t: 1), // 10 kg from stock, 1.8 kg waiting
      doc('back', 'creditNote', {
        'sourceInvoice': 'invoice',
        'quantities': {'11800': 1},
        'rate': 577000,
        'stockReturned': true,
        'note': 'Returned full',
      }, t: 2),
      purchase('second', 20000, t: 3),
    ];
    final book = Book(records);
    expect(book.shortageGrams, 0);
    expect(book.uncostedSales, isEmpty);
    expect(book.gasGrams, 30000);
    // Only the 10 kg that came from stock goes back as a lot, at its cost.
    final back = book.lots.firstWhere((l) => l.id == 'back');
    expect(back.grams, 10000);
    expect(back.cost, book.documents.first.purchaseBill);
    // The second purchase covers nothing for the returned invoice.
    expect(book.allocations.where((a) => a.lot == 'second'), isEmpty);
    expect(book.costOfSales, 0);
    expect(
      book.balance('inventory'),
      book.documents.first.purchaseBill + book.documents.last.purchaseBill,
    );
    balanced(book);
  });

  test('A financial-only credit note of a share books the given-away gas as cost', () async {
    final app = await start();
    await app.post(juPurchase(app, 20000, t: 1));
    await app.post(bulk(app, 5000, t: 5));
    final share = app.book.documents.last;
    await app.post({
      ...share.data,
      'type': 'creditNote',
      'occurredAt': 6,
      'sourceInvoice': share.id,
      'stockReturned': false,
      'note': 'Forgiven',
    });
    expect(app.book.partyBalance(id(app, 'Sadiq')), 0);
    expect(app.book.gasGrams, 15000);
    expect(app.book.balance('purchase-share:cost'), 0);
    expect(app.book.costOfSales, app.book.shareCosts[share.id]);
    expect(app.book.grossProfit, -app.book.shareCosts[share.id]!);
    expect(app.book.warnings, isEmpty);
    final report = buildReport(app, 'Purchase shares', day, day);
    expect(report.rows.fold<num>(0, (v, r) => v + r[6].numeric!), 0);
    balanced(app.book);
  });

  test('Restoring a saved day re-prices its share at today\'s FIFO cost', () async {
    final app = await start();
    await app.post(juPurchase(app, 20000, t: 1));
    await app.post(bulk(app, 15000, t: 5));
    await app.saveSnapshot();
    final snapshot = app.records.lastWhere((r) => r.kind == 'snapshot');
    // An earlier sale back-entered after the snapshot moves the share's cost.
    await app.post(sale(app, 1, t: 2));
    await app.restoreSnapshot(snapshot, 'Undo the late entry');
    final share = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(share.data['restoredFrom'], isNotNull);
    expect(share.shareCharge, roundRupees(app.book.shareCosts[share.id]!));
    expect(app.book.documents.where((d) => d.type == EntryType.sale && !d.bulkAtCost), isEmpty);
    balanced(app.book);
  });

  test('The fast quote for a new entry equals the full projection', () async {
    final app = await start();
    await app.post(juPurchase(app, 23456, t: 1));
    await app.post({...juPurchase(app, 34567, t: 2), 'rate': 613300});
    await app.post(sale(app, 1, t: 3));
    // 23.456 + 34.567 − 11.8 = 46.223 kg left; the candidate's own cylinder
    // takes 11.8 kg of it first, so 34.423 kg is the most it can share.
    for (final grams in [1, 999, 11701, 11800, 23455, 34423]) {
      final candidate = {...bulk(app, grams, t: 50), 'quantities': {'11800': 1}};
      final fast = app.quoteBulkCost(candidate);
      final full = Book([
        ...app.records,
        Record('x', 'document', {...candidate, 'bulkCost': 0}),
      ]).shareCosts['x']!;
      expect(fast, roundRupees(full), reason: '$grams g');
    }
    expect(() => app.quoteBulkCost(bulk(app, 60000, t: 50)), throwsFormatException);
  });

  test('Profit for the sale\'s day includes the cost a later purchase gave it', () async {
    final app = await start();
    await app.post(sale(app, 1, t: 1, date: '2026-11-01'));
    await app.post(juPurchase(app, 20000, t: 1, date: '2026-11-03'));
    final profit = buildReport(app, 'Profit report', '2026-11-01', '2026-11-01');
    num? row(String label) =>
        profit.rows.firstWhere((r) => r[0].text == label)[1].numeric;
    expect(row('Cost of gas sold'), app.book.costOfSales / 100);
    expect(row('Cost of gas sold'), isNot(0));
    final purchaseDay = buildReport(app, 'Profit report', '2026-11-03', '2026-11-03');
    expect(
      purchaseDay.rows.firstWhere((r) => r[0].text == 'Cost of gas sold')[1].numeric,
      0,
    );
    expect(profit.notes, isEmpty);
    // As of that day alone, its cost was not known yet.
    expect(app.bookAt('2026-11-01').profitIncomplete, isTrue);
  });
}
