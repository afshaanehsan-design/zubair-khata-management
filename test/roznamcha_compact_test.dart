import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/features/reports/roznamcha_sheet.dart';
import 'package:zubair_khata_management/ui/app.dart';

const date = '2026-11-02';
const customerName = 'عصمت بریار';
int rs(int value) => value * 100;

Future<(AppController, KhataDatabase, String, String, String)> setup() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  app.setDate(date);
  await app.saveMaster('party', {'name': customerName});
  final customer = app.partyByName(customerName)!.id;
  await app.saveMaster('account', {
    'name': 'لقمان احمد Luqman Ahmad',
    'bank': 'HBL',
  });
  await app.saveMaster('account', {
    'name': 'قیصر عباس Qaisar Abbas',
    'bank': 'MBL',
  });
  final hbl = app
      .ofKind('account')
      .firstWhere((a) => a.data['bank'] == 'HBL')
      .id;
  final mbl = app
      .ofKind('account')
      .firstWhere((a) => a.data['bank'] == 'MBL')
      .id;
  for (final (amount, account) in [(10000, hbl), (39000, mbl), (18000, mbl)]) {
    await app.post({
      'date': date,
      'type': 'receipt',
      'form': 'aamad',
      'party': customer,
      'bank': rs(amount),
      'bankAccount': account,
      'note':
          'بینک وصولی کی تفصیل ${List.filled(20, 'لمبی وضاحت').join(' ')}\nاگلی سطر',
    });
  }
  return (app, db, customer, hbl, mbl);
}

List<List<String>> cells(List<List<SheetCell>> rows) => [
  for (final row in rows) [for (final cell in row) cell.text],
];

