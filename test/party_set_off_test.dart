import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/entry_facts.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';

// A party's two sides are set off against each other (Book._setOff,
// khata_private.rebuild): after every entry a party is owed on one side only.

const en = Words(false);

Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

Document doc(AppController app, String type) =>
    app.book.documents.lastWhere((d) => d.type.name == type);

/// Atif buys 10 cylinders for Rs 30,000 on credit, then sells us 100 KG of
/// gas at Rs [rate] a KG on credit.
Future<String> atif(AppController app, {int rate = 50000}) async {
  await app.saveMaster('party', {'name': 'Atif', 'customer': true});
  final id = app.partyByName('Atif')!.id;
  await app.post({
    'type': 'sale',
    'date': '2026-11-10',
    'party': id,
    'quantities': {'11800': 10},
    'rate': 300000,
  });
  await app.post({
    'type': 'purchase',
    'date': '2026-11-11',
    'party': id,
    'grams': 100000,
    'rate': rate,
    'rateUnit': 1000,
    'account': 'cash',
    'amount': 0,
  });
  return id;
}

void expectBalancedDocuments(Book book) {
  final sums = <String, int>{};
  for (final p in book.postings) {
    sums.update(p.document, (v) => v + p.debit, ifAbsent: () => p.debit);
  }
  expect(sums.values.where((v) => v != 0), isEmpty);
}

