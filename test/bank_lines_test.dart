import 'dart:async';

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
import 'package:zubair_khata_management/features/reports/reports.dart'
    show buildReport, invoiceReport;
import 'package:zubair_khata_management/ui/details.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';
import 'package:zubair_khata_management/ui/pages.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';
import 'package:zubair_khata_management/ui/roznamcha_widgets.dart';

const day = '2026-11-11';
const masters = [
  Record('c', 'party', {'name': 'Umer', 'customer': true}),
  Record('co', 'party', {'name': 'Supreme Petroleum', 'supplier': true}),
  Record('co2', 'party', {'name': 'Other Company', 'supplier': true}),
  Record('gone', 'party', {'name': 'Deleted Company', 'deleted': true}),
  Record('cash', 'account', {'name': 'Cash'}),
  Record('hbl', 'account', {'name': 'First', 'bank': 'HBL'}),
  Record('mzn', 'account', {'name': 'Second', 'bank': 'Meezan'}),
];
const lines = [
  {'amount': 20000, 'account': 'hbl'},
  {'amount': 30000, 'account': 'mzn'},
  {'amount': 40000, 'party': 'co', 'bankName': 'UBL'},
  {'amount': 50000, 'party': 'co2', 'bankName': ''},
];
Record record(Json data, {String id = 'entry'}) => Record(id, 'document', {
  'type': 'receipt',
  'date': day,
  'party': 'c',
  'occurredAt': 1,
  ...data,
});
Document doc(Json data) => Document(record(data));

Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  app.selectedDate = day;
  for (final r in masters.where((r) => r.id != 'cash')) {
    await app.commit([Change(r.id, r.kind, r.data, 0)]);
  }
  return (app, db);
}

Finder field(String key) => find.descendant(
  of: find.byKey(ValueKey('roz-$key')),
  matching: find.byType(TextField),
);
Finder company([int i = 0]) =>
    find.byKey(ValueKey('roz-direct-party${i == 0 ? '' : '-$i'}'));
Finder bankList([int i = 0]) => i == 0
    ? find.descendant(
        of: find.byType(AccountPicker).first,
        matching: find.byType(DropdownButtonFormField<String>),
      )
    : find.descendant(
        of: find.byKey(ValueKey('roz-account-$i')),
        matching: find.byType(DropdownButtonFormField<String>),
      );