Future<void> fonts() async {
  for (final (family, asset) in [
    ('Manrope', 'assets/fonts/Manrope.ttf'),
    ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
    ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
  ]) {
    await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
  }
  // Load Latin glyphs explicitly: test mode otherwise substitutes squares
  // for the Arial text used by the PDF renderer beside Urdu.
  final arial = [
    for (final name in ['arial.ttf', 'arialbd.ttf'])
      File('C:/Windows/Fonts/$name'),
  ].where((f) => f.existsSync());
  final loader = FontLoader('Arial');
  for (final file in arial) {
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  if (arial.isEmpty) {
    loader.addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Three bank entries become 67,000; cash, direct, quantities and bills stay separate', () async {
    final (app, db, customer, hbl, mbl) = await setup();
    addTearDown(() async {
      app.dispose();
      await db.close();
    });
    final detailed = buildReport(app, 'Daily roznamcha', date, date);
    final compact = detailed.withCompact(true);
    expect(detailed.sheets.single.tables.first.body, hasLength(3));
    final row = compact.sheets.single.tables.first.body.single;
    expect(row[2].text.split('\n').first, customerName);
    expect(row[9].lines.first.single.text, '67,000');
    expect(row[10].text, '67,000');
    expect(row[9].numeric, isTrue);
    expect(row[9].text, '67,000');
    expect(row[9].lines, hasLength(1));
    expect(row[9].ellipsis, isFalse);
    expect(
      detailed.sheets.single.tables.first.body.first[9].text,
      contains('Luqman Ahmad'),
    );
    expect(row[2].lines.last.single.text, isNot(contains('\n')));
    expect(
      cells(compact.withCompact(false).sheets.single.tables.first.body),
      cells(detailed.sheets.single.tables.first.body),
    );

    await app.saveMaster('party', {
      'name': 'JU Gas',
      'customer': false,
      'supplier': true,
    });
    final company = app.partyByName('JU Gas')!.id;
    await app.post({
      'date': date,
      'type': 'sale',
      'form': 'aamad',
      'party': customer,
      'quantities': {'11800': 2, '45000': 34},
      'returned': {'11800': 2, '45000': 34},
      'rate': rs(5770),
      'cash': rs(326500),
      'bankLines': [
        {'amount': rs(12500), 'party': company, 'bankName': 'HBL'},
        {'amount': rs(7500), 'party': company, 'bankName': 'MBL'},
      ],
    });
    final source = canonicalJson(app.records.map((r) => r.toJson()).toList());
    final full = buildReport(app, 'Daily roznamcha', date, date);
    final small = full.withCompact(true);
    final a = small.sheets.single.tables.first;
    expect(a.body, hasLength(1));
    expect(a.body.single[3].text, '2');
    expect(a.body.single[5].text, '34');
    expect(a.body.single[6].text, '5,770');
    expect(
      a.body.single[7].text,
      money(
        app.book.documents.firstWhere((d) => d.type == EntryType.sale).total,
      ),
    );
    expect(a.body.single[8].text, '326,500');
    expect(a.body.single[9].lines.first.single.text, '67,000');
    expect(a.body.single[10].lines.first.single.text, '20,000');
    expect(a.body.single[10].text, '20,000');
    expect(a.body.single[10].lines, hasLength(1));
    expect(a.body.single.last.text, '413,500');
    final b = small.sheets.single.table('B: Kharcha + Bank Jama')!;
    expect(
      b.body.where((r) => r[1].text == 'DIRECT TO PARTY').single.last.text,
      '20,000',
    );
    expect(cells(a.foot), cells(full.sheets.single.tables.first.foot));
    expect(
      cells(small.sheets.single.summary.body),
      cells(full.sheets.single.summary.body),
    );
    expect(small.sheets.single.heading, full.sheets.single.heading);
    expect(small.rows, same(full.rows));
    expect(canonicalJson(app.records.map((r) => r.toJson()).toList()), source);
    expect(app.book.money('cash'), rs(326500));
    expect(app.book.money(hbl) + app.book.money(mbl), rs(67000));
  });

  test('Expense types, cash and banks stay separate; jama and withdrawals sum by account', () async {
    final (app, db, customer, hbl, mbl) = await setup();
    addTearDown(() async {
      app.dispose();
      await db.close();
    });
    await app.saveMaster('party', {
      'name': 'JU Gas',
      'customer': false,
      'supplier': true,
    });
    final company = app.partyByName('JU Gas')!.id;
    for (final (amount, account, form) in [
      (1000, 'cash', 'companyPay'),
      (2000, 'cash', 'companyPay'),
      (3000, hbl, 'companyPay'),
      (4000, mbl, 'companyPay'),
      (5000, 'cash', 'udharWapsi'),
    ]) {
      await app.post({
        'date': date,
        'type': 'payment',
        'party': company,
        'supplierPayment': true,
        'amount': rs(amount),
        'account': account,
        'form': form,
      });
    }
    for (final amount in [100, 200]) {
      await app.post({
        'date': date,
        'type': 'transfer',
        'form': 'nikali',
        'account': hbl,
        'toAccount': 'cash',
        'amount': rs(amount),
      });
      await app.post({
        'date': date,
        'type': 'discount',
        'form': 'less',
        'party': customer,
        'amount': rs(amount),
      });
    }
    final detailed = buildReport(app, 'Daily roznamcha', date, date);
    final compact = detailed.withCompact(true);
    final sheet = compact.sheets.single;
    final b = sheet.table('B: Kharcha + Bank Jama')!;
    expect(b.body, hasLength(6)); // four payment groups and two bank accounts
    expect(
      b.body.where((r) => r[1].text == 'COMPANY').map((r) => r.last.text),
      ['3,000', '3,000', '4,000'],
    );
    expect(
      b.body.where((r) => r[1].text == 'UDHAR WAPSI').single.last.text,
      '5,000',
    );
    expect(
      b.body.where((r) => r[1].text == 'BANK JAMA').map((r) => r.last.text),
      ['10,000', '57,000'],
    );
    final middle = sheet.table('Bank Nikali / Less')!;
    expect(middle.body, hasLength(2));
    expect(middle.body.map((r) => r.last.text), ['300', '300']);
    expect(cells(b.foot), cells(detailed.sheets.single.table(b.title)!.foot));
    expect(
      cells(sheet.summary.body),
      cells(detailed.sheets.single.summary.body),
    );
  });

  test('Compact applies to saved history and date ranges without merging dates or party IDs', () async {
    final (app, db, customer, hbl, _) = await setup();
    addTearDown(() async {
      app.dispose();
      await db.close();
    });
    await app.saveSnapshot();
    final saved = app.ofKind('snapshot').single;
    await app.post({
      'date': '2026-11-03',
      'type': 'receipt',
      'party': customer,
      'bank': rs(5000),
      'bankAccount': hbl,
    });
    // Imported data may contain two parties with identical display names.
    await app.saveMaster('party', {'name': 'Another customer'});
    final other = app.partyByName('Another customer')!;
    await app.post({
      'date': date,
      'type': 'receipt',
      'party': other.id,
      'cash': rs(100),
    });
    app.records = [
      for (final r in app.records)
        if (r.id == other.id)
          Record(r.id, r.kind, {
            ...r.data,
            'name': customerName,
          }, version: r.version)
        else
          r,
    ];
    app.rozCustomerWise = true;
    final detailedRange = buildReport(
      app,
      'Daily roznamcha',
      date,
      '2026-11-03',
    );
    expect(detailedRange.compact, isFalse);
    expect(detailedRange.sheets.first.tables.first.body, hasLength(4));
    final range = detailedRange.withCompact(true);
    expect(range.compact, isTrue);
    expect(range.sheets, hasLength(2));
    expect(range.sheets.first.tables.first.body, hasLength(2));
    expect(
      range.sheets.first.tables.first.body.first[9].lines.first.single.text,
      '67,000',
    );
    expect(
      range.sheets.last.tables.first.body.single[9].lines.first.single.text,
      '5,000',
    );
    final detailedHistory = snapshotReport(app, saved);
    expect(detailedHistory.compact, isFalse);
    expect(detailedHistory.sheets.single.tables.first.body, hasLength(3));
    final history = detailedHistory.withCompact(true);
    expect(history.sheets.single.tables.first.body, hasLength(1));
    expect(
      history.withCompact(false).sheets.single.tables.first.body,
      hasLength(3),
    );
    expect(
      history.withCompact(false).sheets.single.heading,
      history.sheets.single.heading,
    );
    expect(buildReport(app, 'Cash book', date, date).roznamchaSheets, isNull);
  });

  testWidgets(
    'Page toggle keeps its original behavior independently of PDF Compact',
    (tester) async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('ur');
      await fonts();
      final (app, db, _, _, _) = await setup();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await db.close();
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(KhataApp(app));
      await tester.pumpAndSettle();
      expect(find.text('Customer wise (ikatha)'), findsOneWidget);
      expect(find.text('Entry wise (alag alag)'), findsOneWidget);
      expect(find.byKey(const ValueKey('roz-compact')), findsNothing);
      expect(find.text(customerName), findsNWidgets(3));
      final customerToggle = find.byKey(const ValueKey('roz-view-true'));
      await tester.ensureVisible(customerToggle);
      await tester.tap(customerToggle);
      await tester.pumpAndSettle();
      expect(app.rozCustomerWise, isTrue);
      // Original grouping adds the party subtotal and retains all three entries.
      expect(find.text(customerName), findsNWidgets(4));
      expect(find.textContaining('Luqman Ahmad'), findsWidgets);
      final detailed = buildReport(app, 'Daily roznamcha', date, date);
      expect(detailed.compact, isFalse);
      expect(detailed.sheets.single.tables.first.body, hasLength(3));
      final compact = detailed.withCompact(true);
      expect(compact.sheets.single.tables.first.body.single[9].text, '67,000');
      expect(app.rozCustomerWise, isTrue);
      for (final language in ['en', 'ur']) {
        app.language = language;
        for (final size in [
          const Size(1920, 2400),
          const Size(1260, 2400),
          const Size(390, 2600),
          const Size(360, 640),
        ]) {
          tester.view.physicalSize = size;
          app.notifyListeners();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$language at $size');
        }
      }
      app.language = 'en';
      tester.view.physicalSize = const Size(1920, 2400);
      app.notifyListeners();
      await tester.pumpAndSettle();
      final entryToggle = find.byKey(const ValueKey('roz-view-false'));
      await tester.ensureVisible(entryToggle);
      await tester.tap(entryToggle);
      await tester.pumpAndSettle();
      expect(app.rozCustomerWise, isFalse);
      expect(find.text(customerName), findsNWidgets(3));
      expect(compact.compact, isTrue);
    },
  );
  testWidgets('Compact PDFs render long mixed text in both languages', (
    tester,
  ) async {
    await fonts();
    final (app, db, _, _, _) = await setup();
    await tester.runAsync(() async {
      const longName =
          'A customer with a very long account name and branch reference';
      await app.saveMaster('party', {'name': longName});
      final party = app.partyByName(longName)!.id;
      final bank = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
      await app.post({
        'date': date,
        'type': 'receipt',
        'party': party,
        'bank': 1234567890123,
        'bankAccount': bank,
      });
      for (final urdu in [false, true]) {
        final report = buildReport(
          app,
          'Daily roznamcha',
          date,
          date,
          urdu: urdu,
        ).withCompact(true);
        final bytes = await ReportExporter().pdf(report);
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        await File(
          'build/preview-roznamcha-compact-${urdu ? 'urdu' : 'english'}.pdf',
        ).writeAsBytes(bytes);
      }
      app.dispose();
      await db.close();
    });
  });
}
