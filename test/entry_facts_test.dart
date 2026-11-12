import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/entry_facts.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/details.dart';
import 'package:zubair_khata_management/ui/pages.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

/// Records every label asked for, to prove each one has an Urdu translation.
class _Recording extends Words {
  final seen = <String>{};
  _Recording() : super(true);
  @override
  String call(String text) {
    seen.add(text);
    return super.call(text);
  }
}

const en = Words(false);

Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

Document doc(AppController app, bool Function(Document) test) =>
    app.book.documents.firstWhere(test);

/// Ali Raza owes an opening balance, pays part of it, then buys 20 cylinders
/// and pays Rs 200,000 cash: the cash goes to the older balance, so the new
/// bill is still due in full.
Future<String> aliWithOlderBalance(AppController app) async {
  await app.saveMaster(
    'party',
    {'name': 'Ali Raza', 'customer': true},
    opening: 180548800,
    openingDate: '2026-11-01',
  );
  final ali = app.partyByName('Ali Raza')!.id;
  await app.post({
    'type': 'receipt',
    'date': '2026-11-01',
    'party': ali,
    'cash': 24000000,
  });
  await app.post({
    'type': 'sale',
    'date': '2026-11-02',
    'party': ali,
    'quantities': {'11800': 20},
    'rate': 1349100,
    'cash': 20000000,
  });
  return ali;
}

/// Four parties: one owes you, one you owe as a company, one owes you and is
/// also owed (customer and supplier), one is settled.
Future<void> mixedParties(AppController app) async {
  await app.saveMaster('party', {
    'name': 'Owes',
    'customer': true,
  }, opening: 100000);
  await app.saveMaster('party', {
    'name': 'Company',
    'customer': true,
  }, supplierOpening: 30000);
  await app.saveMaster(
    'party',
    {'name': 'Both', 'customer': true},
    opening: 100000,
    supplierOpening: 30000,
  );
  await app.saveMaster('party', {'name': 'Clear', 'customer': true});
}