Future<void> pick(WidgetTester tester, int i, String choice) async {
  await tester.ensureVisible(bankList(i));
  await tester.tap(bankList(i));
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice).last);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> form(
  WidgetTester tester,
  AppController app, {
  Key? key,
  Document? replace,
}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RoznamchaForm(app: app, key: key, replace: replace),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> finish(
  WidgetTester tester,
  AppController app,
  KhataDatabase db,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  app.dispose();
  await db.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  test('Legacy lines remain additive, ordered and post exactly as before', () {
    final legacy = record({
      'bank': 100,
      'bankAccount': 'hbl',
      'direct': 200,
      'directParty': 'co',
      'directBank': 'UBL',
    });
    final d = Document(legacy);
    expect(d.bankLines.map((l) => (l.amount, l.account, l.party, l.bankName)), [
      (100, 'hbl', '', ''),
      (200, '', 'co', 'UBL'),
    ]);
    expect(
      Book([...masters, legacy]).postings.map((p) => (p.account, p.debit)),
      [('money:hbl', 100), ('ar:c', -100), ('ap:co', 200), ('ar:c', -200)],
    );
    final additive = doc({...legacy.data, 'bankLines': lines});
    expect(additive.bankLines, hasLength(6));
    expect(additive.bankIn, 50100);
    expect(additive.direct, 90200);
    expect(additive.directTo('co'), 40200);
    expect(additive.directParties, {'co', 'co2'});
    expect(additive.collected, 140300);
  });

  test(
    'Cash, two banks and two companies settle a sale and balance Roznamcha',
    () {
      final sale = record({
        'type': 'sale',
        'quantities': {'11800': 2},
        'returned': {'11800': 2},
        'rate': 100000,
        'cash': 10000,
        'bankLines': lines,
      });
      final book = Book([...masters, sale]);
      expect(book.receivable('c'), 50000);
      expect(book.money('cash'), 10000);
      expect(book.money('hbl'), 20000);
      expect(book.money('mzn'), 30000);
      expect(book.payable('co'), -40000);
      expect(book.payable('co2'), -50000);
      expect(book.invoiceDue['entry'], 50000);
      expect(book.postings.fold(0, (v, p) => v + p.debit), 0);
      final dayView = RoznamchaDay(day, 0, book.documents);
      expect(
        (dayView.cashIn, dayView.bankCust, dayView.direct, dayView.wasooli),
        (10000, 50000, 90000, 150000),
      );
      expect(dayView.safi, book.money('cash'));
      expect(dayView.bankJama.map((l) => (l.account, l.amount, l.automatic)), [
        ('hbl', 20000, true),
        ('mzn', 30000, true),
      ]);
      expect(dayView.directLines.map((l) => (l.party, l.bankName, l.amount)), [
        ('co', 'UBL', 40000),
        ('co2', '', 50000),
      ]);
    },
  );

  test('Bank lines validate shape, limits, destinations, collection and allocations', () {
    void check(Json data, String message) => expect(
      () => validateDocument(doc(data), masters),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', message),
      ),
      reason: '$data',
    );
    for (final raw in <dynamic>[
      {},
      'not an array',
      List.filled(21, {'amount': 1, 'account': 'hbl'}),
      [1],
      [
        {'amount': 1, 'account': 'hbl', 'party': 'co'},
      ],
      [
        {'amount': 1},
      ],
      [
        {'amount': 0, 'account': 'hbl'},
      ],
      [
        {'amount': -1, 'account': 'hbl'},
      ],
      [
        {'amount': 9000000000001, 'account': 'hbl'},
      ],
      [
        {'amount': 1.0, 'account': 'hbl'},
      ],
      [
        {'amount': '1', 'account': 'hbl'},
      ],
      [
        {'amount': 1, 'account': 1},
      ],
      [
        {'amount': 1, 'party': null},
      ],
      [
        {'amount': 1, 'account': 'hbl', 'unknown': 2},
      ],
      [
        {'amount': 1, 'party': 'co', 'bankName': 3},
      ],
      [
        {'amount': 1, 'party': 'co', 'bankName': 'x' * 121},
      ],
    ]) {
      check({'bankLines': raw}, 'Invalid bank lines');
    }
    check({'directBank': 'x' * 121}, 'Invalid bank lines');
    check({
      'type': 'payment',
      'amount': 100,
      'bankLines': lines,
    }, 'Invalid bank lines');
    check({'supplierRefund': true, 'bankLines': lines}, 'Invalid bank lines');
    for (final id in ['cash', 'unknown']) {
      check({
        'bankLines': [
          {'amount': 1, 'account': id},
        ],
      }, 'Choose a bank account');
    }
    for (final id in ['c', 'unknown', 'gone']) {
      check({
        'bankLines': [
          {'amount': 1, 'party': id},
        ],
      }, 'Choose the party that was paid directly');
    }
    validateDocument(doc({'bankLines': lines}), masters);
    validateDocument(doc({'cash': 1, 'bankLines': null}), masters);
    validateDocument(doc({'cash': 1, 'bankLines': []}), masters);
    final bill = record({
      'type': 'sale',
      'quantities': {'11800': 2},
      'rate': 100000,
    }, id: 'bill');
    validateDocument(
      doc({
        'bankLines': lines,
        'allocations': {'bill': 140000},
      }),
      [...masters, bill],
    );
    expect(
      () => validateDocument(
        doc({
          'bankLines': lines,
          'allocations': {'bill': 140001},
        }),
        [...masters, bill],
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Allocation exceeds collection',
        ),
      ),
    );
  });

  test('Only sales and receipts keep bankLines and directBank', () {
    for (final type in EntryType.values) {
      final data = cleanDocumentData({
        'type': type.name,
        'bankLines': lines,
        'directBank': 'UBL',
      });
      final allowed = [EntryType.sale, EntryType.receipt].contains(type);
      expect(data.containsKey('bankLines'), allowed);
      expect(data.containsKey('directBank'), allowed);
      if (allowed) expect(data['bankLines'], same(lines));
    }
  });

  test(
    'Every direct party has entries and deleted parties cannot receive lines',
    () async {
      final (app, db) = await start();
      await app.post(record({'bankLines': lines}).data);
      expect(app.partyHasEntries('co2'), isTrue);
      await expectLater(
        app.deleteParty(app.record('co2')!),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'This party has entries and cannot be deleted',
          ),
        ),
      );
      await expectLater(
        app.post(
          record({
            'bankLines': [
              {'amount': 1, 'party': 'gone'},
            ],
          }).data,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Choose the party that was paid directly',
          ),
        ),
      );
      await app.voidDocument(app.book.documents.single, 'Wrong entry');
      await app.deleteParty(app.record('co2')!);
      expect(app.record('co2')!.deleted, isTrue);
      app.dispose();
      await db.close();
    },
  );

  test(
    'Facts, statements, daily reports and receipts name every destination',
    () async {
      final (app, db) = await start();
      await app.post(
        record({
          'bankLines': [
            ...lines,
            {'amount': 7000, 'party': 'co', 'bankName': 'UBL'},
            {'amount': 3000, 'party': 'co', 'bankName': 'HBL'},
          ],
          'note': 'Online bheje',
        }).data,
      );
      final d = app.book.documents.single;
      const t = Words(false);
      expect(directHeadline(app, d, 'co', t), 'UBL · HBL · Customer: Umer');
      expect(directHeadline(app, d, 'co2', t), 'Customer: Umer');
      expect(d.directTo('co'), 50000);
      final facts = paymentFacts(app, d, t);
      expect(
        facts.where((f) => f.label == 'Bank received').map((f) => f.value),
        ['Rs 200 · First · HBL', 'Rs 300 · Second · Meezan'],
      );
      expect(
        facts.where((f) => f.label == 'Paid directly to party').first.value,
        'Rs 400 · Supreme Petroleum · UBL',
      );
      expect(
        entryHeadline(app, d, t),
        contains('Direct to party 400 (Supreme Petroleum · UBL)'),
      );
      final companyRow = buildReport(
        app,
        'Party statement',
        day,
        day,
        party: 'co',
      ).rows.single;
      expect(
        companyRow[2].text,
        'Bank payment · UBL · HBL · Customer: Umer · Online bheje',
      );
      expect(companyRow[3].numeric, 500);
      final slip = invoiceReport(app, d);
      expect(
        slip.rows.where((r) => r[0].text == 'Bank received'),
        hasLength(2),
      );
      expect(
        slip.rows
            .where((r) => r[0].text == 'Paid directly to party')
            .first[1]
            .text,
        'Supreme Petroleum · UBL',
      );
      final daily = buildReport(app, 'Daily roznamcha', day, day);
      final text = daily.rows.expand((r) => r).map((c) => c.text).join('\n');
      expect(text, contains('Supreme Petroleum · UBL'));
      expect(text, contains('Second'));
      app.dispose();
      await db.close();
    },
  );

  testWidgets(
    'Wasooli adds, removes, saves three destinations and edits all lines',
    (tester) async {
      final (app, db) = await start();
      await form(tester, app);
      await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Umer');
      await tester.enterText(field('cash'), '10');
      await tester.enterText(field('bank'), '100');
      await tester.pumpAndSettle();
      await pick(tester, 0, 'First · HBL');
      await tap(tester, 'roz-add-bank');
      expect(field('bank-1'), findsOneWidget);
      await tester.enterText(field('bank-1'), '200');
      await tester.pumpAndSettle();
      await pick(tester, 1, 'Second · Meezan');
      await tap(tester, 'roz-add-bank');
      await tester.enterText(field('bank-2'), '300');
      await tester.pumpAndSettle();
      await pick(tester, 2, 'Direct to Party');
      await tester.enterText(company(2), 'Naya Company');
      await tester.enterText(field('direct-bank-2'), 'UBL');
      await tester.pumpAndSettle();
      // An empty fourth line is removed; the first three retain entry order.
      await tap(tester, 'roz-add-bank');
      await tap(tester, 'roz-remove-bank-3');
      expect(field('bank-3'), findsNothing);
      await tap(tester, 'roz-save');
      expect(app.book.documents, hasLength(1));
      final d = app.book.documents.single;
      final id = app.partyByName('Naya Company')!.id;
      expect(d.data['bankLines'], [
        {'amount': 10000, 'account': 'hbl'},
        {'amount': 20000, 'account': 'mzn'},
        {'amount': 30000, 'party': id, 'bankName': 'UBL'},
      ]);
      expect(
        (
          d.value('bank'),
          d.bankAccount,
          d.value('direct'),
          d.data['directParty'],
          d.data['directBank'],
        ),
        (0, '', 0, '', ''),
      );
      expect(
        (
          app.book.money('cash'),
          app.book.money('hbl'),
          app.book.money('mzn'),
          app.book.payable(id),
          app.book.receivable('c'),
        ),
        (1000, 10000, 20000, -30000, -61000),
      );
      expect(field('bank-1'), findsNothing);
      final state = tester.state<RoznamchaFormState>(
        find.byType(RoznamchaForm),
      );
      state.edit(d);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('bank')).controller!.text, '100');
      expect(tester.widget<TextField>(field('bank-1')).controller!.text, '200');
      expect(tester.widget<TextField>(field('bank-2')).controller!.text, '300');
      expect(
        tester.widget<TextField>(company(2)).controller!.text,
        'Naya Company',
      );
      expect(
        tester.widget<TextField>(field('direct-bank-2')).controller!.text,
        'UBL',
      );
      expect(rozEditable(d), isTrue);
      await tap(tester, 'roz-save');
      await tester.enterText(find.byType(TextField).last, 'Correct note');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(app.book.documents, hasLength(1));
      expect(app.book.documents.single.data['bankLines'], d.data['bankLines']);
      expect(tester.takeException(), isNull);
      await finish(tester, app, db);
    },
  );

  testWidgets(
    'Repeated new company is created once and drafts retain every field',
    (tester) async {
      final (app, db) = await start();
      app.rozDrafts['page:aamad'] = {
        'party': 'Umer',
        'bank': '100',
        'bankDirect': true,
        'directParty': 'New Gas',
        'directBank': 'UBL',
        'account': 'hbl',
        'extraBanks': [
          {
            'amount': '200',
            'direct': true,
            'company': ' new   GAS ',
            'bankName': 'HBL',
            'account': 'mzn',
          },
          {
            'amount': '',
            'direct': false,
            'company': '',
            'bankName': '',
            'account': 'mzn',
          },
        ],
      };
      await form(tester, app, key: const ValueKey('first'));
      await tester.enterText(field('direct-bank'), 'UBL Lahore');
      await tester.pumpAndSettle();
      // Navigate away and back: in-memory draft restores the full destination.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(app.rozDrafts['page:aamad']!['extraBanks'], hasLength(2));
      await form(tester, app, key: const ValueKey('restored'));
      expect(
        tester.widget<TextField>(field('direct-bank')).controller!.text,
        'UBL Lahore',
      );
      expect(
        tester.widget<TextField>(field('direct-bank-1')).controller!.text,
        'HBL',
      );
      expect(
        find.textContaining('New Gas: Rs 0  →  Advance 300'),
        findsOneWidget,
      );
      await tap(tester, 'roz-save');
      final company = app.partyByName('New Gas')!;
      expect(
        app
            .ofKind('party')
            .where((p) => AppController.nameKey(p.name) == 'new gas'),
        hasLength(1),
      );
      expect(app.book.documents.single.bankLines.map((l) => l.party), [
        company.id,
        company.id,
      ]);
      expect(app.book.payable(company.id), -30000);
      expect(
        app.book.documents.single.data['bankLines'],
        hasLength(2),
        reason: 'zero line ignored',
      );
      await finish(tester, app, db);
    },
  );

  testWidgets(
    'Single destinations keep legacy fields; fill buttons remove extra lines',
    (tester) async {
      final (app, db) = await start();
      await form(tester, app);
      await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Umer');
      await tester.enterText(field('bank'), '100');
      await tester.pumpAndSettle();
      await pick(tester, 0, 'First · HBL');
      await tap(tester, 'roz-save');
      final bank = app.book.documents.single;
      expect((bank.value('bank'), bank.bankAccount), (10000, 'hbl'));
      expect(bank.data.containsKey('bankLines'), isFalse);
      expect(bank.data.containsKey('directBank'), isFalse);
      await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Umer');
      await tester.enterText(field('bank'), '200');
      await tester.pumpAndSettle();
      await pick(tester, 0, 'Direct to Party');
      await tester.enterText(company(), 'Supreme Petroleum');
      await tester.enterText(field('direct-bank'), 'UBL');
      await tester.pumpAndSettle();
      await tap(tester, 'roz-save');
      final direct = app.book.documents.last;
      expect(
        (
          direct.value('bank'),
          direct.bankAccount,
          direct.value('direct'),
          direct.data['directParty'],
          direct.data['directBank'],
        ),
        (0, '', 20000, 'co', 'UBL'),
      );
      expect(direct.data.containsKey('bankLines'), isFalse);
      await tester.enterText(field('q11800'), '1');
      await tester.enterText(field('rate'), '1000');
      await tap(tester, 'roz-add-bank');
      await tap(tester, 'roz-add-bank');
      await tester.tap(find.text('Cash mein dalein'));
      await tester.pumpAndSettle();
      expect(field('bank-1'), findsNothing);
      expect(tester.widget<TextField>(field('bank')).controller!.text, '');
      expect(tester.widget<TextField>(field('cash')).controller!.text, '1000');
      await tap(tester, 'roz-add-bank');
      await tester.tap(find.text('Bank mein dalein'));
      await tester.pumpAndSettle();
      expect(field('bank-1'), findsNothing);
      expect(tester.widget<TextField>(field('cash')).controller!.text, '');
      expect(tester.widget<TextField>(field('bank')).controller!.text, '1000');
      await pick(tester, 0, 'Direct to Party');
      final suggest = tester.widget<SuggestInput>(
        find.byKey(const ValueKey('roz-direct-bank')),
      );
      expect(suggest.suggestions, contains('UBL'));
      await finish(tester, app, db);
    },
  );

  testWidgets(
    'Each nonzero line needs a valid destination and a different company',
    (tester) async {
      final (app, db) = await start();
      await form(tester, app);
      await tester.enterText(find.byKey(const ValueKey('roz-party')), 'Umer');
      await tap(tester, 'roz-add-bank');
      await tester.enterText(field('bank-1'), '100');
      await tester.pumpAndSettle();
      await tap(tester, 'roz-save');
      expect(
        find.text('Bank wasooli ke liye bank / account chunein'),
        findsOneWidget,
      );
      await pick(tester, 1, 'Direct to Party');
      await tap(tester, 'roz-save');
      expect(
        find.text('Direct to Party ke liye party ka naam likhein'),
        findsOneWidget,
      );
      await tester.enterText(company(1), '  UMER ');
      await tester.pumpAndSettle();
      await tap(tester, 'roz-save');
      expect(
        find.text('Direct to Party ke liye customer se alag party chunein'),
        findsOneWidget,
      );
      expect(app.book.documents, isEmpty);
      await finish(tester, app, db);
    },
  );

  testWidgets(
    'Company dialog shows only its amount and Activity finds line parties and accounts',
    (tester) async {
      final (app, db) = await start();
      await app.post(record({'bankLines': lines}).data);
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ActivityPage(app))),
        ),
      );
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byType(ActivityPage));
      unawaited(showParty(ctx, app, app.record('co')!));
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      expect(
        find.descendant(of: dialog, matching: find.text('Bank payment')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('UBL · Customer: Umer'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.descendant(
            of: dialog,
            matching: find.byType(TransactionTile),
          ),
          matching: find.text('Rs 400'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('Rs 900')),
        findsNothing,
      );
      await tester.tap(
        find.descendant(of: dialog, matching: find.byIcon(Icons.close)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Party'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other Company').last);
      await tester.pumpAndSettle();
      expect(find.byType(TransactionTile), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, 'Money'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Second').last);
      await tester.pumpAndSettle();
      expect(find.byType(TransactionTile), findsOneWidget);
      await finish(tester, app, db);
    },
  );

  testWidgets('General composer preserves hydrated bank lines on correction', (
    tester,
  ) async {
    final (app, db) = await start();
    await app.post(
      record({'bankLines': lines, 'directBank': 'Legacy label'}).data,
    );
    final old = app.book.documents.single;
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EntryComposer(app: app, replace: old),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(button);
    await tester.tap(button);
    // The composer shows a progress indicator while the reason dialog is open.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byType(TextField).last,
      'Keep all destinations',
    );
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(app.book.documents.single.data['bankLines'], old.data['bankLines']);
    expect(app.book.documents.single.data['directBank'], 'Legacy label');
    expect(app.book.documents.single.id, isNot(old.id));
    await finish(tester, app, db);
  });
}
