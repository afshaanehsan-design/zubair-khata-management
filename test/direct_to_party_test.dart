// "Direct to Party": a customer pays the company the gas is bought from
// instead of paying us. The amount leaves the customer's khata and goes into
// the company's, and no cash or bank account moves.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/entry_facts.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/features/reports/reports.dart'
    show buildReport, invoiceReport;
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/details.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

const day = '2026-11-02';
var _time = 0;
Record doc(String id, String type, Json data, {String date = day}) => Record(
  id,
  'document',
  {'type': type, 'date': date, 'occurredAt': ++_time, ...data},
);

const masters = [
  Record('umer', 'party', {'name': 'Umer', 'customer': true}),
  Record('supreme', 'party', {
    'name': 'Supreme Petroleum',
    'customer': false,
    'supplier': true,
  }),
  Record('cash', 'account', {'name': 'Cash'}),
  Record('hbl', 'account', {'name': 'Zubair', 'bank': 'HBL'}),
];

/// Rupees to paisa.
int rs(int rupees) => rupees * 100;

Future<(AppController, KhataDatabase)> open() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

/// A customer who owes Rs 446,182 and a company we owe Rs 1,000,000.
Future<(String, String)> parties(AppController app) async {
  await app.saveMaster('party', {
    'name': 'Umer',
    'customer': true,
  }, opening: rs(446182));
  await app.saveMaster('party', {
    'name': 'Supreme Petroleum',
    'customer': false,
    'supplier': true,
  }, supplierOpening: rs(1000000));
  return (
    app.partyByName('Umer')!.id,
    app.partyByName('Supreme Petroleum')!.id,
  );
}

