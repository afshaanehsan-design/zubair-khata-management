// Acceptance test for "bank name on Direct to Party" and "several
// Bank Wasooli lines". Written from the brief, independently of the
// implementation's own tests.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/features/reports/reports.dart'
    show buildReport;
import 'package:zubair_khata_management/ui/details.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

const day = '2026-11-02';
var _t = 0;
Record doc(String id, String type, Json data) => Record(id, 'document', {
  'type': type,
  'date': day,
  'occurredAt': ++_t,
  ...data,
});
int rs(int rupees) => rupees * 100;

const masters = [
  Record('umer', 'party', {'name': 'Umer', 'customer': true}),
  Record('supreme', 'party', {'name': 'Supreme', 'supplier': true}),
  Record('pso', 'party', {'name': 'PSO', 'supplier': true}),
  Record('cash', 'account', {'name': 'Cash'}),
  Record('hbl', 'account', {'name': 'Zubair', 'bank': 'HBL'}),
  Record('mzn', 'account', {'name': 'Luqman', 'bank': 'Meezan'}),
];

Json lines() => {
  'bankLines': [
    {'amount': rs(3000), 'account': 'hbl'},
    {'amount': rs(2000), 'account': 'mzn'},
    {'amount': rs(1000), 'party': 'supreme', 'bankName': 'UBL'},
    {'amount': rs(280), 'party': 'pso', 'bankName': ''},
  ],
};

/// The text field keyed `roz-<key>`, whether the key is on the field itself or
/// on a widget around it.
Finder field(String key) {
  final keyed = find.byKey(ValueKey('roz-$key'));
  final inside = find.descendant(of: keyed, matching: find.byType(TextField));
  return inside.evaluate().isNotEmpty ? inside : keyed;
}

