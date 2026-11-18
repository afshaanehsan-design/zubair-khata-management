import 'dart:io';

import 'package:drift/native.dart';
import 'package:excel/excel.dart' as xls;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/daily_report.dart';
import 'package:zubair_khata_management/features/reports/report_sheet.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/reports_page.dart';

const first = '2026-11-01', second = '2026-11-02', last = '2026-11-03';

Future<(AppController, String, String)> setup() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  app.setDate(first);
  addTearDown(() async {
    app.dispose();
    await db.close();
  });
  await app.saveMaster('party', {'name': 'Ali', 'customer': true});
  await app.saveMaster('party', {
    'name': 'PSO',
    'supplier': true,
    'udhari': true,
  });
  await app.saveMaster('account', {'name': 'HBL', 'bank': 'HBL'});
  final customer = app.partyByName('Ali')!.id;
  final supplier = app.partyByName('PSO')!.id;
  final bank = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
  for (final (date, grams, rate) in [
    ('2026-10-31', 100000, 10000),
    (first, 200000, 20000),
    (first, 300000, 30000),
  ]) {
    await app.post({
      'type': 'purchase',
      'date': date,
      'occurredAt': 0,
      'party': supplier,
      'grams': grams,
      'rate': rate,
      'rateUnit': 1000,
    });
  }
  for (final amount in [12345, 67890]) {
    await app.post({
      'type': 'sale',
      'date': first,
      'party': customer,
      'quantities': {'11800': 1},
      'rate': 472000,
      'cash': amount,
      'dueDate': second,
    });
  }
  await app.post({
    'type': 'sale',
    'date': first,
    'party': customer,
    'extraGrams': 2000,
    'bulkAtCost': true,
  });
  await app.post({
    'type': 'receipt',
    'date': second,
    'party': customer,
    'cash': 10000,
    'bank': 20000,
    'bankAccount': bank,
  });
  await app.post({
    'type': 'deposit',
    'date': second,
    'party': customer,
    'amount': 45000,
    'account': 'cash',
  });
  for (final amount in [10001, 20002]) {
    await app.post({
      'type': 'expense',
      'date': second,
      'category': 'Office',
      'amount': amount,
      'account': 'cash',
    });
  }
  return (app, customer, bank);
}

List<List<Object?>> values(Report report) => [
  for (final row in report.rows)
    [
      for (final cell in row) [cell.text, cell.numeric],
    ],
];

