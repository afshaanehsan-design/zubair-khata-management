import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/report_sheet.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/features/reports/roznamcha_sheet.dart';

List<String> heads(SheetTable t) => [for (final c in t.head) c.text];
List<List<String>> cells(List<List<SheetCell>> rows) => [
  for (final r in rows) [for (final c in r) c.text],
];

/// At Rs 4,720 per 11.8 KG (Rs 400 a KG): Ali Traders owes 4,720 brought
/// forward, then a sale of 27,440 (two 11.8 KG and a 45 KG he keeps) paid
/// 5,000 in cash and bank, then a deposit of 3,000. Also PSO's purchase of
/// 1,000 KG (Rs 300,000 owed), an Office expense and Bilal's overdue 6,000.
Future<(AppController, KhataDatabase, String Function(int))> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  final today = app.selectedDate;
  String ago(int n) => DateTime.parse(
    today,
  ).subtract(Duration(days: n)).toIso8601String().substring(0, 10);
  Future<void> post(int days, Map<String, dynamic> data) =>
      app.post({'date': ago(days), ...data});
  await app.saveMaster('account', {'name': 'Luqman', 'bank': 'HBL'});
  final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
  await app.saveMaster('party', {'name': 'Ali Traders', 'customer': true});
  await app.saveMaster('party', {'name': 'Bilal', 'customer': true});
  await app.saveMaster('party', {
    'name': 'PSO',
    'customer': false,
    'supplier': true,
  });
  final ali = app.partyByName('Ali Traders')!.id;
  final bilal = app.partyByName('Bilal')!.id;
  final pso = app.partyByName('PSO')!.id;
  await post(6, {
    'type': 'purchase',
    'occurredAt': 0,
    'party': pso,
    'grams': 1000000,
    'rate': 30000,
    'rateUnit': 1000,
  });
  await post(5, {
    'type': 'sale',
    'party': ali,
    'quantities': {'11800': 1},
    'returned': {'11800': 1},
    'rate': 472000,
  });
  await post(3, {
    'type': 'sale',
    'party': ali,
    'quantities': {'11800': 2, '45000': 1},
    'returned': {'11800': 2},
    'rate': 472000,
    'cash': 300000,
    'bank': 200000,
    'bankAccount': hbl,
  });
  await post(2, {
    'type': 'deposit',
    'party': ali,
    'amount': 300000,
    'account': 'cash',
  });
  await post(2, {
    'type': 'expense',
    'category': 'Office',
    'amount': 150000,
    'account': 'cash',
    'note': 'Chai pani',
  });
  await post(4, {
    'type': 'sale',
    'party': bilal,
    'quantities': {'15000': 1},
    'returned': {'15000': 1},
    'rate': 472000,
    'dueDate': ago(3),
  });
  return (app, db, ago);
}