Finder field(String key) => find.descendant(
  of: find.byKey(ValueKey('roz-$key')),
  matching: find.byType(TextField),
);
final partyField = find.byKey(const ValueKey('roz-party'));
final directPartyField = find.byKey(const ValueKey('roz-direct-party'));
final save = find.byKey(const ValueKey('roz-save'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('The amount moves from the customer to the company, with no cash or '
      'bank', () {
    final book = Book([
      ...masters,
      doc('umer-open', 'adjustment', {
        'party': 'umer',
        'target': 'ar:umer',
        'amount': rs(446182),
        'note': 'Opening balance',
      }, date: '2026-11-01'),
      doc('buy', 'purchase', {
        'party': 'supreme',
        'grams': 1000000,
        'rate': rs(300),
        'rateUnit': 1000,
      }, date: '2026-11-01'),
      // Wasooli only: Umer sent 400,000 straight to Supreme Petroleum.
      doc('direct', 'receipt', {
        'party': 'umer',
        'direct': rs(400000),
        'directParty': 'supreme',
      }),
      // A sale paid three ways: cash, bank and the rest directly.
      doc('sale', 'sale', {
        'party': 'umer',
        'quantities': {'11800': 2},
        'returned': {'11800': 2},
        'rate': rs(4640),
        'cash': rs(2000),
        'bank': rs(3000),
        'bankAccount': 'hbl',
        'direct': rs(4280),
        'directParty': 'supreme',
      }),
    ]);
    for (final d in book.documents) {
      expect(
        book.postings
            .where((p) => p.document == d.id)
            .fold(0, (v, p) => v + p.debit),
        0,
        reason: '${d.id} is balanced',
      );
    }
    expect(book.receivable('umer'), rs(446182 - 400000));
    expect(book.payable('supreme'), rs(300000 - 400000 - 4280));
    expect(book.money('cash'), rs(2000));
    expect(book.money('hbl'), rs(3000));
    // It settles bills like any other collection.
    final settled = Book([
      ...masters,
      doc('bill', 'sale', {
        'party': 'umer',
        'quantities': {'11800': 2},
        'returned': {'11800': 2},
        'rate': rs(4640),
      }),
      doc('paid', 'receipt', {
        'party': 'umer',
        'direct': rs(9000),
        'directParty': 'supreme',
      }),
    ]);
    expect(settled.invoiceDue['bill'], rs(280));
    expect(settled.receiptAllocations['paid'], [('bill', rs(9000))]);
    final direct = book.documents.firstWhere((d) => d.id == 'direct');
    expect(direct.direct, rs(400000));
    expect(direct.directParties, {'supreme'});
    expect(direct.collected, rs(400000));
    // An entry without the fields is what it always was.
    final plain = Document(
      doc('plain', 'receipt', {'party': 'umer', 'cash': 5}),
    );
    expect(plain.direct, 0);
    expect(plain.directParties, isEmpty);
    expect(plain.collected, 5);
  });

  test('It needs a party, other than the customer, and is for customers', () {
    void check(Json data, {String type = 'receipt', Object? fails}) {
      final d = Document(doc('x', type, {'party': 'umer', ...data}));
      if (fails == null) {
        validateDocument(d, masters);
      } else {
        expect(
          () => validateDocument(d, masters),
          throwsA(
            isA<FormatException>().having((e) => e.message, 'message', fails),
          ),
        );
      }
    }

    const choose = 'Choose the party that was paid directly';
    check({'direct': rs(100), 'directParty': 'supreme'});
    check({'direct': rs(100)}, fails: choose);
    check({'direct': rs(100), 'directParty': 'nobody'}, fails: choose);
    check({'direct': rs(100), 'directParty': 'umer'}, fails: choose);
    check({
      'direct': rs(100),
      'directParty': 'umer',
      'party': 'supreme',
      'supplierRefund': true,
    }, fails: choose);
    check({
      'direct': -1,
      'directParty': 'supreme',
    }, fails: 'Amounts and quantities cannot be negative');
    check({'directParty': 'supreme'}, fails: 'Enter a collection amount');
    // Other kinds of entry never carry it: the field is dropped.
    expect(
      cleanDocumentData({
        'type': 'payment',
        'direct': 5,
        'directParty': 'supreme',
      }).keys,
      ['type'],
    );
    expect(
      cleanDocumentData({'type': 'sale', 'direct': 5, 'directParty': 'supreme'})
          .keys,
      ['type', 'direct', 'directParty'],
    );
  });

  test('Roznamcha: wasooli in A, the party in B, cash in hand unchanged', () {
    final book = Book([
      ...masters,
      doc('open', 'adjustment', {
        'target': 'money:cash',
        'amount': rs(100000),
        'note': 'Opening',
      }, date: '2026-11-01'),
      doc('sale', 'sale', {
        'party': 'umer',
        'quantities': {'11800': 2},
        'returned': {'11800': 2},
        'rate': rs(4640),
        'cash': rs(2000),
        'bank': rs(3000),
        'bankAccount': 'hbl',
        'direct': rs(4280),
        'directParty': 'supreme',
      }),
      doc('direct', 'receipt', {
        'party': 'umer',
        'direct': rs(400000),
        'directParty': 'supreme',
      }),
      doc('tea', 'expense', {
        'account': 'cash',
        'amount': rs(500),
        'category': 'General',
        'note': 'Chai',
      }),
    ], throughDate: day);
    final docs = book.documents.where((d) => d.date == day).toList();
    final opening = book.money('cash') - book.dayMovement(day, 'money:cash');
    final r = RoznamchaDay(day, opening, docs);
    expect(r.cashIn, rs(2000));
    expect(r.bankCust, rs(3000));
    expect(r.direct, rs(404280));
    expect(r.wasooli, rs(2000 + 3000 + 404280));
    expect(r.left, rs(100000 + 2000 + 3000 + 404280));
    expect(r.rightTotal, rs(500 + 3000 + 404280));
    expect(r.safi, rs(101500));
    expect(r.safi, book.money('cash'));
    expect(r.aamad.map((d) => d.id), ['sale', 'direct']);
    expect(r.directLines.map((l) => l.document.id), ['sale', 'direct']);
    // The bank account only received the bank wasooli.
    expect(r.bankJama.map((l) => l.amount), [rs(3000)]);
    expect(r.bankNet, rs(3000));
    expect(rozFormOf(docs.last), isNotNull);
  });

  test('The paid party has entries; a deleted party cannot be paid', () async {
    final (app, db) = await open();
    final (umer, supreme) = await parties(app);
    await app.saveMaster('party', {'name': 'Old Company', 'supplier': true});
    final old = app.partyByName('Old Company')!;
    await app.deleteParty(old);
    await expectLater(
      app.post({
        'type': 'receipt',
        'date': day,
        'party': umer,
        'direct': rs(100),
        'directParty': old.id,
      }),
      throwsA(isA<FormatException>()),
    );

    await app.saveMaster('party', {'name': 'New Company', 'supplier': true});
    final fresh = app.partyByName('New Company')!;
    await app.post({
      'type': 'receipt',
      'date': day,
      'party': umer,
      'direct': rs(100),
      'directParty': fresh.id,
    });
    expect(app.partyHasEntries(fresh.id), isTrue);
    await expectLater(
      app.deleteParty(app.record(fresh.id)!),
      throwsA(isA<FormatException>()),
    );
    // Once the entry is voided nothing is left in its khata.
    await app.voidDocument(
      app.book.documents.firstWhere((d) => d.directParties.contains(fresh.id)),
      'Wrong party',
    );
    expect(app.partyHasEntries(fresh.id), isFalse);
    await app.deleteParty(app.record(fresh.id)!);
    expect(app.partyByName('New Company'), isNull);
    expect(app.book.payable(supreme), rs(1000000));
    app.dispose();
    await db.close();
  });

  test(
    'Both khatas, the statement and the receipt say what happened',
    () async {
      final (app, db) = await open();
      final (umer, supreme) = await parties(app);
      await app.post({
        'type': 'receipt',
        'date': app.selectedDate,
        'party': umer,
        'direct': rs(400000),
        'directParty': supreme,
        'note': 'Online bheje',
      });
      final d = app.book.documents.last;
      const en = Words(false), ur = Words(true);
      expect(app.book.receivable(umer), rs(46182));
      expect(app.book.payable(supreme), rs(600000));
      expect(app.book.money('cash'), 0);

      // The customer's side: a receipt, paid directly.
      expect(directFor(d, umer), isFalse);
      expect(
        entryHeadline(app, d, en),
        'Direct to party 400,000 (Supreme Petroleum)',
      );
      expect(entryAmountText(d), 'Rs 400,000');
      final payment = paymentFacts(app, d, en).single;
      expect(payment.label, 'Paid directly to party');
      expect(payment.value, 'Rs 400,000 · Supreme Petroleum');
      // The company's side: money it got from the customer.
      expect(directFor(d, supreme), isTrue);
      expect(directTitle(en), 'Bank payment');
      expect(directHeadline(app, d, supreme, en), 'Customer: Umer');
      expect(partyBalances(app.book, supreme)[d.id], -rs(600000));
      expect(partyBalances(app.book, umer)[d.id], rs(46182));
      for (final text in [
        entryHeadline(app, d, ur),
        paymentFacts(app, d, ur).single.label,
        directTitle(ur),
      ]) {
        expect(text, isNot(contains('irect')), reason: 'translated: $text');
      }

      final from = app.book.documents.first.date, to = app.selectedDate;
      final company = buildReport(
        app,
        'Party statement',
        from,
        to,
        party: supreme,
      ).rows.first;
      expect(company[2].text, 'Bank payment · Customer: Umer · Online bheje');
      expect(company[3].numeric, 400000);
      expect(company[4].text, '');
      expect(company[5].text, 'You owe 600,000');
      final customer = buildReport(
        app,
        'Party statement',
        from,
        to,
        party: umer,
      ).rows.first;
      expect(customer[2].text, contains('Direct to party 400,000'));
      expect(customer[4].numeric, 400000);
      expect(customer[5].text, 'Owes you 46,182');
      // Not in the cash book: no cash moved.
      expect(buildReport(app, 'Cash book', from, to).rows, isEmpty);
      final roz = buildReport(app, 'Daily roznamcha', to, to).rows;
      String line(String label) =>
          roz.firstWhere((r) => r[2].text.startsWith(label))[4].text;
      expect(line('Aaj ki Wasooli (cash + bank + direct)'), '400,000');
      expect(line('Direct to party · Wasooli — Umer'), '400,000');
      expect(line('Safi Baqaya'), '0');
      final slip = invoiceReport(app, d).rows;
      expect(
        slip.any(
          (r) =>
              r[0].text == 'Paid directly to party' &&
              r[1].text == 'Supreme Petroleum' &&
              r[4].numeric == 400000,
        ),
        isTrue,
      );
      app.dispose();
      await db.close();
    },
  );

  testWidgets('Naya Entry: Direct to Party asks for the party and saves it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, db) = await open();
    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    final (umer, supreme) = await parties(app);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RoznamchaForm(app: app)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No separate box: it is the last choice of the Bank / Account list.
    expect(field('direct'), findsNothing);
    final bankList = find.byType(DropdownButtonFormField<String>);
    Future<void> pick(String choice) async {
      await tester.tap(bankList);
      await tester.pumpAndSettle();
      await tester.tap(find.text(choice).last);
      await tester.pumpAndSettle();
    }

    await tester.enterText(partyField, 'Umer');
    await tester.enterText(field('bank'), '400000');
    await tester.pump();
    expect(directPartyField, findsNothing);
    await tester.tap(bankList);
    await tester.pumpAndSettle();
    // The banks first, Direct to Party at the end.
    expect(
      tester.getTopLeft(find.text('Direct to Party').last).dy,
      greaterThan(tester.getTopLeft(find.text('Zubair · HBL').last).dy),
    );
    await tester.tap(find.text('Direct to Party').last);
    await tester.pumpAndSettle();
    // The company field takes the place of the bank list.
    expect(directPartyField, findsOneWidget);
    expect(bankList, findsNothing);
    // …and the bank icon brings the list back.
    await tester.tap(find.byKey(const ValueKey('roz-back-to-banks')));
    await tester.pumpAndSettle();
    expect(directPartyField, findsNothing);
    expect(bankList, findsOneWidget);
    await pick('Direct to Party');

    await tester.tap(save);
    await tester.pump();
    expect(
      find.text('Direct to Party ke liye party ka naam likhein'),
      findsOneWidget,
    );
    await tester.enterText(directPartyField, 'umer');
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    expect(
      find.text('Direct to Party ke liye customer se alag party chunein'),
      findsOneWidget,
    );
    expect(
      app.book.documents.where((d) => d.type != EntryType.adjustment),
      isEmpty,
    );

    await tester.enterText(directPartyField, 'supreme petroleum');
    await tester.pump();
    // Both khatas, before and after.
    expect(find.text('Baqaya: Lena 446,182  →  Lena 46,182'), findsOneWidget);
    expect(
      find.text('Supreme Petroleum: Dena 1,000,000  →  Dena 600,000'),
      findsOneWidget,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    final receipt = app.book.documents.last;
    expect(receipt.type, EntryType.receipt);
    expect(receipt.party, umer);
    expect(receipt.direct, rs(400000));
    expect(receipt.directParties, {supreme});
    expect(receipt.value('cash') + receipt.value('bank'), 0);
    expect(receipt.data['bankAccount'], '');
    expect(app.book.receivable(umer), rs(46182));
    expect(app.book.payable(supreme), rs(600000));
    expect(app.book.money('cash'), 0);
    expect(app.ofKind('party'), hasLength(2), reason: 'no party was added');
    expect(find.textContaining('Save ho gaya: Umer · Rs 400,000'), findsOne);
    // The next entry starts on the bank list again.
    expect(directPartyField, findsNothing);

    // A sale: part cash, the rest straight to a company typed for the first
    // time.
    await tester.enterText(partyField, 'Umer');
    await tester.enterText(field('q11800'), '2');
    await tester.enterText(field('rate'), '4640');
    await tester.enterText(field('cash'), '1000');
    await tester.enterText(field('bank'), '8280');
    await tester.pump();
    await pick('Direct to Party');
    await tester.enterText(directPartyField, 'Naya Gas Company');
    await tester.pump();
    expect(find.text('Nayi company banegi'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final sale = app.book.documents.last;
    final naya = app.partyByName('Naya Gas Company')!;
    expect(naya.data['supplier'], true);
    expect(naya.data['customer'], false);
    expect(sale.type, EntryType.sale);
    expect(sale.direct, rs(8280));
    expect(sale.value('cash'), rs(1000));
    expect(sale.value('bank'), 0);
    expect(sale.directParties, {naya.id});
    expect(app.book.payable(naya.id), -rs(8280), reason: 'an advance to it');
    expect(app.book.money('cash'), rs(1000));
    expect(app.book.receivable(umer), rs(46182));

    // ✏️ loads the amount into Bank Wasooli with Direct to Party chosen.
    tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).edit(receipt);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('bank')).controller!.text, '400000');
    expect(
      tester.widget<TextField>(directPartyField).controller!.text,
      'Supreme Petroleum',
    );
    // Correcting it to cash takes it back out of the company's khata.
    await tester.enterText(field('bank'), '');
    await tester.enterText(field('cash'), '400000');
    await tester.pump();
    expect(directPartyField, findsNothing);
    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Cash mein mile');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(app.book.payable(supreme), rs(1000000));
    expect(app.book.receivable(umer), rs(46182));
    expect(app.book.money('cash'), rs(401000));

    // An entry paid both into a bank and directly (also possible from the
    // general composer) can now be loaded into this form.
    final both = Document(
      Record('both', 'document', {
        'type': 'receipt',
        'date': day,
        'party': umer,
        'bank': 100,
        'bankAccount': 'x',
        'direct': 100,
        'directParty': supreme,
      }),
    );
    expect(rozEditable(both), isTrue);
    expect(rozEditable(receipt), isTrue);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    app.dispose();
    await db.close();
  });

  testWidgets('Urdu names keep their sides of the arrow in B', (tester) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, db) = await open();
    await app.saveMaster('account', {'name': 'لقمان احمد', 'bank': 'HBL'});
    final luqman = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    await app.saveMaster('party', {'name': 'عصمت بریار'});
    await app.saveMaster('party', {
      'name': 'سانگلہ پیٹرولیم',
      'customer': false,
      'supplier': true,
    });
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': app.partyByName('عصمت بریار')!.id,
      'bank': rs(10000),
      'bankAccount': luqman,
      'direct': rs(5000),
      'directParty': app.partyByName('سانگلہ پیٹرولیم')!.id,
      'form': 'aamad',
    });
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    // Without isolates the two Urdu names around "→" run together and swap
    // sides, so the row would read as money going the other way.
    final l = String.fromCharCode(0x2066), e = String.fromCharCode(0x2069);
    expect(
      find.text('Wasooli — $lعصمت بریار$e → $lلقمان احمد · HBL$e'),
      findsOneWidget,
    );
    expect(
      find.text('Wasooli — $lعصمت بریار$e → $lسانگلہ پیٹرولیم$e'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    app.dispose();
    await db.close();
  });

  testWidgets('The page shows it in A and B, and each khata shows its side', (
    tester,
  ) async {
    await initializeDateFormatting('en');
    for (final (family, asset) in [
      ('Manrope', 'assets/fonts/Manrope.ttf'),
      ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, db) = await open();
    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    final (umer, supreme) = await parties(app);
    await app.post({
      'type': 'adjustment',
      'date': app.selectedDate,
      'target': 'money:cash',
      'amount': rs(50000),
      'occurredAt': 0,
      'note': 'Opening balance',
    });
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': umer,
      'direct': rs(400000),
      'directParty': supreme,
      'form': 'aamad',
    });
    final d = app.book.documents.last;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: KhataApp(app)),
    );
    await tester.pumpAndSettle();

    // A: its own column, counted in the day's wasooli.
    expect(find.text('Direct to Party'), findsWidgets);
    expect(find.byKey(ValueKey('roz-direct-${d.id}')), findsOneWidget);
    expect(find.text('Aaj ki Wasooli (cash + bank + direct)'), findsOneWidget);
    // B: the party got it, automatically.
    expect(
      find.textContaining('DIRECT TO PARTY (customer ne seedha party ko diye)'),
      findsOneWidget,
    );
    expect(find.text('Wasooli — Umer → Supreme Petroleum'), findsOneWidget);
    // Cash in hand is still only the opening cash.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('roz-safi')),
        matching: find.text('Rs 50,000'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Hisab farq'), findsNothing);
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/preview-direct-to-party.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });

    // The company's khata: a payment it received, for that amount only.
    BuildContext ctx() => tester.element(find.byType(Workspace));
    unawaited(showParty(ctx(), app, app.record(supreme)!));
    await tester.pumpAndSettle();
    Finder inDialog(Finder f) =>
        find.descendant(of: find.byType(Dialog), matching: f);
    expect(inDialog(find.text('Bank payment')), findsOneWidget);
    expect(inDialog(find.text('Customer: Umer')), findsOneWidget);
    expect(inDialog(find.text('Rs 400,000')), findsOneWidget);
    expect(inDialog(find.text('You owe Rs 600,000')), findsOneWidget);
    await tester.tap(inDialog(find.byIcon(Icons.close)));
    await tester.pumpAndSettle();

    // The customer's khata: a receipt that went to the company.
    unawaited(showParty(ctx(), app, app.record(umer)!));
    await tester.pumpAndSettle();
    expect(
      inDialog(find.text('Direct to party 400,000 (Supreme Petroleum)')),
      findsOneWidget,
    );
    expect(inDialog(find.text('Owes you Rs 46,182')), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    app.dispose();
    await db.close();
  });
}
