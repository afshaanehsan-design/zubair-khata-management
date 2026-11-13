import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/entry_facts.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

const date = '2026-11-12';
Record doc(String id, String type, Json data, int time) => Record(
  id,
  'document',
  {'type': type, 'date': date, 'occurredAt': time, 'party': 'p', ...data},
);
List<Record> twoLots() => [
  doc('first', 'stockAdjustment', {
    'grams': 10000,
    'cost': 300001,
    'costKnown': true,
  }, 0),
  doc('second', 'stockAdjustment', {
    'grams': 15000,
    'cost': 480005,
    'costKnown': true,
  }, 1),
];
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

Future<AppController> start({int grams = 100000, int cost = 3000000}) async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  addTearDown(app.close);
  app.setDate(date);
  await app.saveMaster('party', {'name': 'Ali'});
  await app.post({
    'type': 'stockAdjustment',
    'date': date,
    'occurredAt': 0,
    'grams': grams,
    'cost': cost,
    'costKnown': true,
    'note': 'Purchase stock',
  });
  return app;
}

Json share(AppController app, int grams, {int time = 10}) => {
  'type': 'sale',
  'date': date,
  'occurredAt': time,
  'party': app.partyByName('Ali')!.id,
  'quantities': <String, int>{},
  'extraGrams': grams,
  'bulkAtCost': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Reset clears sharing and backup restore keeps its recorded exact price',
    () async {
      final app = await start();
      await app.post(share(app, 5000));
      final original = app.book.documents.last;
      final backup = await app.backup();
      app.rozDrafts['share'] = {'bulkAtCost': true};
      app.composerDrafts['share'] = {'bulkAtCost': true};
      await app.resetAll();
      expect(app.book.documents, isEmpty);
      expect(app.book.shareCosts, isEmpty);
      expect(app.book.balance('purchase-share:cost'), 0);
      expect(app.rozDrafts, isEmpty);
      expect(app.composerDrafts, isEmpty);
      await app.restoreBackup(backup);
      final restored = app.book.documents.firstWhere(
        (d) => d.id == original.id,
      );
      expect(restored.bulkAtCost, isTrue);
      expect(restored.bill, original.bill);
      expect(app.book.gasGrams, 95000);
      expect(app.book.grossProfit, 0);
    },
  );

  test('Raw commits reject a stale share quote before queuing it', () async {
    final app = await start();
    await expectLater(
      app.commit([
        Change('stale-share', 'document', {
          ...share(app, 1000),
          'bulkCost': 99999,
        }, 0),
      ]),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Purchase-share cost changed; refresh the entry',
        ),
      ),
    );
    expect(app.record('stale-share'), isNull);
    expect(app.book.gasGrams, 100000);
  });

  test('A share beyond its day\'s stock is priced from the next purchase, oldest first', () async {
    final app = await start(grams: 1000, cost: 30000);
    expect(app.quoteBulkCost(share(app, 500)), 15000);
    // No later stock yet: the price is unknown, so it is refused.
    await expectLater(app.post(share(app, 1500)), throwsFormatException);
    await app.post({
      'type': 'stockAdjustment',
      'date': '2026-11-13',
      'occurredAt': 0,
      'grams': 10000,
      'cost': 700000,
      'costKnown': true,
      'note': 'Later purchase',
    });
    // 1 kg at Rs 30/kg on the day, the other 0.5 kg from the next lot.
    expect(app.quoteBulkCost(share(app, 1500)), 30000 + 35000);
    await app.post(share(app, 1500));
    final shared = app.book.documents.firstWhere((d) => d.bulkAtCost);
    expect(shared.shareCharge, 65000);
    expect(app.book.shareCosts[shared.id], 65000);
    expect(app.book.uncostedSales, isEmpty);
    expect(app.book.balance('purchase-share:cost'), 0);
    expect(app.book.gasGrams, 9500);
    expect(app.book.warnings, isEmpty);
    // Through the share's own day the later lot is not there yet.
    expect(app.bookAt(date).uncostedShares[shared.id], 500);
  });

  test(
    'Known zero-cost stock can be shared without inventing a selling rate',
    () async {
      final app = await start(grams: 1000, cost: 0);
      await app.post(share(app, 500));
      expect(app.book.documents.last.bill, 0);
      expect(app.book.documents.last.bulkAtCost, isTrue);
      expect(app.book.gasGrams, 500);
      expect(app.book.grossProfit, 0);
    },
  );

  test(
    'Sharing across two purchase prices charges FIFO cost in whole rupees with no sales',
    () {
      // 10 kg of the first lot (300001) + 5 kg of the second (480005 / 3).
      final book = Book(
        [
          ...twoLots(),
          doc('share', 'sale', {
            'quantities': <String, int>{},
            'extraGrams': 15000,
            'bulkAtCost': true,
            'bulkCost': 460000,
            'cash': 100000,
          }, 2),
        ],
        verifyShares: {'share'},
      );
      final d = book.documents.last;
      expect(d.bill, 460000); // FIFO cost 4,600.03 in whole rupees.
      expect(d.bulkRevenue, 0);
      expect(book.shareCosts[d.id], 460003);
      expect(book.gasGrams, 10000);
      expect(book.balance('inventory'), 320003);
      expect(book.receivable('p'), 360000);
      expect(book.costOfSales, 0);
      expect(book.cylinderSales, 0);
      expect(book.extraBilling, 0);
      expect(book.grossProfit, 0);
      // The 3 paisa of rounding stay in the share account, not in profit.
      expect(book.balance('purchase-share:cost'), 3);
      expect(book.warnings, isEmpty);
      expect(book.profitIncomplete, isFalse);
      balanced(book);
      // An exact-paisa charge is no longer what the books expect.
      expect(
        () => Book([
          ...twoLots(),
          doc('share', 'sale', {
            'quantities': <String, int>{},
            'extraGrams': 15000,
            'bulkAtCost': true,
            'bulkCost': 460003,
          }, 2),
        ], verifyShares: {'share'}),
        throwsFormatException,
      );
    },
  );

  test('Mixed entry prices cylinders normally and shares only the remaining FIFO cost', () {
    // The cylinder takes 10 kg + 1.8 kg; the share the next 8.2 kg.
    final book = Book(
      [
        ...twoLots(),
        doc('mixed', 'sale', {
          'quantities': {'11800': 1},
          'returned': {'11800': 1},
          'rate': 460000,
          'extraGrams': 8200,
          'bulkAtCost': true,
          'bulkCost': 262400,
        }, 2),
      ],
      verifyShares: {'mixed'},
    );
    expect(book.documents.last.bill, 722400);
    expect(book.costOfSales, 357602);
    expect(book.grossProfit, 102398);
    expect(book.balance('inventory'), 160002);
    expect(book.gasGrams, 5000);
    expect(book.balance('purchase-share:cost'), 2);
    final day = RoznamchaDay(date, 0, book.documents);
    expect(day.bill, 460000);
    expect(day.shareAmount, 262400);
    expect(day.totalBilled, 722400);
    expect(day.dispatchGrams, 20000);
    expect(day.cylinders[11800], 1);
    balanced(book);
  });

  test('Posting calculates price, collections settle the party, and reports separate sharing', () async {
    final app = await start();
    await app.post({...share(app, 5000), 'bulkCost': 999999});
    final d = app.book.documents.last;
    expect(d.shareCharge, 150000); // Ignore stale preview/client prices.
    expect(d.rate, 0);
    expect(entryTypeLabel(d, const Words(false)), 'Purchase share');
    await app.post({
      'type': 'receipt',
      'date': date,
      'occurredAt': 11,
      'party': d.party,
      'cash': 75000,
    });
    expect(app.book.invoiceDue[d.id], 75000);
    expect(app.book.receivable(d.party), 75000);
    expect(app.book.money('cash'), 75000);
    expect(app.book.grossProfit, 0);
    expect(buildReport(app, 'Sales register', date, date).rows, isEmpty);
    final shares = buildReport(app, 'Purchase shares', date, date);
    expect(shares.rows.first[3].numeric, 5);
    expect(shares.rows.first[4].numeric, 1500);
    expect(shares.rows.first[5].numeric, 1500);
    expect(shares.rows.first[6].numeric, 0);
    expect(invoiceReport(app, d).title, startsWith('Purchase share'));
    expect(
      invoiceReport(
        app,
        d,
      ).rows.any((r) => r.first.text == 'Purchase share (at cost)'),
      isTrue,
    );
    final day = RoznamchaDay(date, 0, app.book.documents);
    expect(day.bill, 0);
    expect(day.shareAmount, 150000);
    expect(day.safi, 75000);
    final profit = buildReport(app, 'Profit report', date, date);
    expect(profit.rows.every((r) => r[1].numeric == 0), isTrue);
    final urdu = buildReport(app, 'Purchase shares', date, date, urdu: true);
    expect(urdu.title, isNot('Purchase shares'));
    balanced(app.book);
  });

  test(
    'Daily sale rate changes cannot reprice pure or mixed purchase shares',
    () async {
      final app = await start();
      await app.post(share(app, 1000));
      final pure = app.book.documents.last;
      await app.post({
        ...share(app, 2000, time: 11),
        'quantities': {'11800': 1},
        'returned': {'11800': 1},
        'rate': 460000,
      });
      await app.applyDailyRate(500000, 'Daily cylinder rate');
      final shares = app.book.documents.where((d) => d.bulkAtCost).toList();
      expect(shares.map((d) => d.shareCharge), [30000, 60000]);
      expect(shares.first.id, pure.id);
      expect(shares.first.rate, 0);
      expect(shares.last.rate, 500000);
      expect(app.book.gasGrams, 85200);
      expect(app.book.costOfSales, 354000);
      expect(app.book.grossProfit, 146000);
    },
  );

  test(
    'Missing stock or unknown purchase cost blocks sharing atomically',
    () async {
      final app = await start(grams: 1000, cost: 30000);
      final count = app.book.documents.length;
      await expectLater(app.post(share(app, 2000)), throwsFormatException);
      expect(app.book.documents.length, count);
      expect(app.book.gasGrams, 1000);
      final opening = app.book.documents.single;
      await app.post(
        {...opening.data, 'costKnown': false},
        replace: opening,
        reason: 'Cost not yet entered',
      );
      await expectLater(app.post(share(app, 500)), throwsFormatException);
      expect(app.book.documents.length, count);
      expect(app.book.gasGrams, 1000);
    },
  );

  test('Backdated cost correction exposes a difference without silently changing debt', () async {
    final app = await start(grams: 10000, cost: 300000);
    final opening = app.book.documents.single;
    await app.post(share(app, 1000));
    final shared = app.book.documents.last;
    await app.post(
      {...opening.data, 'cost': 400000},
      replace: opening,
      reason: 'Supplier corrected purchase price',
    );
    expect(app.book.receivable(shared.party), 30000);
    expect(app.book.shareCosts[shared.id], 40000);
    expect(app.book.balance('purchase-share:cost'), 10000);
    expect(app.book.grossProfit, 0);
    expect(
      app.book.warnings,
      contains('Purchase share cost changed; review purchase shares'),
    );
    await app.post(
      shared.data,
      replace: shared,
      reason: 'Correct agreed share cost',
    );
    expect(app.book.documents.last.shareCharge, 40000);
    expect(app.book.receivable(shared.party), 40000);
    expect(app.book.balance('purchase-share:cost'), 0);
  });

  test('Physical sharing return restores cost and stock without creating revenue or profit', () async {
    final app = await start();
    await app.post({...share(app, 5000), 'cash': 100000});
    final shared = app.book.documents.last;
    await app.post({
      ...shared.data,
      'type': 'creditNote',
      'occurredAt': 11,
      'sourceInvoice': shared.id,
      'stockReturned': true,
      'note': 'Shared gas returned',
    });
    expect(app.book.gasGrams, 100000);
    expect(app.book.balance('inventory'), 3000000);
    expect(app.book.balance('purchase-share:cost'), 0);
    expect(app.book.receivable(shared.party), -100000);
    expect(app.book.money('cash'), 100000);
    expect(app.book.costOfSales, 0);
    expect(app.book.grossProfit, 0);
    final report = buildReport(app, 'Purchase shares', date, date);
    expect(report.rows.last[3].numeric, 0);
    expect(report.rows.last[4].numeric, 0);
    expect(report.rows.last[5].numeric, 0);
    balanced(app.book);
  });

  test(
    'Share corrections, cancellation and a one-paisa cost keep exact balances',
    () async {
      final app = await start(grams: 2000, cost: 1);
      await app.post(share(app, 1000));
      final shared = app.book.documents.last;
      expect(shared.bill, 0); // A cost of one paisa rounds to no charge.
      expect(app.book.balance('purchase-share:cost'), 1);
      expect(app.book.grossProfit, 0);
      await app.post(
        {...shared.data, 'extraGrams': 1500},
        replace: shared,
        reason: 'Correct shared quantity',
      );
      expect(app.book.gasGrams, 500);
      expect(app.book.documents.last.bill, 0);
      await app.voidDocument(app.book.documents.last, 'Sharing cancelled');
      expect(app.book.gasGrams, 2000);
      expect(app.book.balance('inventory'), 1);
      expect(app.book.receivable(shared.party), 0);
    },
  );

  testWidgets(
    'Daily entry defaults bulk to sharing, previews cost and saves without a selling rate',
    (tester) async {
      final app = await start();
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RoznamchaForm(app: app)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder input(String key) => find.descendant(
        of: find.byKey(ValueKey('roz-$key')),
        matching: find.byType(TextField),
      );
      await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Ali');
      await tester.enterText(input('bulk'), '5');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('roz-share-at-cost')),
            )
            .value,
        isTrue,
      );
      expect(
        find.textContaining('Purchase share (at cost): Rs 1,500'),
        findsOneWidget,
      );
      expect(find.text('Rate likhein (11.8 KG ka)'), findsNothing);
      final save = find.byKey(const ValueKey('roz-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final posted = app.book.documents.last;
      expect(posted.bulkAtCost, isTrue);
      expect(posted.bill, 150000);
      expect(posted.rate, 0);
      expect(app.book.gasGrams, 95000);
      expect(app.book.grossProfit, 0);
      tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).edit(posted);
      await tester.pumpAndSettle();
      expect(
        tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).bulkAtCost,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('After saving an ordinary bulk sale the next bulk entry is a share again', (
    tester,
  ) async {
    final app = await start();
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RoznamchaForm(app: app)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder input(String key) => find.descendant(
      of: find.byKey(ValueKey('roz-$key')),
      matching: find.byType(TextField),
    );
    await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Ali');
    await tester.enterText(input('bulk'), '5');
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('roz-share-at-cost'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.enterText(input('rate'), '4600');
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('roz-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.book.documents.last.bulkAtCost, isFalse);
    expect(app.book.documents.last.bulkRevenue, greaterThan(0));
    expect(
      tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).bulkAtCost,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'General composer previews the same share cost and keeps its draft choice',
    (tester) async {
      final app = await start();
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final party = app.partyByName('Ali')!.id;
      Future<void> pump() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EntryComposer(
                app: app,
                initial: EntryType.sale,
                initialParty: party,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump();
      await tester.enterText(
        find.byKey(const ValueKey('field-extraGrams')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('composer-share-at-cost')),
            )
            .value,
        isTrue,
      );
      expect(app.composerDrafts['new-entry']?['bulkCost'], 150000);
      await tester.ensureVisible(
        find.byKey(const ValueKey('composer-share-at-cost')),
      );
      await tester.tap(find.byKey(const ValueKey('composer-share-at-cost')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await pump();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('composer-share-at-cost')),
            )
            .value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