Future<void> loadFonts() async {
  for (final (family, asset) in [
    ('Manrope', 'assets/fonts/Manrope.ttf'),
    ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
  ]) {
    await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
  }
  // Latin beside Urdu is drawn in Arial (Manrope where it is missing).
  final arial = [
    for (final name in ['arial.ttf', 'arialbd.ttf'])
      File('C:/Windows/Fonts/$name'),
  ].where((f) => f.existsSync());
  final loader = FontLoader('Arial');
  for (final file in arial) {
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  if (arial.isEmpty) loader.addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Party statement prints like the Roznamcha: summary, khata, deposits '
      '(rows for the table, Excel and CSV unchanged)', () async {
    final (app, db, ago) = await start();
    final ali = app.partyByName('Ali Traders')!.id;
    final r = buildReport(
      app,
      'Party statement',
      ago(4),
      app.selectedDate,
      party: ali,
    );
    // The rows are as before: sale, opening, deposit heading, deposit.
    expect(r.rows, hasLength(4));
    expect(r.rows[1][2].text, 'Opening');

    final sheet = r.sheets.single;
    expect(sheet.title, '${app.businessName} — Party statement');
    expect(sheet.stamp, startsWith('Date: ${rozDmy(app.selectedDate)} | '));
    expect(
      sheet.heading,
      '${rozDmy(ago(4))} — ${rozDmy(app.selectedDate)} · Ali Traders · '
      'Balance: Owes you Rs. 27,160',
    );
    expect(heads(sheet.summary), [
      'OPENING',
      'DEBIT',
      'CREDIT',
      'BALANCE',
      'REFUNDABLE DEPOSIT',
      'CUSTOMER-HELD',
    ]);
    expect(cells(sheet.summary.body).single, [
      'Owes you Rs. 4,720',
      'Rs. 27,440',
      'Rs. 5,000',
      'Owes you Rs. 27,160 Entries 1',
      'Rs. 3,000',
      '1 45 KG: 1',
    ]);

    expect(sheet.tables.map((t) => t.title), [
      'Ali Traders',
      'Refundable deposit',
    ]);
    final khata = sheet.tables.first;
    expect(heads(khata), [
      '#',
      'DATE',
      'REFERENCE',
      'DESCRIPTION',
      'DEBIT',
      'CREDIT',
      'BALANCE',
    ]);
    // Figures on the end side, text on the start side.
    expect(khata.head.map((c) => c.align).toList(), [
      SheetAlign.start,
      SheetAlign.start,
      SheetAlign.start,
      SheetAlign.start,
      SheetAlign.end,
      SheetAlign.end,
      SheetAlign.end,
    ]);
    final sale = cells(khata.body).first;
    expect(sale[0], '1');
    expect(sale[1], rozDmy(ago(3)));
    expect(sale.skip(4), ['27,440', '5,000', 'Owes you 27,160']);
    // The balance brought forward is unnumbered, with '—' for no figure.
    expect(cells(khata.body).last, [
      '',
      rozDmy(ago(4)),
      '',
      'Opening',
      '—',
      '—',
      'Owes you 4,720',
    ]);
    // Total across '#', Date, Reference and Description, in bold.
    expect(cells(khata.foot), [
      ['Total', '27,440', '5,000', 'Owes you 27,160'],
    ]);
    expect(khata.foot.single.first.span, 4);
    expect(khata.foot.single.every((c) => c.lines.single.single.bold), isTrue);
    // Description wraps; date and reference keep one line.
    expect(khata.wrap, {3});

    final deposit = sheet.tables.last;
    expect(cells(deposit.body).single.skip(4), ['—', '3,000', '3,000']);
    expect(cells(deposit.foot), [
      ['Total', '0', '3,000', '3,000'],
    ]);

    // Urdu: the same sheet in Urdu words.
    final urdu = buildReport(
      app,
      'Party statement',
      ago(4),
      app.selectedDate,
      party: ali,
      urdu: true,
    ).sheets.single;
    expect(urdu.summary.head.first.text, Words(true)('Opening'));
    expect(urdu.tables.first.foot.single.first.text, Words(true)('Total'));
    app.dispose();
    await db.close();
  });

  test('Every report has a sheet with a title, stamp, heading and tables; '
      'the summaries add up', () async {
    final (app, db, ago) = await start();
    final from = ago(7), to = app.selectedDate;
    for (final kind in reportNames) {
      for (final urdu in [false, true]) {
        final r = buildReport(
          app,
          kind,
          from,
          to,
          party: kind == 'Party statement'
              ? app.partyByName('Ali Traders')!.id
              : null,
          account: kind == 'Bank book'
              ? app.ofKind('account').firstWhere((a) => a.id != 'cash').id
              : null,
          urdu: urdu,
        );
        expect(r.sheets, isNotEmpty, reason: kind);
        for (final s in r.sheets) {
          expect(s.title, isNotEmpty, reason: kind);
          expect(s.stamp, isNotEmpty, reason: kind);
          expect(s.tables, isNotEmpty, reason: kind);
          for (final t in s.tables) {
            for (final row in [...t.body, ...t.foot]) {
              // Every row fills the table's columns exactly.
              expect(
                row.fold(0, (v, c) => v + c.span),
                t.head.length,
                reason: '$kind ${t.title}',
              );
            }
          }
        }
      }
    }

    final sales = buildReport(app, 'Sales register', from, to).sheets.single;
    expect(heads(sales.summary), [
      'KG SOLD',
      'BILL TOTAL',
      'CASH',
      'BANK',
      'OUTSTANDING',
    ]);
    expect(cells(sales.summary.body).single.first, '95.4 kg');
    expect(
      cells(sales.summary.body).single[1],
      'Rs. 38,160 Cylinder billing 38,160 | Extra-KG billing 0',
    );
    expect(sales.heading, endsWith('Bill total: Rs. 38,160'));
    expect(cells(sales.tables.single.foot).single.first, 'Total');

    final overdue = buildReport(app, 'Overdue', from, to).sheets.single;
    expect(cells(overdue.summary.body).single, ['Rs. 6,000 Entries 1']);
    expect(cells(overdue.tables.single.body).single.first, '1');
    expect(cells(overdue.tables.single.foot).single.last, '6,000');

    // Balances list only the parties with a figure; the totals are all.
    final balances = buildReport(
      app,
      'Customer balances',
      from,
      to,
    ).sheets.single;
    expect(balances.heading, '${rozDmy(to)} · Receivable: Rs. 33,160');
    expect(cells(balances.tables.single.body).map((r) => r[1]).toSet(), {
      'Ali Traders',
      'Bilal',
      'PSO',
    });
    expect(
      cells(balances.summary.body).single.first,
      'Rs. 33,160 Parties 3',
    );

    final gas = buildReport(app, 'Gas stock', from, to).sheets.single;
    expect(heads(gas.summary), ['OPENING', 'GAS IN', 'GAS OUT', 'CLOSING']);
    expect(cells(gas.summary.body).single, [
      '0 kg',
      '1,000 kg',
      '95.4 kg',
      '904.6 kg Entries 4',
    ]);

    final profit = buildReport(app, 'Profit report', from, to).sheets.single;
    expect(heads(profit.summary), hasLength(6));
    // No '#' in the profit statement; its profit rows are bold.
    expect(heads(profit.tables.single), ['DESCRIPTION', 'AMOUNT']);
    expect(
      profit.tables.single.body[3].first.lines.single.single.bold,
      isTrue,
    );

    final custody = buildReport(app, 'Cylinder custody', from, to);
    expect(custody.rows.single.last.numeric, 1);
    expect(cells(custody.sheets.single.summary.body).single, [
      '1 Entries 1',
      '1',
    ]);

    final audit = buildReport(app, 'Audit trail', from, to).sheets.single;
    expect(audit.heading, startsWith('Entries: '));
    // Moments as the Roznamcha's print stamp writes them.
    expect(
      cells(audit.tables.single.body).first[1],
      matches(RegExp(r'^\d\d/\d\d/\d{4}, \d\d:\d\d:\d\d$')),
    );
    app.dispose();
    await db.close();
  });

  test('Invoice: the items, then the bill, payments and outstanding', () async {
    final (app, db, _) = await start();
    final sale = app.book.documents.lastWhere(
      (d) => d.type == EntryType.sale && d.value('cash') > 0,
    );
    final r = invoiceReport(app, sale);
    final sheet = r.sheets.single;
    expect(sheet.title, '${app.businessName} — Invoice / receipt');
    expect(sheet.heading, contains(sale.reference));
    expect(sheet.heading, contains('Ali Traders'));
    expect(heads(sheet.summary), [
      'WEIGHT (KG)',
      'BILL TOTAL',
      'KUL WASOOLI',
      'OUTSTANDING',
    ]);
    final table = sheet.tables.single;
    expect(cells(table.body).map((r) => r.take(3).toList()), [
      ['1', '11.8 KG', '2'],
      ['2', '45 KG', '1'],
    ]);
    expect(cells(table.foot).map((r) => r.first), [
      'Bill total',
      'Cash received',
      'Bank received · Luqman',
      'Outstanding',
    ]);
    expect(table.foot.first.first.span, 5);
    expect(table.foot.first.first.lines.single.single.bold, isTrue);
    expect(table.foot[1].first.lines.single.single.bold, isFalse);
    // The table, Excel and CSV rows are as before.
    expect(r.rows.map((r) => r.first.text), [
      '11.8 KG',
      '45 KG',
      'Bill total',
      'Cash received',
      'Bank received',
      'Outstanding',
    ]);

    // A receipt has no items: its lines are the table.
    final deposit = app.book.documents.firstWhere(
      (d) => d.type == EntryType.deposit,
    );
    final receipt = invoiceReport(app, deposit);
    final slip = receipt.sheets.single.tables.single;
    expect(slip.foot, isEmpty);
    expect(cells(slip.body).single.last, receipt.rows.single.last.text);
    app.dispose();
    await db.close();
  });

  test('A report without sheets of its own is printed as one sheet', () {
    const report = Report(
      title: 'Party statement',
      business: 'Zubair Traders',
      subtitle: '2026-11-13 — 2026-11-14 · Imtiaz',
      columns: ['Date', 'Description', 'Amount'],
      rows: [
        [Cell('2026-11-13'), Cell('Sale · 45 KG × 6'), Cell('137,975', 1379.75)],
        [Cell('2026-11-14'), Cell('Cash'), Cell('')],
      ],
      notes: ['Note'],
    );
    final sheet = autoSheet(report);
    expect(sheet.title, 'Zubair Traders — Party statement');
    expect(sheet.heading, '13-11-2026 — 14-11-2026 · Imtiaz');
    expect(sheet.summary.head, isEmpty);
    expect(heads(sheet.tables.single), ['#', 'DATE', 'DESCRIPTION', 'AMOUNT']);
    expect(cells(sheet.tables.single.body), [
      ['1', '13-11-2026', 'Sale · 45 KG × 6', '137,975'],
      ['2', '14-11-2026', 'Cash', '—'],
    ]);
    expect(sheet.notes, ['Note']);
    // No rows: one line saying so, across the table.
    final empty = autoSheet(
      const Report(
        title: 't',
        business: 'b',
        subtitle: 's',
        columns: ['A', 'B'],
        rows: [],
      ),
    );
    expect(cells(empty.tables.single.body), [
      ['— Koi entry nahi —'],
    ]);
    expect(empty.tables.single.body.single.single.span, 3);
  });

  testWidgets('Every report prints as a PDF in English and Urdu', (
    tester,
  ) async {
    await loadFonts();
    int pagesOf(List<int> bytes) =>
        RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length;
    await tester.runAsync(() async {
      final (app, db, ago) = await start();
      // An Urdu name and a big wide register, as the business has them.
      await app.saveMaster('party', {
        'name': 'لقمان احمد Luqman Ahmad',
        'customer': true,
        'phone': '0300 1112223',
      });
      final luqman = app.partyByName('لقمان احمد Luqman Ahmad')!.id;
      final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
      for (var i = 0; i < 30; i++) {
        await app.post({
          'date': ago(1),
          'type': 'sale',
          'party': luqman,
          'quantities': {'11800': 120, '15000': 40, '45000': 12},
          'returned': {'11800': 120, '15000': 40, '45000': 12},
          'rate': 460000 + i * 100,
          'extraGrams': 12500,
          'cash': 30000000,
          'bank': 50000000,
          'bankAccount': hbl,
          'note': 'گودام کے پیچھے Delivered behind the godown',
        });
      }
      final from = ago(7), to = app.selectedDate;
      final previews = {
        'Party statement',
        'Sales register',
        'Customer balances',
        'Daily customer balances',
        'Profit report',
      };
      for (final kind in reportNames) {
        for (final urdu in [false, true]) {
          final report = buildReport(
            app,
            kind,
            from,
            to,
            party: kind == 'Party statement' ? luqman : null,
            account: kind == 'Bank book' ? hbl : null,
            urdu: urdu,
          );
          final bytes = await ReportExporter().pdf(report);
          expect(String.fromCharCodes(bytes.take(4)), '%PDF', reason: kind);
          expect(pagesOf(bytes), greaterThan(0), reason: kind);
          if (previews.contains(kind)) {
            final name = kind.toLowerCase().replaceAll(' ', '-');
            await File(
              'build/preview-report-$name${urdu ? '-urdu' : ''}.pdf',
            ).writeAsBytes(bytes);
          }
        }
      }
      final sale = app.book.documents.lastWhere((d) => d.party == luqman);
      for (final urdu in [false, true]) {
        await File(
          'build/preview-report-invoice${urdu ? '-urdu' : ''}.pdf',
        ).writeAsBytes(
          await ReportExporter().pdf(invoiceReport(app, sale, urdu: urdu)),
        );
      }
      app.dispose();
      await db.close();
    });
  });
}
