import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

// A share taken from a chosen purchase: its KG come out of that purchase
// (never our stock), whatever the entry order, and it is charged that
// purchase's own rate for those KG, in whole rupees like the purchase bill.

const day = '2026-11-02';

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

Future<AppController> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  addTearDown(app.close);
  app.setDate(day);
  for (final name in ['JU Gas', 'Sadiq', 'Ali', 'Old Supplier']) {
    await app.saveMaster('party', {'name': name});
  }
  return app;
}

String id(AppController app, String name) => app.partyByName(name)!.id;

Json purchase(
  AppController app,
  int grams, {
  int rate = 572000,
  int t = 9,
  String date = day,
  String from = 'JU Gas',
}) => {
  'type': 'purchase',
  'date': date,
  'occurredAt': t,
  'party': id(app, from),
  'grams': grams,
  'rate': rate,
  'rateUnit': 11800,
  'account': 'cash',
};

Json sale(AppController app, int count, {int t = 1}) => {
  'type': 'sale',
  'date': day,
  'occurredAt': t,
  'party': id(app, 'Ali'),
  'quantities': {'11800': count},
  'customerOwned': true,
  'rate': 577000,
};

Json share(AppController app, int grams, {int t = 5, String from = ''}) => {
  'type': 'sale',
  'date': day,
  'occurredAt': t,
  'party': id(app, 'Sadiq'),
  'quantities': <String, int>{},
  'extraGrams': grams,
  'bulkAtCost': true,
  if (from.isNotEmpty) 'sharePurchase': from,
};

