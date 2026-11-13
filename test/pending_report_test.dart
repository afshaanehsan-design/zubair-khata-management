import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/pages.dart';

/// Ali and Hassan owe us, PSO and Umer are owed, Bilal is settled and
/// Kamran (owes 900) is archived. Saved in that order, so newest first is
/// Kamran, Bilal, Umer, PSO, Hassan, Ali.
Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  await app.saveMaster('party', {
    'name': 'Ali Raza',
    'customer': true,
  }, opening: 160721600);
  await app.saveMaster('party', {
    'name': 'Hassan Butt',
    'customer': true,
    'phone': '0300 1112223',
  }, opening: 89370400);
  await app.saveMaster('party', {
    'name': 'PSO',
    'customer': false,
    'supplier': true,
  }, supplierOpening: 50000000);
  await app.saveMaster('party', {
    'name': 'Umer Udhar',
    'customer': false,
    'udhari': true,
  }, supplierOpening: 2500000);
  await app.saveMaster('party', {'name': 'Bilal', 'customer': true});
  await app.saveMaster('party', {
    'name': 'Kamran',
    'customer': true,
  }, opening: 90000);
  final kamran = app.partyByName('Kamran')!;
  await app.saveMaster('party', {
    ...kamran.data,
    'archived': true,
  }, existing: kamran);
  return (app, db);
}

List<String> names(Report r) => [for (final row in r.rows) row[1].text];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Pending balances print the filtered list in one column', () async {
    final (app, db) = await start();
    Report pending(String filter, {bool archived = false}) => pendingReport(
      app,
      visibleParties(app, filter, archived),
      filter: filter,
      archived: archived,
      search: app.search,
    );

    final all = pending('All');
    expect(all.title, 'Pending balances');
    // The paper sheet: a number, the name and one balance, two grids a page.
    expect(all.columns, ['No.', 'Name', 'Baqaya jaat']);
    expect(all.grids, 2);
    expect(all.flex, hasLength(3));
    expect(all.flex.first, lessThan(all.flex.last));
    // Newest first like the list; settled Bilal and archived Kamran left out.
    // To receive is written plainly, to pay with a "+".
    expect(all.rows.map((r) => r.map((c) => c.text).toList()), [
      ['1', 'Umer Udhar', '+25,000'],
      ['2', 'PSO', '+500,000'],
      ['3', 'Hassan Butt', '893,704'],
      ['4', 'Ali Raza', '1,607,216'],
    ]);
    for (final row in all.rows) {
      final id = app.partyByName(row[1].text)!.id;
      expect(row[2].numeric, app.book.partyBalance(id) / 100);
    }
    expect(all.notes, [
      'Total (4): You will receive 2,500,920 · You will pay +525,000',
    ]);
    expect(all.subtitle, endsWith(' · All · + = You will pay'));

    // Each filter chip prints only what it shows.
    expect(names(pending('Customers')), ['Hassan Butt', 'Ali Raza']);
    expect(names(pending('Companies')), ['PSO']);
    expect(names(pending('Udhari')), ['Umer Udhar']);
    expect(names(pending('You will receive')), ['Hassan Butt', 'Ali Raza']);
    final pay = pending('You will pay');
    expect(names(pay), ['Umer Udhar', 'PSO']);
    expect(pay.notes, [
      'Total (2): You will receive 0 · You will pay +525,000',
    ]);
    // The Archived switch adds archived parties, as on the page.
    final archived = pending('All', archived: true);
    expect(names(archived).first, 'Kamran');
    expect(archived.subtitle, contains(' · All · Archived · '));
    // So does the search in the top bar (name or phone).
    app.search = '0300';
    final found = pending('All');
    expect(names(found), ['Hassan Butt']);
    expect(found.subtitle, contains(' · All · Search: 0300 · '));
    // Nothing pending: no rows and no totals.
    app.search = 'Bilal';
    expect(pending('All').rows, isEmpty);
    expect(pending('All').notes, isEmpty);
    app.search = '';

    // A party with both sides shows its one khata balance: 1,000 to receive
    // less 300 to pay.
    await app.saveMaster(
      'party',
      {'name': 'Dono Taraf', 'customer': true},
      opening: 100000,
      supplierOpening: 30000,
    );
    expect(pending('All').rows.first.map((c) => c.text), [
      '1',
      'Dono Taraf',
      '700',
    ]);

    // Urdu headings, as on the paper sheet.
    final urdu = pendingReport(
      app,
      visibleParties(app, 'All', false),
      urdu: true,
    );
    expect(urdu.title, 'بقایا جات');
    expect(urdu.columns, ['نمبر', 'نام', 'بقایا جات']);
    app.dispose();
    await db.close();
  });

  testWidgets('Parties page has the Pending balances button', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, db) = (await tester.runAsync(start))!;
    app.go('parties');
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parties-pending')), findsOneWidget);
    // Settled Bilal alone: the chosen list has nothing to print.
    app.setSearch('Bilal');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('parties-pending')));
    await tester.pumpAndSettle();
    expect(find.text('No pending balances'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      app.dispose();
      await db.close();
    });
  });

  testWidgets('Pending balances PDF: two grids a page, English and Urdu', (
    tester,
  ) async {
    await (FontLoader(
      'NotoUrdu',
    )..addFont(rootBundle.load('assets/fonts/NotoNastaliqUrdu.ttf'))).load();
    // The names of the paper sheet, with deep and tall letters and a long one.
    const sheet = [
      'لقمان احمد',
      'علی رضا',
      'میاں شہزاد',
      'حسن بٹ',
      'سلمان .GH',
      'ریاست چاگوال',
      'عبدالرشید پٹی',
      'چیمہ ٹریڈرز',
      'چاند (BS)',
      'ملک سجاد بوبی',
      'مفتی منور',
      'JU Gas',
      'Pyramid',
      'استاد عثمان صاحب لاہور والے پرانی منڈی',
    ];
    int pagesOf(List<int> bytes) =>
        RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length;
    await tester.runAsync(() async {
      final (app, db) = await start();
      Future<List<int>> build(bool urdu, String file) async {
        final report = pendingReport(
          app,
          visibleParties(app, 'All', false),
          urdu: urdu,
        );
        final bytes = await ReportExporter().pdf(report);
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        await File('build/$file').writeAsBytes(bytes);
        return bytes;
      }

      for (var i = 0; i < 36; i++) {
        await app.saveMaster(
          'party',
          {'name': '${sheet[i % sheet.length]} ${i + 1}', 'customer': true},
          opening: i.isEven ? 1234500 * (i + 1) : 0,
          supplierOpening: i.isOdd ? 987600 * (i + 1) : 0,
        );
      }
      // 40 pending: one page, shared 20 and 20 between the grids.
      expect(pagesOf(await build(false, 'preview-pending-english.pdf')), 1);
      expect(pagesOf(await build(true, 'preview-pending-urdu.pdf')), 1);
      // One more than two full grids goes to a second page.
      for (var i = 36; i < 2 * ReportExporter.gridRows - 3; i++) {
        await app.saveMaster('party', {
          'name': 'Party ${i + 1}',
          'customer': true,
        }, opening: 100 * (i + 1));
      }
      expect(pagesOf(await build(false, 'preview-pending-long.pdf')), 2);
      app.dispose();
      await db.close();
    });
  });
}
