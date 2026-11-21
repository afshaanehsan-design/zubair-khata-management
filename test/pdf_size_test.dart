// The PDF preview's size slider: 50% to 200% in 5% steps, remembered for
// each kind of report until a reset, and printed into the PDF itself.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/features/reports/roznamcha_sheet.dart';
import 'package:zubair_khata_management/ui/export_ui.dart';

Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

int pagesOf(List<int> bytes) =>
    RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length;

/// A long list in the Roznamcha sheet design (no sheets of its own, so it is
/// printed through `autoSheet`), with Urdu names in both languages.
Report longList({required bool urdu, int grids = 1, int rows = 150}) => Report(
  kind: grids > 1 ? 'Pending balances' : 'Customer balances',
  title: grids > 1 ? 'Pending balances' : 'Customer balances',
  business: 'Zubair Traders',
  subtitle: '2026-11-16',
  columns: grids > 1
      ? const ['No.', 'Name', 'Baqaya jaat']
      : const ['Name', 'Phone', 'Balance'],
  rows: [
    for (var i = 0; i < rows; i++)
      [
        if (grids > 1) Cell('${i + 1}'),
        Cell(i.isEven ? 'علی رضا ${i + 1}' : 'Hassan Butt ${i + 1}'),
        if (grids == 1) const Cell('0300 1112223'),
        Cell.amount(12345600 * (i + 1)),
      ],
  ],
  urdu: urdu,
  grids: grids,
  flex: grids > 1 ? const [1, 4.6, 3] : const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('The size is remembered for each kind of report, 50% to 200%', () async {
    final (app, db) = await start();
    expect(app.pdfSize('Party statement'), 100);
    await app.setPdfSize('Party statement', 120);
    await app.setPdfSize('Pending balances', 52); // to the 5% step: 50
    await app.setPdfSize('Sales register', 175); // above the old 150
    await app.setPdfSize('Invoice', 400); // at most 200
    await app.setPdfSize('Cash book', 10); // at least 50
    expect(app.pdfSize('Party statement'), 120);
    expect(app.pdfSize('Pending balances'), 50);
    expect(app.pdfSize('Sales register'), 175);
    expect(app.pdfSize('Invoice'), 200);
    expect(app.pdfSize('Cash book'), 50);
    expect(app.pdfSize('Daily roznamcha'), 100);
    // Back to 100% forgets it.
    await app.setPdfSize('Cash book', 100);
    expect(app.pdfSizes.containsKey('Cash book'), isFalse);

    // Kept in this organization's database: a new start remembers it.
    app.dispose();
    final again = AppController(db);
    await again.initialize();
    expect(again.pdfSize('Party statement'), 120);
    expect(again.pdfSize('Sales register'), 175);
    expect(again.pdfSize('Invoice'), 200);
    expect(again.pdfSize('Cash book'), 100);

    // A damaged value only loses the sizes.
    await db.setMeta('pdf_sizes', '{"Party statement": 999, "Invoice": "x"');
    final damaged = AppController(db);
    await damaged.initialize();
    expect(damaged.pdfSizes, isEmpty);
    again.dispose();
    damaged.dispose();
    await db.close();
  });

  test('Reset all data forgets the sizes; a backup restore brings its own', () async {
    final (app, db) = await start();
    await app.setPdfSize('Party statement', 80);
    final backup = await app.backup();
    await app.setPdfSize('Party statement', 140);
    await app.setPdfSize('Invoice', 60);

    await app.resetAll();
    expect(app.pdfSizes, isEmpty);
    expect(app.pdfSize('Party statement'), 100);
    expect(await db.meta('pdf_sizes'), isNull);

    await app.restoreBackup(backup);
    expect(app.pdfSize('Party statement'), 80);
    expect(app.pdfSize('Invoice'), 100);
    app.dispose();
    await db.close();
  });

  test('The exporter keeps the size between 50% and 200%', () {
    expect(ReportExporter().size, 1);
    expect(ReportExporter(size: 2).size, 2);
    expect(ReportExporter(size: 3).size, ReportExporter.maxSize);
    expect(ReportExporter(size: .1).size, ReportExporter.minSize);
    expect(ReportExporter.minSize, AppController.pdfSizeMin / 100);
    expect(ReportExporter.maxSize, AppController.pdfSizeMax / 100);
  });

  test('A wide table shrinks to fit; above 150% as far as at 150%', () {
    // Up to 150% as it always was: down to 85% of the size, then it wraps.
    expect(sheetScale(1, 1), 1);
    expect(sheetScale(1, .9), .9);
    expect(sheetScale(1, .5), 1 * .85);
    expect(sheetScale(.5, .5), .5 * .85);
    expect(sheetScale(1.5, .5), 1.5 * .85);
    // Above it a narrow table still grows to the full size and a wider one
    // as far as the page allows, but a very wide one prints as at 150%
    // instead of at 85% of 200%, where its figures broke.
    expect(sheetScale(2, 1), 2);
    expect(sheetScale(2, .8), 1.6);
    expect(sheetScale(2, .5), 1.5 * .85);
    expect(sheetScale(1.75, .2), 1.5 * .85);
  });

  test('Pending balances grids hold more rows smaller, fewer bigger', () {
    expect(ReportExporter.gridRowsAt(1), ReportExporter.gridRows);
    expect(ReportExporter.gridRowsAt(.5), 97);
    expect(ReportExporter.gridRowsAt(1.5), 27);
    expect(ReportExporter.gridRowsAt(2), 18);
    var previous = 1 << 30;
    for (var p = 50; p <= 200; p += 5) {
      final rows = ReportExporter.gridRowsAt(p / 100);
      expect(rows, lessThanOrEqualTo(previous), reason: '$p%');
      previous = rows;
      // Everything on the page still fits in the 806 pt inside the margins.
      final s = p / 100;
      final used = (56 + 17 + 18 * 2 + 10) * s + 12 + rows * 15 * s;
      expect(used, lessThanOrEqualTo(806), reason: '$p%');
    }
  });

  testWidgets('The size bar steps by 5% and goes back to 100%', (tester) async {
    final chosen = <int>[];
    Future<void> show(double size) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(PdfSizeBar.height),
              child: PdfSizeBar(
                shown: size,
                onSliding: (_) {},
                onSet: chosen.add,
              ),
            ),
          ),
        ),
      ),
    );
    bool enabled(String key) =>
        tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).enabled;
    bool iconEnabled(String key) =>
        tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed != null;

    await show(100);
    expect(find.text('100%'), findsOneWidget);
    expect(enabled('pdf-size-reset'), isFalse);
    await tester.tap(find.byKey(const ValueKey('pdf-size-bigger')));
    await tester.tap(find.byKey(const ValueKey('pdf-size-smaller')));
    expect(chosen, [105, 95]);

    // A drag can stop between steps only by rounding; the buttons still
    // land on a 5% step.
    chosen.clear();
    await show(72.4);
    expect(find.text('72%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pdf-size-bigger')));
    await tester.tap(find.byKey(const ValueKey('pdf-size-smaller')));
    await tester.tap(find.byKey(const ValueKey('pdf-size-reset')));
    expect(chosen, [75, 70, 100]);

    // 150% is no longer the end: bigger goes on to 200%.
    chosen.clear();
    await show(150);
    await tester.tap(find.byKey(const ValueKey('pdf-size-bigger')));
    expect(chosen, [155]);
    await show(200);
    expect(find.text('200%'), findsOneWidget);
    expect(iconEnabled('pdf-size-bigger'), isFalse);
    expect(iconEnabled('pdf-size-smaller'), isTrue);
    await show(50);
    expect(iconEnabled('pdf-size-smaller'), isFalse);
    expect(iconEnabled('pdf-size-bigger'), isTrue);

    // Dragging the slider reports the size where it is let go.
    chosen.clear();
    await show(100);
    await tester.drag(
      find.byKey(const ValueKey('pdf-size')),
      const Offset(-2000, 0),
    );
    await tester.pumpAndSettle();
    expect(chosen.last, 50);
    await show(100);
    await tester.drag(
      find.byKey(const ValueKey('pdf-size')),
      const Offset(2000, 0),
    );
    await tester.pumpAndSettle();
    expect(chosen.last, 200);
  });

  testWidgets('Bigger prints more pages, smaller fewer, in both languages', (
    tester,
  ) async {
    await (FontLoader(
      'NotoUrdu',
    )..addFont(rootBundle.load('assets/fonts/NotoNastaliqUrdu.ttf'))).load();
    await (FontLoader(
      'Manrope',
    )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
    final arial = [
      for (final name in ['arial.ttf', 'arialbd.ttf'])
        File('C:/Windows/Fonts/$name'),
    ].where((f) => f.existsSync());
    final latin = FontLoader('Arial');
    for (final file in arial) {
      latin.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    if (arial.isEmpty) {
      latin.addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
    }
    await latin.load();

    await tester.runAsync(() async {
      for (final urdu in [false, true]) {
        final language = urdu ? 'urdu' : 'english';
        for (final grids in [1, 2]) {
          final report = longList(urdu: urdu, grids: grids);
          final pages = <int, int>{};
          for (final percent in [50, 100, 150, 200]) {
            final bytes = await ReportExporter(
              size: percent / 100,
            ).pdf(report);
            expect(String.fromCharCodes(bytes.take(4)), '%PDF');
            pages[percent] = pagesOf(bytes);
            await File(
              'build/preview-size-${grids > 1 ? 'grids' : 'sheet'}-$language-$percent.pdf',
            ).writeAsBytes(bytes);
          }
          final what = '$language, ${grids > 1 ? 'grids' : 'sheet'}: $pages';
          expect(pages[50]!, lessThan(pages[100]!), reason: what);
          expect(pages[100]!, lessThan(pages[150]!), reason: what);
          expect(pages[150]!, lessThan(pages[200]!), reason: what);
          // 100% is the PDF as it was before the slider.
          expect(
            pagesOf(await ReportExporter().pdf(report)),
            pages[100],
            reason: what,
          );
          if (grids > 1) {
            // 150 rows: 97, 45, 27 and 18 to a grid, two grids to a page.
            expect(pages, {50: 1, 100: 2, 150: 3, 200: 5}, reason: what);
          }
        }
      }
    });
  });
}
