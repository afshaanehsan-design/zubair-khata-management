import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/entry_facts.dart'
    show partyOwed;
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

Finder field(String key) => key == 'party'
    ? find.byKey(const ValueKey('roz-party'))
    : find.descendant(
        of: find.byKey(ValueKey('roz-$key')),
        matching: find.byType(TextField),
      );
Finder tab(String name) => find.byKey(ValueKey('roz-tab-$name'));
final save = find.byKey(const ValueKey('roz-save'));
String text(WidgetTester tester, String key) =>
    tester.widget<TextField>(field(key)).controller!.text;

Future<(AppController, KhataDatabase)> start(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
  return (app, db);
}

Future<void> pumpForm(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: RoznamchaForm(app: app)),
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
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  app.dispose();
  await db.close();
}

Future<void> chooseAccount(WidgetTester tester, {int index = 0}) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).at(index));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Zubair · HBL').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Naya Entry shows six tabs, without Opening Theek Karo', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    await pumpForm(tester, app);
    expect(RozTab.values, hasLength(6));
    for (final t in RozTab.values) {
      expect(tab(t.name), findsOneWidget);
    }
    expect(tab('opening'), findsNothing);
    expect(find.text('Opening Theek Karo'), findsNothing);
    expect(find.text(RozTab.aamad.description), findsOneWidget);
    await tester.tap(tab('kharcha'));
    await tester.pumpAndSettle();
    expect(find.text(RozTab.kharcha.description), findsOneWidget);
    await tester.tap(find.text('Cash kharcha'));
    await tester.pumpAndSettle();
    for (final k in KharchaKind.values) {
      expect(find.text(k.label), findsWidgets);
    }
    await finish(tester, app, db);
  });

  testWidgets(
    'Aamad: typed customer is created and the bill matches the HTML',
    (tester) async {
      final (app, db) = await start(tester);
      await pumpForm(tester, app);
      await tester.enterText(field('party'), 'Ali Traders');
      await tester.pump();
      expect(find.text('Naya customer banega'), findsOneWidget);
      await tester.enterText(field('vehicle'), '92');
      await tester.enterText(field('q11800'), '2');
      await tester.enterText(field('rate'), '4640');
      await tester.pump();
      expect(find.textContaining('Bill: Rs 9,280'), findsOneWidget);
      await tester.tap(find.text('Cash mein dalein'));
      await tester.pump();
      expect(text(tester, 'cash'), '9280');
      await tester.tap(save);
      await tester.pumpAndSettle();
      final ali = app.partyByName('ali traders')!;
      expect(ali.data['customer'], true);
      final sale = app.book.documents.single;
      expect(sale.type, EntryType.sale);
      expect(sale.party, ali.id);
      expect(sale.data['form'], 'aamad');
      expect(sale.data['vehicle'], '92');
      expect(sale.bill, 928000);
      expect(app.book.money('cash'), 928000);
      expect(app.book.receivable(ali.id), 0);
      expect(find.textContaining('Save ho gaya'), findsOneWidget);
      // The rate stays for the next customer; the rest is cleared.
      expect(text(tester, 'rate'), '4640');
      expect(text(tester, 'party'), '');

      // Wasooli without cylinders is a receipt for the same customer.
      await tester.enterText(field('party'), 'ali traders');
      await tester.enterText(field('vehicle'), '93');
      await tester.enterText(field('bank'), '1000');
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(
        find.text('Bank wasooli ke liye bank / account chunein'),
        findsOneWidget,
      );
      await chooseAccount(tester);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final receipt = app.book.documents.last;
      expect(receipt.type, EntryType.receipt);
      expect(receipt.party, ali.id);
      expect(receipt.data['vehicle'], '93');
      expect(app.ofKind('party').length, 1);
      expect(app.book.receivable(ali.id), -100000);

      // Cylinders without a rate are refused instead of billing nothing.
      await tester.enterText(field('party'), 'Ali Traders');
      await tester.enterText(field('q15000'), '1');
      await tester.enterText(field('rate'), '');
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(find.text('Rate likhein (11.8 KG ka)'), findsWidgets);
      expect(app.book.documents.length, 2);
      await finish(tester, app, db);
    },
  );

  testWidgets('Kharcha, Bank jama, Nikali and Office move cash like the HTML', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    await pumpForm(tester, app);
    await tester.tap(tab('kharcha'));
    await tester.pumpAndSettle();
    await tester.enterText(field('amount'), '500');
    await tester.tap(save);
    await tester.pump();
    expect(find.text('Tafseel likhna zaroori hai'), findsOneWidget);
    await tester.enterText(field('note'), 'Chai');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.book.documents.last.type, EntryType.expense);
    expect(app.book.money('cash'), -50000);

    await tester.tap(find.text('Cash kharcha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank account mein jama').last);
    await tester.pumpAndSettle();
    await chooseAccount(tester, index: 1);
    await tester.enterText(field('amount'), '2000');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(rozFormOf(app.book.documents.last), RozForm.bankJama);
    expect(app.book.money(hbl), 200000);
    expect(app.book.money('cash'), -250000);

    // The chosen account carries over to Bank se Cash Nikala.
    await tester.tap(tab('nikali'));
    await tester.pumpAndSettle();
    await tester.enterText(field('amount'), '1000');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(rozFormOf(app.book.documents.last), RozForm.nikali);
    expect(app.book.money(hbl), 100000);
    expect(app.book.money('cash'), -150000);

    await tester.tap(tab('office'));
    await tester.pumpAndSettle();
    await tester.enterText(field('note'), 'Bijli bill');
    await tester.enterText(field('amount'), '300');
    await tester.tap(save);
    await tester.pumpAndSettle();
    final office = app.book.documents.last;
    expect(office.data['category'], 'Office');
    expect(rozFormOf(office), RozForm.office);
    expect(app.book.money('cash'), -180000);
    expect(app.book.documents.every((d) => d.data['form'] != null), true);
    await finish(tester, app, db);
  });

  testWidgets('Less and Company se Wasooli keep HTML effects', (tester) async {
    final (app, db) = await start(tester);
    final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    await app.saveMaster('party', {'name': 'Ali', 'customer': true});
    await app.saveMaster('party', {
      'name': 'PSO',
      'customer': false,
      'supplier': true,
    });
    final ali = app.partyByName('Ali')!.id, pso = app.partyByName('PSO')!.id;
    await pumpForm(tester, app);

    await tester.tap(tab('less'));
    await tester.pumpAndSettle();
    await tester.enterText(field('party'), 'Ali');
    await tester.enterText(field('amount'), '280');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.book.documents.last.type, EntryType.discount);
    expect(app.book.receivable(ali), -28000);
    expect(app.book.money('cash'), 0);

    await tester.tap(find.text('Khata se minus (discount)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank deposit (account mein jama)').last);
    await tester.pumpAndSettle();
    await chooseAccount(tester, index: 1);
    await tester.enterText(field('party'), 'Ali');
    await tester.enterText(field('amount'), '1000');
    await tester.tap(save);
    await tester.pumpAndSettle();
    final lessBank = app.book.documents.last;
    expect(lessBank.type, EntryType.receipt);
    expect(rozFormOf(lessBank), RozForm.less);
    expect(app.book.receivable(ali), -128000);
    expect(app.book.money(hbl), 100000);

    await tester.tap(tab('companyIn'));
    await tester.pumpAndSettle();
    await tester.enterText(field('party'), 'pso');
    await tester.enterText(field('cash'), '1000');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.book.payable(pso), 100000);
    expect(app.book.money('cash'), 100000);

    final day = RoznamchaDay(
      app.selectedDate,
      0,
      app.book.documents.where((d) => d.date == app.selectedDate),
    );
    expect(day.lessBank, 100000);
    expect(day.bankCust, 0);
    expect(day.cashIn, 100000);
    expect(day.safi, app.book.money('cash'));
    await finish(tester, app, db);
  });

  /// An Udhari party you borrowed Rs 3,225,000 from, as in the live khata.
  Future<String> usman(AppController app) async {
    await app.saveMaster('party', {
      'name': 'Ustad Usman',
      'customer': false,
      'udhari': true,
    }, supplierOpening: 322500000);
    return app.partyByName('Ustad Usman')!.id;
  }

  testWidgets('Udhar wapsi pays an Udhari party back, in its khata', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    final id = await usman(app);
    await app.saveMaster('party', {'name': 'Ali', 'customer': true});
    await pumpForm(tester, app);
    await tester.tap(tab('kharcha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash kharcha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Udhar wapsi').last);
    await tester.pumpAndSettle();
    expect(find.text('Udhari party'), findsOneWidget);

    // Nothing typed: the party is required.
    await tester.enterText(field('amount'), '1500000');
    await tester.tap(save);
    await tester.pump();
    expect(find.text('Udhari party ka naam likhein'), findsOneWidget);

    // Udhari parties are suggested (customers are not), with what you owe.
    await tester.enterText(field('party'), 'us');
    await tester.pumpAndSettle();
    expect(find.text('Ustad Usman'), findsOneWidget);
    expect(find.text('Ali'), findsNothing);
    await tester.tap(find.text('Ustad Usman'));
    await tester.pumpAndSettle();
    expect(text(tester, 'party'), 'Ustad Usman');
    expect(find.text('Baqaya: Dena 3,225,000'), findsOneWidget);
    expect(
      find.text('Baqaya: Dena 3,225,000  →  Dena 1,725,000'),
      findsOneWidget,
    );
    await tester.enterText(field('note'), 'Malik Abbas le gaya');
    await tester.tap(save);
    await tester.pumpAndSettle();

    final wapsi = app.book.documents.last;
    expect(wapsi.type, EntryType.payment);
    expect(wapsi.party, id);
    expect(wapsi.account, 'cash');
    expect(wapsi.data['supplierPayment'], true);
    expect(wapsi.data['form'], 'udharWapsi');
    expect(rozFormOf(wapsi), RozForm.udharWapsi);
    expect(app.book.payable(id), 172500000);
    expect(app.book.receivable(id), 0);
    expect(app.book.money('cash'), -150000000);
    // The party stays an Udhari party; it is not made a company.
    expect(app.record(id)!.data['supplier'], isNot(true));
    expect(app.record(id)!.data['udhari'], true);

    final day = RoznamchaDay(
      app.selectedDate,
      0,
      app.book.documents.where((d) => d.date == app.selectedDate),
    );
    expect(day.kharcha.single.id, wapsi.id);
    expect(day.udharCash, 150000000);
    expect(day.safi, app.book.money('cash'));

    // A new name opens a new Udhari khata.
    await tester.enterText(field('party'), 'Malik Abbas');
    await tester.pump();
    expect(find.text('Naya udhari khata banega'), findsOneWidget);
    await tester.enterText(field('amount'), '100');
    await tester.tap(save);
    await tester.pumpAndSettle();
    final abbas = app.partyByName('Malik Abbas')!;
    expect(abbas.data['udhari'], true);
    expect(abbas.data['customer'], false);
    expect(abbas.data['supplier'], false);
    expect(app.book.documents.last.party, abbas.id);
    await finish(tester, app, db);
  });

  testWidgets('From a party khata every tab keeps the party', (tester) async {
    final (app, db) = await start(tester);
    final id = await usman(app);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openRoznamchaForm(context, app, party: id),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Khata: Ustad Usman'), findsOneWidget);
    expect(text(tester, 'party'), 'Ustad Usman');

    // The Kharcha tab starts on the type that pays this party back.
    await tester.tap(tab('kharcha'));
    await tester.pumpAndSettle();
    expect(find.text('Udhar wapsi'), findsOneWidget);
    expect(text(tester, 'party'), 'Ustad Usman');
    expect(find.byKey(const ValueKey('roz-not-in-khata')), findsNothing);

    // A type without a party says the entry would miss the khata.
    await tester.tap(find.text('Udhar wapsi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash kharcha').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Yeh entry Ustad Usman ke khata mein nahi jayegi. '
        'Khata ke liye "Udhar wapsi" chunein.',
      ),
      findsOneWidget,
    );
    await tester.tap(tab('nikali'));
    await tester.pumpAndSettle();
    expect(
      find.text('Yeh entry Ustad Usman ke khata mein nahi jayegi.'),
      findsOneWidget,
    );

    // Back on Kharcha the name is still there (not cleared by the switch).
    await tester.tap(tab('kharcha'));
    await tester.pumpAndSettle();
    expect(text(tester, 'party'), 'Ustad Usman');
    expect(find.text('Udhar wapsi'), findsOneWidget);
    await tester.enterText(field('amount'), '1500000');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(app.book.documents.last.data['form'], 'udharWapsi');
    expect(app.book.payable(id), 172500000);
    // Ready for the next payment to the same party.
    expect(text(tester, 'party'), 'Ustad Usman');
    await finish(tester, app, db);
  });

  testWidgets('Edit loads the row into its form and Update replaces it', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    await pumpForm(tester, app);
    await tester.enterText(field('party'), 'Bilal');
    await tester.enterText(field('cash'), '1000');
    await tester.tap(save);
    await tester.pumpAndSettle();
    final original = app.book.documents.single;
    tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).edit(original);
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsOneWidget);
    expect(text(tester, 'cash'), '1000');
    expect(text(tester, 'party'), 'Bilal');
    await tester.enterText(field('cash'), '1500');
    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Galat raqam');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    final replaced = app.book.documents.single;
    expect(replaced.value('cash'), 150000);
    expect(replaced.reference, original.reference);
    expect(rozFormOf(replaced), RozForm.aamad);
    expect(app.record(original.id)!.data['voided'], true);
    expect(find.text('Add'), findsOneWidget);
    await finish(tester, app, db);
  });

  testWidgets('A customer you owe reads Dena: both sides of the khata count', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    // As in the live khata (لقمان احمد LPG): a customer entered with an
    // opening payable, who then paid into a bank. The Parties page showed
    // "You will pay"; the form read only the receivable side, so it showed
    // Rs 0 for him before the receipt.
    await app.saveMaster('party', {
      'name': 'Luqman Ahmed LPG',
      'customer': true,
    }, supplierOpening: 88802900);
    final id = app.partyByName('Luqman Ahmed LPG')!.id;
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': id,
      'bank': 22700000,
      'bankAccount': hbl,
    });
    expect(app.book.partyBalance(id), -111502900);
    expect(partyOwed(app.book, id), (receive: 0, pay: 111502900));
    // A company you owe Rs 1,000,000 that also owes you Rs 300,000.
    await app.saveMaster(
      'party',
      {'name': 'Supreme Petroleum', 'customer': false, 'supplier': true},
      opening: 30000000,
      supplierOpening: 100000000,
    );
    await pumpForm(tester, app);

    // Suggested, and then chosen, with what you owe him.
    await tester.enterText(field('party'), 'luq');
    await tester.pumpAndSettle();
    expect(find.text('Dena 1,115,029'), findsOneWidget);
    await tester.tap(find.text('Luqman Ahmed LPG'));
    await tester.pumpAndSettle();
    expect(find.text('Baqaya: Dena 1,115,029'), findsOneWidget);
    expect(
      find.text('Baqaya: Dena 1,115,029  →  Dena 1,115,029'),
      findsOneWidget,
    );

    // Gas sold to him comes off what you owe him.
    await tester.enterText(field('q11800'), '10');
    await tester.enterText(field('rate'), '5770');
    await tester.pump();
    expect(
      find.text('Baqaya: Dena 1,115,029  →  Dena 1,057,329'),
      findsOneWidget,
    );

    // A company paid directly shows its whole khata too: 1,000,000 − 300,000.
    await tester.enterText(field('bank'), '100000');
    await tester.pump();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct to Party').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('roz-direct-party')),
      'supreme petroleum',
    );
    await tester.pump();
    expect(
      find.text('Supreme Petroleum: Dena 700,000  →  Dena 600,000'),
      findsOneWidget,
    );

    // Paying him (Customer ko payment) brings what you owe down.
    await tester.tap(tab('kharcha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash kharcha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customer ko payment').last);
    await tester.pumpAndSettle();
    await tester.enterText(field('party'), 'Luqman Ahmed LPG');
    await tester.enterText(field('amount'), '500000');
    await tester.pump();
    expect(find.text('Baqaya: Dena 1,115,029'), findsOneWidget);
    expect(
      find.text('Baqaya: Dena 1,115,029  →  Dena 615,029'),
      findsOneWidget,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    final payment = app.book.documents.last;
    expect(payment.type, EntryType.payment);
    expect(payment.party, id);
    expect(rozFormOf(payment), RozForm.customerPay);
    expect(app.book.partyBalance(id), -61502900);
    expect(app.book.money('cash'), -50000000);
    await tester.enterText(field('party'), 'Luqman Ahmed LPG');
    await tester.pump();
    expect(find.text('Baqaya: Dena 615,029'), findsOneWidget);
    await finish(tester, app, db);
  });

  testWidgets(
    'Company ko payment keeps Customer (kis ke liye) and the branch',
    (tester) async {
      final (app, db) = await start(tester);
      await app.saveMaster('party', {
        'name': 'Pyramid',
        'customer': false,
        'supplier': true,
      }, supplierOpening: 205960200);
      final pyramid = app.partyByName('Pyramid')!.id;
      await pumpForm(tester, app);
      await tester.tap(tab('kharcha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cash kharcha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Company ko payment').last);
      await tester.pumpAndSettle();
      expect(find.text('Customer (kis ke liye)'), findsOneWidget);
      await tester.enterText(field('party'), 'Pyramid');
      await tester.enterText(field('customerNote'), 'Ali Traders');
      await tester.enterText(field('branch'), 'UBL');
      await tester.enterText(field('amount'), '1618000');
      await tester.pump();
      expect(
        find.text('Baqaya: Dena 2,059,602  →  Dena 441,602'),
        findsOneWidget,
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      final payment = app.book.documents.last;
      expect(payment.party, pyramid);
      expect(rozFormOf(payment), RozForm.companyPay);
      expect(payment.data['customerNote'], 'Ali Traders');
      expect(payment.data['branch'], 'UBL');
      // The customer is a note: only the company's khata and the cash move.
      expect(app.book.payable(pyramid), 44160200);
      expect(app.book.money('cash'), -161800000);
      // Editing the entry brings both back into the form.
      tester
          .state<RoznamchaFormState>(find.byType(RoznamchaForm))
          .edit(payment);
      await tester.pumpAndSettle();
      expect(text(tester, 'customerNote'), 'Ali Traders');
      expect(text(tester, 'branch'), 'UBL');
      await finish(tester, app, db);
    },
  );
}