void main() {
  test('A party shows what it owes you and what you owe it', () async {
    final (app, db) = await start();
    await mixedParties(app);
    await app.saveMaster('party', {'name': 'Advance', 'customer': true});
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': app.partyByName('Advance')!.id,
      'cash': 50000,
    });
    ({int receive, int pay}) owed(String name) =>
        partyOwed(app.book, app.partyByName(name)!.id);
    expect(owed('Owes'), (receive: 100000, pay: 0));
    expect(owed('Company'), (receive: 0, pay: 30000));
    expect(owed('Both'), (receive: 100000, pay: 30000));
    expect(owed('Clear'), (receive: 0, pay: 0));
    // Paid before buying anything: you owe the customer the advance.
    expect(owed('Advance'), (receive: 0, pay: 50000));
    app.dispose();
    await db.close();
  });

  testWidgets(
    'Parties: newest first on the left, the chosen party on the right',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (app, db) = await start();
      await mixedParties(app); // Owes, Company, Both, Clear: in that order.
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PartiesPage(app))),
      );
      await tester.pumpAndSettle();

      Finder inList(String text) =>
          find.descendant(of: find.byKey(PartiesPage.listKey), matching: find.text(text));
      Finder inDetails(Finder f) =>
          find.descendant(of: find.byType(PartyDetails), matching: f);
      final names = ['Clear', 'Both', 'Company', 'Owes'];
      final tops = [for (final n in names) tester.getTopLeft(inList(n)).dy];
      expect(tops, [...tops]..sort(), reason: 'newest first');
      // The list is on the left, the details on the right.
      expect(
        tester.getTopRight(find.byKey(PartiesPage.listKey)).dx,
        lessThan(tester.getTopLeft(find.byType(PartyDetails)).dx),
      );
      // The newest is shown until another is picked.
      expect(inDetails(find.text('Clear')), findsOneWidget);

      // Each row says what is owed either way, on the far side.
      expect(inList('Settled'), findsOneWidget);
      expect(inList('Rs 1,000'), findsNWidgets(2)); // Owes and Both
      expect(inList('Rs 300'), findsNWidgets(2)); // Company and Both
      expect(inList('You will pay'), findsNWidgets(2));
      expect(
        tester.getTopRight(inList('Rs 300').first).dx,
        closeTo(tester.getTopRight(find.byKey(PartiesPage.listKey)).dx - 12, 2),
      );

      await tester.tap(inList('Both'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing, reason: 'shown beside');
      expect(inDetails(find.text('Both')), findsOneWidget);
      expect(inDetails(find.text('Clear')), findsNothing);
      expect(
        inDetails(find.text('Net: you will receive Rs 700')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // On a narrow screen a tap opens the details as a dialog instead.
      tester.view.physicalSize = const Size(600, 1000);
      await tester.pumpAndSettle();
      expect(find.byType(PartyDetails), findsNothing);
      await tester.tap(find.text('Company'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(PartyDetails),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );

  testWidgets(
    'An Udhari khata leads with Udhar wapsi and shows what is still owed',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (app, db) = await start();
      await app.saveMaster(
        'party',
        {'name': 'Ustad Usman', 'customer': false, 'udhari': true},
        supplierOpening: 322500000,
        openingDate: '2026-10-31',
      );
      final usman = app.partyByName('Ustad Usman')!;
      await app.post({
        'type': 'payment',
        'date': '2026-11-01',
        'party': usman.id,
        'amount': 150000000,
        'account': 'cash',
        'supplierPayment': true,
        'form': 'udharWapsi',
        'note': 'Malik Abbas le gaya',
      });
      final opening = doc(app, (d) => d.type == EntryType.adjustment);
      final wapsi = doc(app, (d) => d.type == EntryType.payment);
      expect(entryTypeLabel(wapsi, en), 'Udhar wapsi');
      expect(entryHeadline(app, opening, en), 'Udhar liya — aap ne dena hai');
      // Running balance of an Udhari party: what you still owe it.
      final balances = partyBalances(app.book, usman.id);
      expect(balances[opening.id], -322500000);
      expect(balances[wapsi.id], -172500000);
      expect(balanceText(balances[wapsi.id]!, en), 'You owe Rs 1,725,000');

      // The type a payment from each kind of khata starts on.
      expect(kharchaKindFor(usman), KharchaKind.udharWapsi);
      expect(
        kharchaKindFor(const Record('p', 'party', {'supplier': true})),
        KharchaKind.company,
      );
      expect(
        kharchaKindFor(const Record('c', 'party', {'customer': true})),
        KharchaKind.customer,
      );

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PartyDetails(app, usman))),
      );
      await tester.pumpAndSettle();
      final pay = find.byKey(const ValueKey('party-pay'));
      expect(tester.widget(pay), isA<FilledButton>());
      expect(
        find.descendant(of: pay, matching: find.text('Udhar wapsi')),
        findsOneWidget,
      );
      // The Activity row is named and carries the balance after it.
      expect(find.text('Udhar wapsi'), findsNWidgets(2));
      expect(find.text('You owe Rs 1,725,000'), findsOneWidget);
      expect(find.text('You owe Rs 3,225,000'), findsOneWidget);
      expect(find.text('Udhar liya — aap ne dena hai'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The button opens the Kharcha tab on Udhar wapsi for this party.
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(find.text('Khata: Ustad Usman'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('roz-party')))
            .controller!
            .text,
        'Ustad Usman',
      );
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Udhar wapsi'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );

  test('A sale lists its cylinders, rate and why it is still due', () async {
    final (app, db) = await start();
    final ali = await aliWithOlderBalance(app);
    final sale = doc(app, (d) => d.type == EntryType.sale);

    expect(sale.saleLines, hasLength(1));
    expect(sale.saleLines.single.size, 11800);
    expect(sale.saleLines.single.count, 20);
    expect(sale.saleLines.single.amount, 26982000);
    expect(sale.lineRounding, 0);

    expect(entryTitle(app, sale, en), 'Ali Raza');
    expect(entryHeadline(app, sale, en), '11.8 KG × 20 · Rate 13,491');
    expect(entryAmountText(sale), 'Rs 269,820');
    final status = entryStatus(app, sale, en)!;
    expect(status.label, 'Due Rs 269,820');
    expect(status.warning, isTrue);

    final rows = billRows(sale, en);
    expect(rows.single.label, '11.8 KG × 20');
    expect(rows.single.caption, '236 KG');
    expect(rows.single.amount, 26982000);

    final payment = paymentFacts(app, sale, en);
    expect(payment.map((f) => f.label), [
      'Cash received',
      'Still due on this bill',
    ]);
    expect(payment.first.value, 'Rs 200,000');
    expect(payment.last.value, 'Rs 269,820');

    // The cash went to the older (opening) balance, and the screen says so.
    final notes = paymentNotes(app, sale, en);
    expect(notes, hasLength(1));
    expect(notes.single, contains('Rs 200,000'));
    expect(notes.single, contains('older balance'));
    expect(billPayments(app, sale, en), isEmpty);

    final receipt = doc(app, (d) => d.type == EntryType.receipt);
    expect(paymentNotes(app, receipt, en).single, contains('Rs 240,000'));

    // Running balance after each entry, like a khata.
    final balances = partyBalances(app.book, ali);
    final opening = doc(app, (d) => d.type == EntryType.adjustment);
    expect(balances[opening.id], 180548800);
    expect(balances[receipt.id], 156548800);
    expect(balances[sale.id], 156548800 + 26982000 - 20000000);
    expect(balanceText(balances[sale.id]!, en), 'Owes you Rs 1,635,308');
    expect(balanceText(0, en), 'Settled');
    expect(balanceText(-5000, en), 'You owe Rs 50');

    expect(entryTypeLabel(opening, en), 'Opening balance');
    expect(entryTitle(app, opening, en), 'Ali Raza');
    expect(entryHeadline(app, opening, en), 'Customer owes you');
    app.dispose();
    await db.close();
  });

  test(
    'A paid sale says Paid, shows the bank, and lists later payments',
    () async {
      final (app, db) = await start();
      await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
      final bank = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
      await app.saveMaster('party', {'name': 'Bilal', 'customer': true});
      final bilal = app.partyByName('Bilal')!.id;
      await app.post({
        'type': 'sale',
        'date': '2026-11-02',
        'party': bilal,
        'quantities': {'11800': 2, '45000': 1},
        'returned': {'11800': 1},
        'rate': 400000,
        'extraGrams': 500,
        'bank': 1000000,
        'bankAccount': bank,
        'vehicle': 'P-12',
      });
      var sale = doc(app, (d) => d.type == EntryType.sale);
      expect(entryStatus(app, sale, en)!.label, startsWith('Due Rs '));
      expect(
        entryHeadline(app, sale, en),
        '11.8 KG × 2, 45 KG × 1, +0.5 KG Extra KG · Rate 4,000',
      );
      final payment = paymentFacts(app, sale, en);
      expect(payment[0].label, 'Bank received');
      expect(payment[0].value, 'Rs 10,000 · Zubair · HBL');
      expect(payment.any((f) => f.label == 'Cash received'), isFalse);
      expect(paymentNotes(app, sale, en), isEmpty);

      final cylinders = cylinderFacts(app, sale, en);
      expect(cylinders.first.label, '11.8 KG');
      expect(cylinders.first.value, 'Delivered 2 · Empties returned 1');
      expect(cylinders.last.label, 'Customer holds now');
      expect(cylinders.last.value, '11.8 KG × 1, 45 KG × 1');

      final due = app.book.invoiceDue[sale.id]!;
      await app.post({
        'type': 'receipt',
        'date': '2026-11-03',
        'party': bilal,
        'cash': due,
      });
      sale = doc(app, (d) => d.type == EntryType.sale);
      expect(entryStatus(app, sale, en)!.label, 'Paid');
      final received = billPayments(app, sale, en);
      expect(received, hasLength(1));
      expect(received.single.label, startsWith('Receipt · 2026-11-03'));
      expect(received.single.value, 'Rs ${money(due)}');
      expect(received.single.openId, isNotNull);

      final receipt = doc(app, (d) => d.type == EntryType.receipt);
      final applied = appliedFacts(app, receipt, en);
      expect(applied.single.openId, sale.id);
      expect(paymentNotes(app, receipt, en), isEmpty);

      // Nothing is shown with an empty value: no "Bank received 0 ·".
      for (final d in app.book.documents) {
        for (final f in [
          ...paymentFacts(app, d, en),
          ...detailFacts(app, d, en),
          ...cylinderFacts(app, d, en),
        ]) {
          expect(f.value.trim(), isNotEmpty, reason: f.label);
          expect(f.value.trim(), isNot(endsWith('·')), reason: f.label);
        }
      }
      app.dispose();
      await db.close();
    },
  );

  test('Every type of entry can be described, in both languages', () async {
    final (app, db) = await start();
    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    final bank = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    await app.saveMaster('party', {'name': 'Bilal', 'customer': true});
    await app.saveMaster('party', {'name': 'PSO', 'supplier': true});
    final bilal = app.partyByName('Bilal')!.id,
        pso = app.partyByName('PSO')!.id;
    const date = '2026-11-02';
    await app.post({
      'type': 'purchase',
      'date': date,
      'party': pso,
      'grams': 1000000,
      'rate': 30000,
      'rateUnit': 1000,
      'amount': 10000000,
      'account': 'cash',
    });
    await app.post({
      'type': 'sale',
      'date': date,
      'party': bilal,
      'quantities': {'11800': 5},
      'rate': 400000,
      'cash': 500000,
    });
    final sale = doc(app, (d) => d.type == EntryType.sale);
    for (final entry in <Json>[
      {
        'type': 'receipt',
        'party': bilal,
        'cash': 100000,
        'bank': 200000,
        'bankAccount': bank,
      },
      {'type': 'receipt', 'party': pso, 'cash': 100000, 'supplierRefund': true},
      {'type': 'payment', 'party': bilal, 'amount': 50000, 'account': 'cash'},
      {
        'type': 'payment',
        'party': pso,
        'amount': 50000,
        'account': bank,
        'supplierPayment': true,
        'branch': 'Lahore',
        'customerNote': 'Ahmed',
      },
      {
        'type': 'expense',
        'amount': 25000,
        'account': 'cash',
        'category': 'Diesel run',
      },
      {
        'type': 'transfer',
        'amount': 25000,
        'account': 'cash',
        'toAccount': bank,
      },
      {'type': 'discount', 'party': bilal, 'amount': 1000},
      {'type': 'deposit', 'party': bilal, 'amount': 300000, 'account': 'cash'},
      {
        'type': 'depositRefund',
        'party': bilal,
        'amount': 100000,
        'account': 'cash',
      },
      {
        'type': 'adjustment',
        'target': 'money:cash',
        'amount': 5000,
        'note': 'Cash count',
      },
      {'type': 'stockAdjustment', 'grams': 50000, 'note': 'Found'},
      {'type': 'stockAdjustment', 'grams': -20000, 'note': 'Leak'},
      {
        'type': 'cylinder',
        'party': bilal,
        'size': 11800,
        'cylinderMode': 'Issue',
        'count': 2,
        'fullDelta': -2,
        'emptyDelta': 0,
        'heldDelta': 2,
        'note': 'Loan',
      },
      {
        'type': 'cylinder',
        'size': 15000,
        'cylinderMode': 'Acquire',
        'acquireFull': true,
        'count': 4,
        'fullDelta': 4,
        'emptyDelta': 0,
        'heldDelta': 0,
        'note': 'New',
      },
      {
        'type': 'creditNote',
        'party': bilal,
        'sourceInvoice': sale.id,
        'stockReturned': true,
        'quantities': {'11800': 5},
        'rate': 400000,
        'note': 'Returned',
      },
    ]) {
      await app.post({'date': date, ...entry});
    }
    // A voided entry stays readable and says so.
    final expense = doc(app, (d) => d.type == EntryType.expense);
    await app.voidDocument(expense, 'Typed twice');
    final voided = Document(app.record(expense.id)!);
    expect(entryStatus(app, voided, en)!.label, 'Voided');
    expect(paymentNotes(app, voided, en), isEmpty);

    final all = [...app.book.documents, voided];
    expect(all.map((d) => d.type).toSet(), hasLength(greaterThan(12)));

    final urdu = _Recording();
    for (final d in all) {
      for (final t in [en, urdu]) {
        expect(entryTypeLabel(d, t), isNotEmpty);
        expect(entryTitle(app, d, t), isNotEmpty, reason: '${d.type}');
        expect(entryAmountText(d), isNotEmpty);
        entryHeadline(app, d, t);
        entryStatus(app, d, t);
        entryAmountLabel(d, t);
        billRows(d, t);
        cylinderFacts(app, d, t);
        paymentFacts(app, d, t);
        paymentNotes(app, d, t);
        billPayments(app, d, t);
        appliedFacts(app, d, t);
        for (final f in detailFacts(app, d, t)) {
          expect(f.value.trim(), isNotEmpty, reason: '${d.type} ${f.label}');
        }
      }
    }
    for (final p in app.book.postings) {
      expect(postingLabel(app, p.account, en), isNot(contains(':')));
      postingLabel(app, p.account, urdu);
    }
    for (final n in [-1, 0, 1]) {
      balanceText(n, urdu);
    }
    // Spot checks of what the user reads.
    String headline(EntryType type, [bool Function(Document)? where]) =>
        entryHeadline(
          app,
          all.firstWhere((d) => d.type == type && (where?.call(d) ?? true)),
          en,
        );
    expect(headline(EntryType.purchase), '1,000 KG · Rate 300 per KG');
    expect(
      headline(EntryType.cylinder, (d) => d.party.isNotEmpty),
      '11.8 KG · Issue · Full -2 · Customer-held +2',
    );
    expect(
      entryAmountText(all.firstWhere((d) => d.type == EntryType.cylinder)),
      '2 × 11.8 KG',
    );
    expect(
      entryAmountText(
        all.firstWhere(
          (d) => d.type == EntryType.stockAdjustment && d.value('grams') < 0,
        ),
      ),
      '-20 KG',
    );
    expect(
      entryTitle(app, all.firstWhere((d) => d.type == EntryType.transfer), en),
      'Cash → Zubair · HBL',
    );
    final purchase = all.firstWhere((d) => d.type == EntryType.purchase);
    expect(entryStatus(app, purchase, en)!.label, 'You owe Rs 200,000');

    // Only the user's own text (an expense category) may lack a translation.
    final missing = urdu.seen.where((k) => !Words.hasUrdu(k)).toSet()
      ..remove('Diesel run');
    expect(missing, isEmpty, reason: 'Add these to l10n.dart');
    app.dispose();
    await db.close();
  });

  test('A historical summary reads as gas and money', () async {
    final (app, db) = await start();
    await app.post({
      'type': 'historicalSale',
      'date': '2026-11-02',
      'grams': 118000,
      'amount': 5000000,
    });
    final d = doc(app, (d) => d.type == EntryType.historicalSale);
    expect(entryHeadline(app, d, en), '118 KG');
    expect(entryAmountText(d), 'Rs 50,000');
    expect(detailFacts(app, d, en).single.value, '118');
    app.dispose();
    await db.close();
  });

  testWidgets(
    'The details dialog explains the sale and the party ledger shows balances',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (app, db) = await start();
      await aliWithOlderBalance(app);
      final sale = doc(app, (d) => d.type == EntryType.sale);
      final ali = app.partyByName('Ali Raza')!;

      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      unawaited(showTransaction(context, app, sale));
      await tester.pumpAndSettle();
      expect(find.text('What was sold'), findsOneWidget);
      // The bill line, and what the customer holds now.
      expect(find.text('11.8 KG × 20'), findsNWidgets(2));
      expect(find.text('Customer holds now'), findsOneWidget);
      expect(find.text('236 KG'), findsOneWidget);
      expect(find.text('Rate per 11.8 KG'), findsOneWidget);
      expect(find.text('Rs 13,491'), findsOneWidget);
      expect(find.text('Still due on this bill'), findsOneWidget);
      expect(find.text('Due Rs 269,820'), findsOneWidget);
      expect(
        find.textContaining('Rs 200,000 of the money received'),
        findsOneWidget,
      );
      expect(find.text('Accounting entries'), findsOneWidget);
      // Not signed in: no sync state that would read like "unpaid".
      expect(find.text('Waiting to sync'), findsNothing);
      expect(find.text('Pending'), findsNothing);
      // No dangling separator such as "Bank received  0 ·".
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').trim().endsWith('·'),
        ),
        findsNothing,
      );
      Navigator.of(context, rootNavigator: true).pop();
      await tester.pumpAndSettle();

      unawaited(showParty(context, app, ali));
      await tester.pumpAndSettle();
      expect(find.text('Unpaid invoices'), findsOneWidget);
      expect(find.text('Cylinders with customer'), findsOneWidget);
      expect(find.text('Opening balance'), findsWidgets);
      expect(find.text('11.8 KG × 20 · Rate 13,491'), findsOneWidget);
      expect(find.text('Owes you Rs 1,635,308'), findsOneWidget);
      expect(find.text('Owes you Rs 1,805,488'), findsOneWidget);
      expect(
        find.textContaining('Bill Rs 269,820 · Paid Rs 0'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      app.dispose();
      await db.close();
    },
  );
}