List<List<Cell>> days(Report report) => report.rows
    .where((row) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(row.first.text))
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('All reports have one row per day in both languages; switching restores detail', () async {
    final (app, customer, bank) = await setup();
    final records = canonicalJson(app.records.map((r) => r.toJson()).toList());
    for (final kind in reportNames) {
      for (final urdu in [false, true]) {
        final detailed = buildReportView(
          app,
          kind,
          first,
          last,
          party: customer,
          account: bank,
          urdu: urdu,
        );
        final compact = detailed.withCompact(true);
        final daily = days(compact);
        expect(compact.compact, isTrue, reason: kind);
        expect(
          daily.map((r) => r.first.text).toSet().length,
          daily.length,
          reason: kind,
        );
        expect(
          compact.rows.every((r) => r.length == compact.columns.length),
          isTrue,
          reason: kind,
        );
        expect(compact.sheets.single.heading, contains(Words(urdu)('Compact')));
        final table = compact.sheets.single.tables.single;
        for (final (i, row) in daily.indexed) {
          expect(
            table.body[i].skip(1).map((c) => c.text),
            row.map((c) => sheetText(c.text)),
            reason: kind,
          );
        }
        expect(
          values(compact.withCompact(false)),
          values(detailed),
          reason: kind,
        );
        expect(
          values(
            buildReportView(
              app,
              kind,
              first,
              last,
              party: customer,
              account: bank,
              urdu: urdu,
              compact: true,
            ),
          ),
          values(compact),
          reason: kind,
        );
      }
    }
    expect(canonicalJson(app.records.map((r) => r.toJson()).toList()), records);
  });

  test('Gas movements sum per day; closing stock and opening stock are never added', () async {
    final (app, _, _) = await setup();
    final r = buildReportView(app, 'Gas stock', first, last, compact: true);
    expect(days(r), hasLength(1));
    expect(days(r).single[1].numeric, 474.4); // 500 KG in, 25.6 KG out.
    expect(
      days(r).single[2].numeric,
      574.4,
    ); // Includes 100 KG brought forward.
    expect(r.rows.last[1].numeric, 474.4);
    expect(r.rows.last[2].numeric, 574.4);
    final quiet = buildReportView(app, 'Gas stock', last, last, compact: true);
    expect(days(quiet).single[1].numeric, 0);
    expect(days(quiet).single[2].numeric, 574.4);
  });

  test(
    'Registers preserve exact totals, leave out rates, and snapshots are daily',
    () async {
      final (app, customer, bank) = await setup();
      for (final kind in [
        'Sales register',
        'Purchase register',
        'Purchase shares',
        'Office expenses',
        'Overdue',
      ]) {
        final full = buildReportView(app, kind, first, last);
        final small = full.withCompact(true);
        for (var i = 1; i < small.columns.length; i++) {
          final sourceColumn = full.columns.indexOf(small.columns[i]);
          expect(
            small.rows.last[i].numeric,
            closeTo(full.rows.last[sourceColumn].numeric!, 0.000001),
            reason: '$kind ${small.columns[i]}',
          );
        }
        expect(small.columns, isNot(contains('Rate')));
      }
      for (final kind in ['Cash book', 'Bank book', 'Party statement']) {
        final r = buildReportView(
          app,
          kind,
          first,
          last,
          party: customer,
          account: bank,
          compact: true,
        );
        for (final row in days(r)) {
          final book = app.bookAt(row[0].text);
          expect(
            row[3].numeric,
            (kind == 'Cash book'
                    ? book.money('cash')
                    : kind == 'Bank book'
                    ? book.money(bank)
                    : book.partyBalance(customer)) /
                100,
          );
          if (kind == 'Party statement') {
            expect(row[6].numeric, book.deposits(customer) / 100);
          }
        }
        expect(r.rows.last[3].numeric, days(r).first[3].numeric);
      }
      for (final kind in [
        'Customer balances',
        'Udhari',
        'Cylinder custody',
        'Deposit liabilities',
      ]) {
        final r = buildReportView(app, kind, first, last, compact: true);
        expect(days(r).map((r) => r[0].text), [last, second, first]);
        expect(r.rows, hasLength(3)); // No sum of snapshots in a Total row.
      }
      final deposits = buildReportView(
        app,
        'Deposit liabilities',
        first,
        last,
        compact: true,
      );
      expect(days(deposits).map((r) => r[1].numeric), [450, 450, 0]);
    },
  );

  test(
    'Empty reports switch safely; CSV and Excel export the chosen daily rows',
    () async {
      final (app, customer, bank) = await setup();
      for (final kind in reportNames) {
        final r = buildReportView(
          app,
          kind,
          '2026-10-01',
          '2026-10-02',
          party: customer,
          account: bank,
          compact: true,
        );
        expect(r.sheets, hasLength(1), reason: kind);
        expect(
          r.rows.every((row) => row.length == r.columns.length),
          isTrue,
          reason: kind,
        );
        expect(
          r.rows.expand((row) => row).every((c) => (c.numeric ?? 0) == 0),
          isTrue,
          reason: kind,
        );
      }
      final r = buildReportView(
        app,
        'Office expenses',
        first,
        last,
        compact: true,
      );
      expect(days(r).single[1].numeric, 300.03);
      final exporter = ReportExporter();
      expect(exporter.csv(r), contains('300.03'));
      expect(exporter.csv(r), isNot(contains('100.01')));
      final sheet = xls.Excel.decodeBytes(exporter.excel(r)).tables['Report']!;
      expect(sheet.rows[4][0]!.value.toString(), second);
      expect((sheet.rows[4][1]!.value as xls.DoubleCellValue).value, 300.03);
    },
  );

  test('Audit days use Karachi dates, respect the range and deduplicate synced commands', () async {
    final (app, _, _) = await setup();
    app.commands = [
      for (final (id, instant) in [
        ('before', '2026-10-31T18:59:59Z'),
        ('synced', '2026-10-31T19:01:00Z'),
        ('one', '2026-11-01T17:00:00Z'),
        ('two', '2026-11-01T19:00:00Z'),
        ('after', '2026-11-02T19:00:00Z'),
      ])
        Command(
          id: id,
          device: 'device',
          epoch: 'epoch',
          action: 'post',
          changes: [],
          created: DateTime.parse(instant).microsecondsSinceEpoch,
        ),
    ];
    app.records.add(
      const Record('audit1', 'audit', {
        'command_id': 'synced',
        'receivedAt': '2026-10-31T19:02:00Z',
        'action': 'post',
        'device': 'device',
      }),
    );
    final full = buildReportView(app, 'Audit trail', first, second);
    expect(full.rows, hasLength(3));
    final small = full.withCompact(true);
    expect(days(small).map((r) => [r[0].text, r[1].numeric]), [
      [second, 1],
      [first, 2],
    ]);
    expect(small.rows.last[1].numeric, 3);
  });

  testWidgets(
    'Reports page toggle changes every report and fits English and Urdu',
    (tester) async {
      await initializeDateFormatting();
      final (app, _, _) = await setup();
      app.go('reports');
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1366, 900);
      await tester.pumpWidget(KhataApp(app));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('reports-compact'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReportDataTable>(find.byType(ReportDataTable))
            .report
            .compact,
        isTrue,
      );
      for (final kind in reportNames) {
        final tile = find.widgetWithText(ListTile, kind);
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        final report = tester
            .widget<ReportDataTable>(find.byType(ReportDataTable))
            .report;
        expect(report.compact, isTrue, reason: kind);
        expect(report.kind, kind);
      }
      for (final language in ['en', 'ur']) {
        app.language = language;
        for (final size in [
          const Size(1366, 900),
          const Size(390, 844),
          const Size(360, 640),
        ]) {
          tester.view.physicalSize = size;
          app.notifyListeners();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$language $size');
        }
      }
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReportDataTable>(find.byType(ReportDataTable))
            .report
            .compact,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Daily PDFs render all reports in English and Urdu', (
    tester,
  ) async {
    for (final (family, asset) in [
      ('Manrope', 'assets/fonts/Manrope.ttf'),
      ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final arial = FontLoader('Arial');
    for (final name in ['arial.ttf', 'arialbd.ttf']) {
      final file = File('C:/Windows/Fonts/$name');
      if (file.existsSync()) {
        arial.addFont(
          Future.value(ByteData.sublistView(file.readAsBytesSync())),
        );
      }
    }
    await arial.load();
    final (app, customer, bank) = await setup();
    await tester.runAsync(() async {
      for (final urdu in [false, true]) {
        for (final kind in reportNames) {
          final report = buildReportView(
            app,
            kind,
            first,
            last,
            party: customer,
            account: bank,
            urdu: urdu,
            compact: true,
          );
          final pdf = await ReportExporter().pdf(report);
          expect(String.fromCharCodes(pdf.take(4)), '%PDF', reason: kind);
          if (kind == 'Gas stock') {
            await File('build/daily-gas-stock-${urdu ? 'ur' : 'en'}.pdf')
                .writeAsBytes(pdf);
          }
        }
      }
    });
  });
}