Document lastOf(AppController app, EntryType type) =>
    app.book.documents.lastWhere((d) => d.type == type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('The live case: sales first, then the JU purchase, Sadiq\'s bulk charged at JU\'s rate', () async {
    final app = await start();
    await app.post(sale(app, 2, t: 1));
    await app.post({
      ...share(app, 14500000, t: 5),
      'bulkAtCost': false,
      'rate': 572000,
    }); // entered first as an ordinary bulk sale, as in the live khata
    await app.post(purchase(app, 29695000, t: 9));
    final ju = lastOf(app, EntryType.purchase);
    expect(ju.purchaseBill, 1439452500);
    final old = app.book.documents.firstWhere((d) => d.extraGrams > 0);
    expect(app.quoteBulkCost(
      {...old.data, 'bulkAtCost': true, 'sharePurchase': ju.reference},
      replace: old,
    ), 702881400);
    await app.post(
      {...old.data, 'bulkAtCost': true, 'sharePurchase': ju.reference},
      replace: old,
      reason: 'Share of the JU purchase',
    );
    final sadiq = app.book.documents.firstWhere((d) => d.bulkAtCost);
    // 14,500 kg × Rs 5,720 / 11.8 kg = 7,028,813.56 → Rs 7,028,814.
    expect(sadiq.shareCharge, 702881400);
    expect(sadiq.sharePurchase, ju.reference);
    expect(app.book.partyBalance(id(app, 'Sadiq')), 702881400);
    // Its KG come out of the JU purchase at the purchase bill's own split.
    final taken = app.book.allocations.where((a) => a.sale == sadiq.id).single;
    expect((taken.lot, taken.grams, taken.account), (ju.id, 14500000, 'purchase-share:cost'));
    expect(taken.cost, multiplyDivide(1439452500, 14500000, 29695000));
    // The rest of the purchase is ours: it covers the earlier sales first.
    final lot = app.book.lots.single;
    expect(lot.grams, 29695000 - 14500000 - 2 * 11800);
    expect(app.book.uncostedSales, isEmpty);
    expect(
      app.book.allocations.where((a) => a.account == 'cogs').map((a) => a.lot),
      [ju.id],
    );
    // Nothing of it is sales or profit; the paisa of rounding stay apart.
    expect(app.book.extraBilling, 0);
    expect(app.book.balance('purchase-share:cost'), taken.cost - 702881400);
    expect(app.book.warnings, isEmpty);
    expect(app.shareSource(sadiq), 'JU Gas · 02-11-2026');
    balanced(app.book);
  });

  test('A share before its chosen purchase waits for it; a dated book shows it waiting', () async {
    final app = await start();
    await app.post(purchase(app, 20000, t: 9, date: '2026-11-03'));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 5000, t: 1, from: ju.reference));
    final shared = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(shared.date, day);
    expect(shared.shareCharge, ju.purchaseBillFor(5000));
    expect(app.book.uncostedShares, isEmpty);
    final allocation = app.book.allocations.single;
    expect(allocation.lot, ju.id);
    // Costed on the day the purchase came, under the share.
    final cost = app.book.postings.where(
      (p) => p.document == shared.id && p.account == 'purchase-share:cost' && p.debit > 0,
    );
    expect(cost.single.date, '2026-11-03');
    final before = app.bookAt(day);
    expect(before.uncostedShares[shared.id], 5000);
    expect(before.gasGrams, -5000);
    expect(before.lots, isEmpty);
    expect(app.book.gasGrams, 15000);
    expect(app.book.lots.single.grams, 15000);
    balanced(app.book);
  });

  test('A chosen purchase\'s shared KG never reach our FIFO stock', () async {
    final app = await start();
    await app.post(purchase(app, 10000, rate: 400000, t: 1, from: 'Old Supplier'));
    final old = lastOf(app, EntryType.purchase);
    await app.post(purchase(app, 20000, t: 2));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 10000, t: 3, from: ju.reference));
    // 1 kg more than our stock: old 10 kg + JU's other 10 kg, then waiting.
    await app.post({
      ...sale(app, 1, t: 4),
      'quantities': {'45000': 0, '11800': 0, '15000': 0},
      'extraGrams': 21000,
      'bulkAtCost': false,
      'rate': 577000,
    });
    final big = app.book.documents.last;
    expect(
      app.book.allocations.where((a) => a.sale == big.id).map((a) => (a.lot, a.grams)),
      [(old.id, 10000), (ju.id, 10000)],
    );
    expect(app.book.uncostedSales[big.id], 1000);
    // The share is still charged JU's rate, not the cheaper old stock.
    final shared = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(shared.shareCharge, ju.purchaseBillFor(10000));
    balanced(app.book);
  });

  test('Shares cannot take more than their purchase, nor can a correction shrink it below them', () async {
    final app = await start();
    await app.post(purchase(app, 20000));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 12000, t: 1, from: ju.reference));
    expect(
      () => app.quoteBulkCost(share(app, 9000, from: ju.reference)),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
          'Shared KG exceed the selected purchase')),
    );
    await expectLater(
      app.post(share(app, 9000, t: 2, from: ju.reference)),
      throwsFormatException,
    );
    await app.post(share(app, 8000, t: 2, from: ju.reference));
    expect(app.book.lots.single.grams, 0);
    await expectLater(
      app.post({...ju.data, 'grams': 19000}, replace: ju, reason: 'Less gas'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
          'Shared KG exceed the selected purchase')),
    );
    final options = app.sharePurchaseOptions(day);
    expect(options.single.$2, 0);
    // Correcting one share may reuse its own KG.
    final first = app.book.documents.firstWhere((d) => d.extraGrams == 12000);
    expect(
      app.sharePurchaseOptions(day, replace: first).single.$2,
      12000,
    );
    await app.post({...first.data, 'extraGrams': 11000}, replace: first, reason: 'Weighed again');
    expect(app.book.lots.single.grams, 1000);
    balanced(app.book);
  });

  test('Correcting the purchase keeps the link; its new rate shows as a difference until the share is saved again', () async {
    final app = await start();
    await app.post(purchase(app, 20000));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 10000, t: 1, from: ju.reference));
    final shared = app.book.documents.firstWhere((d) => d.bulkAtCost);
    await app.post({...ju.data, 'rate': 600000}, replace: ju, reason: 'Supplier rate corrected');
    final corrected = lastOf(app, EntryType.purchase);
    expect(corrected.reference, ju.reference);
    expect(app.book.allocations.single.lot, corrected.id);
    expect(app.book.documents.firstWhere((d) => d.id == shared.id).shareCharge, shared.shareCharge);
    expect(app.book.warnings, contains('Purchase share cost changed; review purchase shares'));
    await app.post(shared.data, replace: shared, reason: 'New JU rate');
    final again = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(again.shareCharge, corrected.purchaseBillFor(10000));
    expect(app.book.warnings, isEmpty);
  });

  test('A purchase with shares cannot be deleted until the shares change', () async {
    final app = await start();
    await app.post(purchase(app, 20000));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 10000, t: 1, from: ju.reference));
    await expectLater(
      app.voidDocument(ju, 'Entered twice'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message',
          'Change the shares of this purchase first')),
    );
    final shared = app.book.documents.firstWhere((d) => d.bulkAtCost);
    await app.voidDocument(shared, 'Not shared after all');
    await app.voidDocument(ju, 'Entered twice');
    expect(app.book.documents, isEmpty);
  });

  test('Returning a chosen share\'s gas makes the whole purchase ours', () async {
    final app = await start();
    await app.post(purchase(app, 20000));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 10000, t: 1, from: ju.reference));
    final shared = app.book.documents.firstWhere((d) => d.bulkAtCost);
    await app.post({
      ...shared.data,
      'type': 'creditNote',
      'occurredAt': 2,
      'sourceInvoice': shared.id,
      'stockReturned': true,
      'note': 'Sadiq did not take it',
    });
    expect(app.book.gasGrams, 20000);
    expect(app.book.partyBalance(id(app, 'Sadiq')), 0);
    expect(app.book.balance('inventory'), ju.purchaseBill);
    expect(app.book.balance('purchase-share:cost'), 0);
    expect(app.book.costOfSales, 0);
    balanced(app.book);
  });

  test('A mixed entry: cylinders by FIFO at the sale rate, the bulk from the chosen purchase', () async {
    final app = await start();
    await app.post(purchase(app, 10000, rate: 400000, t: 1, from: 'Old Supplier'));
    final old = lastOf(app, EntryType.purchase);
    await app.post(purchase(app, 30000, t: 2));
    final ju = lastOf(app, EntryType.purchase);
    await app.post({
      ...share(app, 5000, t: 3, from: ju.reference),
      'quantities': {'11800': 1},
      'customerOwned': true,
      'rate': 577000,
    });
    final mixed = app.book.documents.last;
    expect(mixed.bill, mixed.cylinderRevenue + ju.purchaseBillFor(5000));
    expect(
      app.book.allocations.where((a) => a.sale == mixed.id).map((a) => (a.lot, a.account, a.grams)),
      [(old.id, 'cogs', 10000), (ju.id, 'cogs', 1800), (ju.id, 'purchase-share:cost', 5000)],
    );
    await app.applyDailyRate(590000, 'New cylinder rate');
    final rerated = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(rerated.rate, 590000);
    expect(rerated.shareCharge, ju.purchaseBillFor(5000));
    balanced(app.book);
  });

  test('Backup restore and reset keep and clear the chosen purchase', () async {
    final app = await start();
    await app.post(purchase(app, 20000));
    final ju = lastOf(app, EntryType.purchase);
    await app.post(share(app, 10000, t: 1, from: ju.reference));
    final backup = await app.backup();
    await app.resetAll();
    expect(app.book.documents, isEmpty);
    await app.restoreBackup(backup);
    final restored = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(restored.sharePurchase, ju.reference);
    expect(app.book.allocations.single.lot, ju.id);
  });

  test('Purchase options: around the entry date, newest first, with KG still free', () async {
    final app = await start();
    await app.post(purchase(app, 10000, t: 1, date: '2026-08-01'));
    await app.post(purchase(app, 20000, t: 1, date: '2026-10-30'));
    await app.post(purchase(app, 30000, t: 1, date: '2026-11-05'));
    await app.post(purchase(app, 40000, t: 1, date: '2026-11-20'));
    final options = app.sharePurchaseOptions(day);
    expect(options.map((o) => o.$1.date), ['2026-11-05', '2026-10-30']);
    final august = app.book.documents.firstWhere((d) => d.date == '2026-08-01');
    expect(
      app.sharePurchaseOptions(day, selected: august.reference).map((o) => o.$1.date),
      ['2026-11-05', '2026-10-30', '2026-08-01'],
    );
    expect(options.first.$2, 30000);
  });

  testWidgets('The daily form picks the purchase, previews its rate and saves the link', (tester) async {
    final app = await start();
    await app.post(purchase(app, 29695000));
    final ju = lastOf(app, EntryType.purchase);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RoznamchaForm(app: app))),
      ),
    );
    await tester.pumpAndSettle();
    Finder input(String key) => find.descendant(
      of: find.byKey(ValueKey('roz-$key')),
      matching: find.byType(TextField),
    );
    await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Sadiq');
    await tester.enterText(input('bulk'), '14500');
    await tester.pumpAndSettle();
    final picker = find.byKey(const ValueKey('roz-share-purchase'));
    expect(picker, findsOneWidget);
    await tester.ensureVisible(picker);
    await tester.tap(find.descendant(of: picker, matching: find.byType(DropdownButtonFormField<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('JU Gas').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Rs 7,028,814'), findsWidgets);
    final save = find.byKey(const ValueKey('roz-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final posted = app.book.documents.last;
    expect(posted.sharePurchase, ju.reference);
    expect(posted.shareCharge, 702881400);
    // The next entry starts from oldest stock again.
    expect(tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).sharePurchase, '');
    final report = buildReport(app, 'Purchase shares', day, day);
    expect(report.rows.first.last.text, 'JU Gas · 02-11-2026');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