void main() {
  test('A purchase from a customer who owes you lowers what he owes', () async {
    final (app, db) = await start();
    final id = await atif(app);
    final sale = doc(app, 'sale'), purchase = doc(app, 'purchase');
    final book = app.book;

    // Rs 30,000 owed to you is set off against the Rs 50,000 purchase.
    expect(book.receivable(id), 0);
    expect(book.payable(id), 2000000);
    expect(book.partyBalance(id), -2000000);
    expect(partyOwed(book, id), (receive: 0, pay: 2000000));
    expect(book.receivables, 0);
    expect(book.payables, 2000000);
    expect(book.setOffs[purchase.id], [(id, 3000000)]);
    expectBalancedDocuments(book);

    // The bill is paid by the set-off, and both entries say so.
    expect(book.invoiceDue[sale.id], 0);
    expect(book.setOffAllocations[purchase.id], [(sale.id, 3000000)]);
    expect(book.receiptAllocations[purchase.id], isNull);
    expect(entryStatus(app, sale, en)!.label, 'Paid');
    expect(entryStatus(app, purchase, en)!.label, 'You owe Rs 20,000');
    final paidBy = billPayments(app, sale, en).single;
    expect(paidBy.label, startsWith('Set off · Purchase'));
    expect(paidBy.value, 'Rs 30,000');
    expect(appliedFacts(app, purchase, en).single.label, startsWith('Set off'));
    final details = {
      for (final f in detailFacts(app, purchase, en)) f.label: f.value,
    };
    expect(details['Set off against what Atif owes you'], 'Rs 30,000');
    expect(details['Still owed to supplier'], 'Rs 20,000');

    // The day before the purchase is as it was.
    final before = app.bookAt('2026-11-10');
    expect(before.receivable(id), 3000000);
    expect(before.payable(id), 0);
    expect(before.invoiceDue[sale.id], 3000000);

    // The khata statement shows the purchase once, with no set-off rows.
    final statement = buildReport(
      app,
      'Party statement',
      '2026-11-01',
      '2026-11-12',
      party: id,
    );
    final row = statement.rows.firstWhere(
      (r) => r[2].text.contains('Purchase'),
    );
    expect(row[3].text, '');
    expect(row[4].numeric, 50000);
    expect(row[5].text, 'You owe 20,000');

    // Customer balances: one side only.
    final balances = buildReport(
      app,
      'Customer balances',
      '2026-11-12',
      '2026-11-12',
    );
    final atifRow = balances.rows.firstWhere((r) => r[0].text == 'Atif');
    expect(atifRow[2].numeric, 0);
    expect(atifRow[3].numeric, 20000);

    // The day sheet counts what the day's entries did, not the set-off.
    final day = pendingReport(
      app,
      app.ofKind('party'),
      day: '2026-11-11',
    ).withCompact(true);
    final dayRow = day.sheets.single.tables.single.body.firstWhere(
      (r) => r.any((c) => c.text == 'Atif'),
    );
    final texts = dayRow.map((c) => c.text).toList();
    expect(texts, contains('50,000'));
    expect(texts, isNot(contains('80,000')));

    // Voiding the purchase brings the receivable and the bill back.
    await app.voidDocument(purchase, 'Entered twice');
    expect(app.book.receivable(id), 3000000);
    expect(app.book.payable(id), 0);
    expect(app.book.invoiceDue[sale.id], 3000000);
    expect(app.book.setOffs, isEmpty);
    app.dispose();
    await db.close();
  });

  test('A smaller purchase only lowers the receivable', () async {
    final (app, db) = await start();
    // 100 KG at Rs 100 = Rs 10,000 against Rs 30,000 owed.
    final id = await atif(app, rate: 10000);
    final sale = doc(app, 'sale'), purchase = doc(app, 'purchase');
    expect(app.book.receivable(id), 2000000);
    expect(app.book.payable(id), 0);
    expect(partyOwed(app.book, id), (receive: 2000000, pay: 0));
    expect(app.book.invoiceDue[sale.id], 2000000);
    expect(entryStatus(app, purchase, en)!.label, 'Set off');
    final details = {
      for (final f in detailFacts(app, purchase, en)) f.label: f.value,
    };
    expect(details.containsKey('Still owed to supplier'), isFalse);

    // Paying him later for nothing he is owed: what you paid is his debt.
    await app.post({
      'type': 'receipt',
      'date': '2026-11-12',
      'party': id,
      'cash': 2000000,
    });
    expect(partyOwed(app.book, id), (receive: 0, pay: 0));
    expect(app.book.invoiceDue[sale.id], 0);
    app.dispose();
    await db.close();
  });

  test('An opening payable is set off by later sales', () async {
    final (app, db) = await start();
    await app.saveMaster(
      'party',
      {'name': 'Luqman', 'customer': true},
      supplierOpening: 888029,
      openingDate: '2026-11-01',
    );
    final id = app.partyByName('Luqman')!.id;
    await app.post({
      'type': 'sale',
      'date': '2026-11-02',
      'party': id,
      'quantities': {'11800': 5},
      'rate': 300000,
    });
    final sale = doc(app, 'sale');
    // Rs 15,000 of sales against Rs 8,880.29 you owed him.
    expect(app.book.payable(id), 0);
    expect(app.book.receivable(id), 1500000 - 888029);
    expect(partyOwed(app.book, id), (receive: 611971, pay: 0));
    expect(app.book.invoiceDue[sale.id], 611971);
    expect(app.book.setOffs[sale.id], [(id, 888029)]);
    // A bill's own set-off is listed on it (its Payment card does not).
    expect(billPayments(app, sale, en).single.value, 'Rs 8,880.29');
    expectBalancedDocuments(app.book);
    app.dispose();
    await db.close();
  });

  test(
    'An advance from a customer is set off against an overpaid company',
    () async {
      final (app, db) = await start();
      await app.saveMaster('party', {'name': 'Dono', 'customer': true});
      final id = app.partyByName('Dono')!.id;
      // He pays Rs 50,000 in advance; you pay him Rs 30,000 as a company.
      await app.post({
        'type': 'receipt',
        'date': '2026-11-10',
        'party': id,
        'cash': 5000000,
      });
      await app.post({
        'type': 'payment',
        'date': '2026-11-11',
        'party': id,
        'account': 'cash',
        'amount': 3000000,
        'supplierPayment': true,
      });
      final payment = doc(app, 'payment');
      expect(app.book.setOffs[payment.id], [(id, -3000000)]);
      expect(app.book.receivable(id), -2000000);
      expect(app.book.payable(id), 0);
      expect(partyOwed(app.book, id), (receive: 0, pay: 2000000));
      final details = {
        for (final f in detailFacts(app, payment, en)) f.label: f.value,
      };
      expect(details['Set off against the advance from Dono'], 'Rs 30,000');

      // A sale of Rs 40,000 uses the Rs 20,000 advance left.
      await app.post({
        'type': 'sale',
        'date': '2026-11-12',
        'party': id,
        'quantities': {'11800': 4},
        'rate': 1000000,
      });
      final sale = doc(app, 'sale');
      expect(app.book.receivable(id), 2000000);
      expect(app.book.invoiceDue[sale.id], 2000000);
      expectBalancedDocuments(app.book);
      app.dispose();
      await db.close();
    },
  );

  test('Sides that point the same way are left alone', () {
    Record party = Record('p', 'party', {'name': 'P'});
    Record document(String id, Json data) => Record(id, 'document', {
      'date': '2026-11-10',
      'party': 'p',
      'account': 'cash',
      ...data,
    });
    final book = Book([
      party,
      Record('cash', 'account', {'name': 'Cash'}),
      // Overpaid as a company and owed as a customer: both owe you.
      document('a', {
        'type': 'payment',
        'supplierPayment': true,
        'amount': 500000,
      }),
      document('b', {'type': 'payment', 'amount': 100000, 'occurredAt': 1}),
    ]);
    expect(book.setOffs, isEmpty);
    expect(book.payable('p'), -500000);
    expect(book.receivable('p'), 100000);
    expect(partyOwed(book, 'p'), (receive: 600000, pay: 0));
  });
}