Finder byKey(String key) => find.byKey(ValueKey(key));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('A1 Document.bankLines: legacy fields, then the list', () {
    final legacy = Document(
      doc('l', 'receipt', {
        'party': 'umer',
        'bank': rs(5),
        'bankAccount': 'hbl',
        'direct': rs(7),
        'directParty': 'supreme',
        'directBank': 'UBL',
      }),
    );
    expect(
      legacy.bankLines.map((l) => (l.amount, l.account, l.party, l.bankName)),
      [(rs(5), 'hbl', '', ''), (rs(7), '', 'supreme', 'UBL')],
    );
    expect(legacy.bankIn, rs(5));
    expect(legacy.direct, rs(7));
    expect(legacy.collected, rs(12));
    expect(legacy.directParties, {'supreme'});
    final multi = Document(
      doc('m', 'receipt', {'party': 'umer', 'cash': rs(1), ...lines()}),
    );
    expect(multi.bankLines.map((l) => l.direct), [false, false, true, true]);
    expect(multi.bankIn, rs(5000));
    expect(multi.direct, rs(1280));
    expect(multi.directTo('supreme'), rs(1000));
    expect(multi.directTo('pso'), rs(280));
    expect(multi.directTo('hbl'), 0);
    expect(multi.directParties, {'supreme', 'pso'});
    expect(multi.collected, rs(1 + 5000 + 1280));
    final plain = Document(doc('p', 'receipt', {'party': 'umer', 'cash': 5}));
    expect(plain.bankLines, isEmpty);
    expect(plain.direct, 0);
    expect(plain.collected, 5);
  });

  test('A2 Book posts every line; legacy postings unchanged', () {
    final book = Book([
      ...masters,
      doc('sale', 'sale', {
        'party': 'umer',
        'quantities': {'11800': 2},
        'customerOwned': true,
        'rate': rs(4640),
        'cash': rs(3000),
        ...lines(),
      }),
    ]);
    for (final d in book.documents) {
      expect(
        book.postings
            .where((p) => p.document == d.id)
            .fold(0, (v, p) => v + p.debit),
        0,
      );
    }
    expect(book.receivable('umer'), rs(9280 - 3000 - 5000 - 1280));
    expect(book.money('cash'), rs(3000));
    expect(book.money('hbl'), rs(3000));
    expect(book.money('mzn'), rs(2000));
    expect(book.payable('supreme'), -rs(1000));
    expect(book.payable('pso'), -rs(280));
    expect(book.invoiceDue['sale'], 0);

    final legacy = Book([
      ...masters,
      doc('r', 'receipt', {
        'party': 'umer',
        'cash': rs(1),
        'bank': rs(2),
        'bankAccount': 'hbl',
        'direct': rs(3),
        'directParty': 'supreme',
      }),
    ]);
    expect(legacy.postings.map((p) => (p.account, p.debit)).toList(), [
      ('money:cash', rs(1)),
      ('ar:umer', -rs(1)),
      ('money:hbl', rs(2)),
      ('ar:umer', -rs(2)),
      ('ap:supreme', rs(3)),
      ('ar:umer', -rs(3)),
    ]);
  });

  test('A3 Roznamcha: A and B per line, Safi equals cash', () {
    final book = Book([
      ...masters,
      doc('open', 'adjustment', {
        'target': 'money:cash',
        'amount': rs(100000),
        'note': 'Opening',
        'occurredAt': 0,
      }),
      doc('r', 'receipt', {
        'party': 'umer',
        'cash': rs(500),
        ...lines(),
        'form': 'aamad',
      }),
    ]);
    final docs = book.documents.where((d) => d.date == day).toList();
    final opening = book.money('cash') - book.dayMovement(day, 'money:cash');
    final r = RoznamchaDay(day, opening, docs);
    expect(r.cashIn, rs(500));
    expect(r.bankCust, rs(5000));
    expect(r.direct, rs(1280));
    expect(r.safi, book.money('cash'));
    expect(r.safi, rs(100500));
    expect(r.bankJama.map((l) => (l.account, l.amount, l.automatic)), [
      ('hbl', rs(3000), true),
      ('mzn', rs(2000), true),
    ]);
    expect(r.directLines.map((l) => (l.party, l.bankName, l.amount)), [
      ('supreme', 'UBL', rs(1000)),
      ('pso', '', rs(280)),
    ]);
  });

  test('A4 Validation of bank lines', () {
    void fails(String type, Json data, String message) => expect(
      () => validateDocument(Document(doc('x', type, data)), masters),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', message),
      ),
      reason: '$data',
    );
    validateDocument(
      Document(doc('ok', 'receipt', {'party': 'umer', ...lines()})),
      masters,
    );
    validateDocument(
      Document(
        doc('ok2', 'sale', {
          'party': 'umer',
          'quantities': {'11800': 1},
          'customerOwned': true,
          'rate': rs(4640),
          ...lines(),
        }),
      ),
      masters,
    );
    const bad = 'Invalid bank lines';
    // Cash keeps the collection check out of the way of the line checks.
    fails('receipt', {'party': 'umer', 'cash': 1, 'bankLines': 'x'}, bad);
    fails('receipt', {
      'party': 'umer',
      'cash': 1,
      'bankLines': [5],
    }, bad);
    fails('receipt', {
      'party': 'umer',
      'cash': 1,
      'bankLines': [
        {'amount': 0, 'account': 'hbl'},
      ],
    }, bad);
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        {'amount': rs(1), 'account': 'hbl', 'party': 'supreme'},
      ],
    }, bad);
    fails('receipt', {
      'party': 'umer',
      'cash': 1,
      'bankLines': [
        {'amount': rs(1)},
      ],
    }, bad);
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        {'amount': rs(1), 'account': 'hbl', 'junk': 1},
      ],
    }, bad);
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        for (var i = 0; i < 21; i++) {'amount': rs(1), 'account': 'hbl'},
      ],
    }, bad);
    fails('payment', {
      'party': 'umer',
      'amount': rs(1),
      'account': 'cash',
      'bankLines': [
        {'amount': rs(1), 'account': 'hbl'},
      ],
    }, bad);
    fails('receipt', {
      'party': 'supreme',
      'supplierRefund': true,
      'bankLines': [
        {'amount': rs(1), 'account': 'hbl'},
      ],
    }, bad);
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        {'amount': rs(1), 'account': 'cash'},
      ],
    }, 'Choose a bank account');
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        {'amount': rs(1), 'account': 'nope'},
      ],
    }, 'Choose a bank account');
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        {'amount': rs(1), 'party': 'umer'},
      ],
    }, 'Choose the party that was paid directly');
    fails('receipt', {
      'party': 'umer',
      'bankLines': [
        {'amount': rs(1), 'party': 'nobody'},
      ],
    }, 'Choose the party that was paid directly');
    expect(
      cleanDocumentData({'type': 'sale', 'bankLines': [], 'directBank': 'x'})
          .keys,
      containsAll(['bankLines', 'directBank']),
    );
    expect(
      cleanDocumentData({'type': 'receipt', 'bankLines': [], 'directBank': 'x'})
          .keys,
      containsAll(['bankLines', 'directBank']),
    );
    expect(
      cleanDocumentData({'type': 'payment', 'bankLines': [], 'directBank': 'x'})
          .keys,
      ['type'],
    );
  });

  test(
    'A5 Controller: a company in a line has entries, deleted ones refused',
    () async {
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
      final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
      await app.saveMaster('party', {'name': 'Umer', 'customer': true});
      await app.saveMaster('party', {'name': 'Supreme', 'supplier': true});
      await app.saveMaster('party', {'name': 'Gone', 'supplier': true});
      final umer = app.partyByName('Umer')!.id,
          supreme = app.partyByName('Supreme')!.id;
      final gone = app.partyByName('Gone')!;
      await app.deleteParty(gone);
      await expectLater(
        app.post({
          'type': 'receipt',
          'date': day,
          'party': umer,
          'bankLines': [
            {'amount': rs(1), 'account': hbl},
            {'amount': rs(1), 'party': gone.id, 'bankName': ''},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      await app.post({
        'type': 'receipt',
        'date': day,
        'party': umer,
        'bankLines': [
          {'amount': rs(1), 'account': hbl},
          {'amount': rs(2), 'party': supreme, 'bankName': 'UBL'},
        ],
      });
      expect(app.partyHasEntries(supreme), isTrue);
      await expectLater(
        app.deleteParty(app.record(supreme)!),
        throwsA(isA<FormatException>()),
      );
      // A legacy bank + direct entry opens in the Roznamcha form again.
      expect(
        rozEditable(
          Document(
            Record('both', 'document', {
              'type': 'receipt',
              'date': day,
              'party': umer,
              'bank': 1,
              'bankAccount': hbl,
              'direct': 1,
              'directParty': supreme,
              'form': 'aamad',
            }),
          ),
        ),
        isTrue,
      );
      app.dispose();
      await db.close();
    },
  );

  testWidgets(
    'A6 The Wasooli form: + lines, direct with bank name, edit, khata',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
      await app.saveMaster('account', {'name': 'Luqman', 'bank': 'Meezan'});
      final hbl = app
          .ofKind('account')
          .firstWhere((a) => a.data['bank'] == 'HBL')
          .id;
      final mzn = app
          .ofKind('account')
          .firstWhere((a) => a.data['bank'] == 'Meezan')
          .id;
      await app.saveMaster('party', {'name': 'Umer', 'customer': true});
      final umer = app.partyByName('Umer')!.id;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RoznamchaForm(app: app)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> choose(Finder dropdown, String item) async {
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(item).last);
        await tester.pumpAndSettle();
      }

      Finder picker(int i) => i == 0
          ? find.byType(DropdownButtonFormField<String>).first
          : find.descendant(
              of: byKey('roz-account-$i'),
              matching: find.byType(DropdownButtonFormField<String>),
            );

      // 1) Single direct line with a bank name: legacy fields + directBank.
      await tester.enterText(byKey('roz-party'), 'Umer');
      await tester.enterText(field('bank'), '700');
      await tester.pump();
      await choose(picker(0), 'Direct to Party');
      await tester.enterText(byKey('roz-direct-party'), 'Supreme');
      await tester.pump();
      expect(field('direct-bank'), findsOneWidget);
      await tester.enterText(field('direct-bank'), 'Meezan Supreme');
      await tester.pump();
      await tester.tap(byKey('roz-save'));
      await tester.pumpAndSettle();
      final single = app.book.documents.last;
      expect(single.data.containsKey('bankLines'), isFalse);
      expect(single.value('direct'), rs(700));
      expect(single.data['directBank'], 'Meezan Supreme');
      final supreme = app.partyByName('Supreme')!.id;
      expect(single.data['directParty'], supreme);

      // 2) + adds lines; remove works.
      await tester.enterText(byKey('roz-party'), 'Umer');
      await tester.tap(byKey('roz-add-bank'));
      await tester.pumpAndSettle();
      expect(field('bank-1'), findsOneWidget);
      await tester.tap(byKey('roz-remove-bank-1'));
      await tester.pumpAndSettle();
      expect(field('bank-1'), findsNothing);

      // 3) Three lines: HBL, Meezan, Direct to a NEW company with a bank name,
      //    and a 4th line to the same new name: one party only.
      await tester.enterText(field('q11800'), '2');
      await tester.enterText(field('rate'), '4640');
      await tester.enterText(field('cash'), '1000');
      await tester.enterText(field('bank'), '3000');
      await tester.pump();
      await choose(picker(0), 'Zubair · HBL');
      for (final (i, amount) in [(1, '2000'), (2, '3000'), (3, '280')]) {
        await tester.tap(byKey('roz-add-bank'));
        await tester.pumpAndSettle();
        await tester.enterText(field('bank-$i'), amount);
        await tester.pump();
      }
      await choose(picker(1), 'Luqman · Meezan');
      await choose(picker(2), 'Direct to Party');
      await tester.enterText(byKey('roz-direct-party-2'), 'Naya Company');
      await tester.enterText(field('direct-bank-2'), 'UBL');
      await choose(picker(3), 'Direct to Party');
      await tester.enterText(byKey('roz-direct-party-3'), 'naya  company');
      await tester.pump();
      await tester.tap(byKey('roz-save'));
      await tester.pumpAndSettle();
      final multi = app.book.documents.last;
      expect(
        multi.type,
        EntryType.sale,
        reason: 'saved: ${app.book.documents.length}',
      );
      final naya = app.partyByName('Naya Company')!;
      expect(
        app
            .ofKind('party')
            .where((p) => AppController.nameKey(p.name) == 'naya company'),
        hasLength(1),
      );
      expect(naya.data['supplier'], true);
      expect(multi.data['bankLines'], [
        {'amount': rs(3000), 'account': hbl},
        {'amount': rs(2000), 'account': mzn},
        {'amount': rs(3000), 'party': naya.id, 'bankName': 'UBL'},
        {'amount': rs(280), 'party': naya.id, 'bankName': ''},
      ]);
      expect(multi.value('bank'), 0);
      expect(multi.value('direct'), 0);
      expect(app.book.money(hbl), rs(3000));
      expect(app.book.money(mzn), rs(2000));
      expect(app.book.money('cash'), rs(1000));
      expect(app.book.payable(naya.id), -rs(3280));
      expect(app.book.payable(supreme), -rs(700));
      expect(app.book.receivable(umer), -rs(700));
      // After save the extra lines are gone.
      expect(field('bank-1'), findsNothing);

      // 4) ✏️ loads all lines back.
      tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).edit(multi);
      await tester.pumpAndSettle();
      String text(String key) =>
          tester.widget<TextField>(field(key)).controller!.text;
      expect(text('bank'), '3000');
      expect(text('bank-1'), '2000');
      expect(text('bank-2'), '3000');
      expect(text('bank-3'), '280');
      expect(
        tester.widget<TextField>(byKey('roz-direct-party-2')).controller!.text,
        'Naya Company',
      );
      expect(text('direct-bank-2'), 'UBL');
      tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).cancelEdit();
      await tester.pumpAndSettle();

      // 5) Single bank line keeps today's shape.
      await tester.enterText(byKey('roz-party'), 'Umer');
      await tester.enterText(field('bank'), '500');
      await tester.pump();
      await choose(picker(0), 'Zubair · HBL');
      await tester.tap(byKey('roz-save'));
      await tester.pumpAndSettle();
      final plain = app.book.documents.last;
      expect(plain.data.containsKey('bankLines'), isFalse);
      expect(plain.value('bank'), rs(500));
      expect(plain.bankAccount, hbl);

      // 6) The company's khata: a bank payment, only its own amount.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionTile(app, multi, showParty: false, khata: naya.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bank payment'), findsOneWidget);
      expect(find.text('UBL · Customer: Umer'), findsOneWidget);
      expect(find.text('Rs 3,280'), findsOneWidget);
      final row = buildReport(
        app,
        'Party statement',
        app.selectedDate,
        app.selectedDate,
        party: naya.id,
      ).rows.firstWhere((r) => r[2].text.startsWith('Bank payment'));
      expect(row[2].text, 'Bank payment · UBL · Customer: Umer');
      expect(row[3].numeric, 3280);
      final supremeRow = buildReport(
        app,
        'Party statement',
        app.selectedDate,
        app.selectedDate,
        party: supreme,
      ).rows.firstWhere((r) => r[2].text.startsWith('Bank payment'));
      expect(
        supremeRow[2].text,
        'Bank payment · Meezan Supreme · Customer: Umer',
      );

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await db.close();
    },
  );
}
