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
    Report pending(
      String filter, {
      bool archived = false,
      PendingOrder order = PendingOrder.balance,
    }) => pendingReport(
      app,
      visibleParties(app, filter, archived),
      filter: filter,
      archived: archived,
      search: app.search,
      order: order,
    );

    final all = pending('All');
    expect(all.title, 'Pending balances');
    // The paper sheet: a number, the name and one balance, two grids a page.
    expect(all.columns, ['No.', 'Name', 'Baqaya jaat']);
    expect(all.grids, 2);
    expect(all.flex, hasLength(3));
    expect(all.flex.first, lessThan(all.flex.last));
    // The biggest balance on top: to receive, then to pay, each largest
    // first; settled Bilal and archived Kamran left out. To receive is
    // written plainly, to pay with a "+".
    expect(all.rows.map((r) => r.map((c) => c.text).toList()), [
      ['1', 'Ali Raza', '1,607,216'],
      ['2', 'Hassan Butt', '893,704'],
      ['3', 'PSO', '+500,000'],
      ['4', 'Umer Udhar', '+25,000'],
    ]);
    expect(all.sections, isEmpty, reason: 'nothing to shade');
    for (final row in all.rows) {
      final id = app.partyByName(row[1].text)!.id;
      expect(row[2].numeric, app.book.partyBalance(id) / 100);
    }
    expect(all.notes, [
      'Total (4): You will receive 2,500,920 · You will pay +525,000',
    ]);
    expect(
      all.subtitle,
      endsWith(' · All · Biggest balance first · + = You will pay'),
    );

    // Each filter chip prints only what it shows.
    expect(names(pending('Customers')), ['Ali Raza', 'Hassan Butt']);
    expect(names(pending('Companies')), ['PSO']);
    expect(names(pending('Udhari')), ['Umer Udhar']);
    expect(names(pending('You will receive')), ['Ali Raza', 'Hassan Butt']);
    final pay = pending('You will pay');
    expect(names(pay), ['PSO', 'Umer Udhar']);
    expect(pay.notes, [
      'Total (2): You will receive 0 · You will pay +525,000',
    ]);
    // The Archived switch adds archived parties, as on the page.
    final archived = pending('All', archived: true);
    expect(names(archived), [
      'Ali Raza',
      'Hassan Butt',
      'Kamran',
      'PSO',
      'Umer Udhar',
    ]);
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
    expect(pending('All').rows[2].map((c) => c.text), [
      '3',
      'Dono Taraf',
      '700',
    ]);

    // Arranged three ways, A to Z by default. A to Z ignores case: "aslam"
    // (written small) comes after "Ali Raza", not after every capital.
    await app.saveMaster('party', {
      'name': 'aslam',
      'customer': true,
    }, opening: 50000);
    final plain = pendingReport(app, visibleParties(app, 'All', false));
    expect(names(plain), [
      'Ali Raza',
      'aslam',
      'Dono Taraf',
      'Hassan Butt',
      'PSO',
      'Umer Udhar',
    ]);
    expect(plain.subtitle, endsWith(' · All · A to Z · + = You will pay'));
    expect(
      [for (final row in plain.rows) row[0].text],
      ['1', '2', '3', '4', '5', '6'],
      reason: 'numbered in the printed order',
    );
    expect(names(pending('All')), [
      'Ali Raza',
      'Hassan Butt',
      'Dono Taraf',
      'aslam',
      'PSO',
      'Umer Udhar',
    ]);
    // Newest first, as the Parties page lists them.
    final newest = pending('All', order: PendingOrder.newest);
    expect(names(newest), [
      'aslam',
      'Dono Taraf',
      'Umer Udhar',
      'PSO',
      'Hassan Butt',
      'Ali Raza',
    ]);
    expect(newest.subtitle, contains(' · Newest first · '));
    // The order never changes the totals.
    for (final order in PendingOrder.values) {
      expect(pending('All', order: order).notes, plain.notes);
    }

    // Urdu headings, as on the paper sheet.
    final urdu = pendingReport(
      app,
      visibleParties(app, 'All', false),
      urdu: true,
    );
    expect(urdu.title, 'بقایا جات');
    expect(urdu.columns, ['نمبر', 'نام', 'بقایا جات']);
    expect(urdu.subtitle, contains('الف سے ے (A سے Z)'));
    app.dispose();
    await db.close();
  });

  test('The day sheet lists only the balances that day changed', () async {
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    const before = '2026-11-01', day = '2026-11-10', after = '2026-11-11';
    // Saved in this order, so newest first is Umer, Bilal, PSO, Hassan, Ali.
    Future<String> party(String name, {int owes = 0, int owed = 0}) async {
      await app.saveMaster(
        'party',
        {'name': name, 'customer': owed == 0, 'supplier': owed != 0},
        opening: owes,
        supplierOpening: owed,
        openingDate: before,
      );
      return app.partyByName(name)!.id;
    }

    final ali = await party('Ali Raza', owes: 1000000);
    final hassan = await party('Hassan Butt', owes: 500000);
    final pso = await party('PSO', owed: 2000000);
    await party('Bilal', owes: 300000);
    final umer = await party('Umer', owes: 200000);
    // On the day: Ali pays 4,000 of his 10,000, Hassan clears his 5,000, PSO
    // is paid 8,000 of the 20,000 owed to it, and Umer buys a cylinder for
    // 3,000 and pays it in cash, so he still owes his 2,000. Bilal has no
    // entry. The day after, Ali pays 1,000 more.
    await app.post({
      'type': 'receipt',
      'date': day,
      'party': ali,
      'cash': 400000,
    });
    await app.post({
      'type': 'receipt',
      'date': day,
      'party': hassan,
      'cash': 500000,
    });
    await app.post({
      'type': 'payment',
      'date': day,
      'party': pso,
      'amount': 800000,
      'account': 'cash',
    });
    await app.post({
      'type': 'sale',
      'date': day,
      'party': umer,
      'quantities': {'11800': 1},
      'rate': 300000,
      'cash': 300000,
    });
    await app.post({
      'type': 'receipt',
      'date': after,
      'party': ali,
      'cash': 100000,
    });
    Report on(
      String date, {
      String filter = 'All',
      bool urdu = false,
      PendingOrder order = PendingOrder.name,
    }) =>
        pendingReport(
          app,
          visibleParties(app, filter, false),
          filter: filter,
          day: date,
          urdu: urdu,
          order: order,
        );
    List<List<String>> texts(Report r) => [
      for (final row in r.rows) [for (final c in row) c.text],
    ];

    // Balances at the end of the day, the cleared khata with its 0.
    final report = on(day);
    expect(report.title, 'Pending balances');
    expect(report.columns, ['No.', 'Name', 'Baqaya jaat']);
    expect(report.grids, 2);
    // A to Z by default.
    expect(texts(report), [
      ['1', 'Ali Raza', '6,000'],
      ['2', 'Hassan Butt', '0'],
      ['3', 'PSO', '+12,000'],
    ]);
    expect(report.sections, isEmpty, reason: 'every row changed that day');
    expect(report.notes, [
      'Total (3): You will receive 6,000 · You will pay +12,000',
    ]);
    expect(
      report.subtitle,
      '$day · Changed on this day only · All · A to Z · + = You will pay',
    );
    // Largest first, to receive before to pay (the cleared khata's 0 ends
    // the receivables), or newest first; the Details table follows suit.
    expect(names(on(day, order: PendingOrder.balance)), [
      'Ali Raza',
      'Hassan Butt',
      'PSO',
    ]);
    final newest = on(day, order: PendingOrder.newest);
    expect(names(newest), ['PSO', 'Hassan Butt', 'Ali Raza']);
    expect(
      [
        for (final row in newest.withCompact(true).sheets.single.tables.single.body)
          row[1].text,
      ],
      ['PSO', 'Hassan Butt', 'Ali Raza'],
    );
    // Off, the Details switch leaves the paper sheet's grids.
    expect(report.sheetSwitch, 'Details');
    expect(report.roznamchaSheets, isNotNull);
    expect(report.sheets, isEmpty);
    expect(report.withCompact(false).sheets, isEmpty);

    // On, one sheet: before the day, what the day added and took off, after.
    final detailed = report.withCompact(true);
    expect(detailed.compact, isTrue);
    expect(texts(detailed), texts(report), reason: 'rows unchanged');
    final sheet = detailed.sheets.single;
    expect(sheet.title, '${app.businessName} — Pending balances');
    expect(
      sheet.heading,
      '10-11-2026 · Changed on this day only · All · A to Z · + = You will pay',
    );
    List<String> line(List<SheetCell> cells) => [for (final c in cells) c.text];
    final table = sheet.tables.single;
    expect(line(table.head), [
      '#',
      'NAME',
      'PREVIOUS BALANCE',
      'DEBIT',
      'CREDIT',
      'BAQAYA JAAT',
    ]);
    expect(table.body.map(line), [
      ['1', 'Ali Raza', '10,000', '—', '4,000', '6,000'],
      ['2', 'Hassan Butt', '5,000', '—', '5,000', '0'],
      ['3', 'PSO', '+20,000', '8,000', '—', '+12,000'],
    ]);
    // 15,000 to receive less 20,000 to pay before; 6,000 less 12,000 after.
    expect(table.foot.map(line), [
      ['Total', '+5,000', '8,000', '9,000', '+6,000'],
    ]);
    expect(line(sheet.summary.head), [
      'PREVIOUS BALANCE',
      'DEBIT',
      'CREDIT',
      'BAQAYA JAAT',
    ]);
    expect(line(sheet.summary.body.single), [
      '+5,000 Parties 3',
      '8,000',
      '9,000',
      '+6,000 You will receive 6,000 | You will pay +12,000',
    ]);
    expect(sheet.notes, isEmpty);

    // The next day only Ali changed; the complete sheet is as before.
    expect(texts(on(after)), [
      ['1', 'Ali Raza', '5,000'],
    ]);
    expect(on(before).rows, hasLength(5), reason: 'the openings');
    expect(on('2026-11-05').rows, isEmpty);
    expect(on('2026-11-05').notes, isEmpty);
    final all = pendingReport(app, visibleParties(app, 'All', false));
    expect(names(all), ['Ali Raza', 'Bilal', 'PSO', 'Umer']);
    expect(all.roznamchaSheets, isNull, reason: 'no switch');
    expect(all.sections, isEmpty);
    // On the top bar's date the complete sheet is the balances at the end of
    // that day, with that date in its subtitle, and shades the parties whose
    // balance the day changed: Ali and PSO on the day (Hassan is settled,
    // Umer's sale was paid in cash), Ali alone the day after, nobody before.
    final shaded = pendingReport(
      app,
      visibleParties(app, 'All', false),
      asOf: day,
    );
    // Ali's 1,000 of the day after is not in it yet.
    expect(texts(shaded), [
      ['1', 'Ali Raza', '6,000'],
      ['2', 'Bilal', '3,000'],
      ['3', 'PSO', '+12,000'],
      ['4', 'Umer', '2,000'],
    ]);
    expect(shaded.subtitle, '$day · All · A to Z · + = You will pay');
    expect(shaded.sections, {0, 2});
    // The shading follows its rows into another order.
    expect(
      pendingReport(
        app,
        visibleParties(app, 'All', false),
        asOf: day,
        order: PendingOrder.balance,
      ).sections,
      {0, 3},
    );
    expect(shaded.notes, [
      'Total (4): You will receive 11,000 · You will pay +12,000',
      'Shaded: balance changed on 10-11-2026 (2)',
    ]);
    final next = pendingReport(
      app,
      visibleParties(app, 'All', false),
      asOf: after,
    );
    expect(texts(next), texts(all), reason: 'nothing after it');
    expect(next.sections, {0});
    // Before the day: Hassan still owes his 5,000, nothing changed that day.
    final quiet = pendingReport(
      app,
      visibleParties(app, 'All', false),
      asOf: '2026-11-05',
    );
    expect(names(quiet), ['Ali Raza', 'Bilal', 'Hassan Butt', 'PSO', 'Umer']);
    expect(quiet.rows.first[2].text, '10,000');
    expect(quiet.sections, isEmpty);
    expect(quiet.notes, hasLength(1), reason: 'no note without shading');
    // The day sheet never shades: every row changed.
    expect(
      pendingReport(
        app,
        visibleParties(app, 'All', false),
        day: day,
        asOf: day,
      ).sections,
      isEmpty,
    );
    // The page's filter applies to the day sheet too.
    expect(names(on(day, filter: 'Companies')), ['PSO']);
    expect(on(day, filter: 'Companies').subtitle, contains(' · Companies · '));

    // Urdu.
    final urdu = on(day, urdu: true);
    expect(urdu.subtitle, contains('صرف اس دن تبدیل ہونے والے'));
    expect(line(urdu.withCompact(true).sheets.single.tables.single.head), [
      '#',
      'نام',
      'سابقہ بقایا',
      'جمع',
      'منفی',
      'بقایا جات',
    ]);
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
    // The button offers the complete sheet or only the top bar's day.
    Future<void> choose(String key) async {
      await tester.tap(find.byKey(const ValueKey('parties-pending')));
      await tester.pumpAndSettle();
      expect(
        find.text('All pending balances · ${app.selectedDate}'),
        findsOneWidget,
      );
      expect(
        find.text('Changed on this day only · ${app.selectedDate}'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    // Under them, Arrange: exactly one of the three ticked, A to Z at first.
    // Choosing another ticks it instead and opens the menu again.
    List<bool> ticks() => [
      for (final order in PendingOrder.values)
        tester
            .widget<CheckedPopupMenuItem<String>>(
              find.byKey(ValueKey('parties-pending-order-${order.name}')),
            )
            .checked,
    ];
    expect(app.pendingOrder, PendingOrder.name);
    await tester.tap(find.byKey(const ValueKey('parties-pending')));
    await tester.pumpAndSettle();
    expect(find.text('Arrange'), findsOneWidget);
    expect(find.text('A to Z'), findsOneWidget);
    expect(find.text('Biggest balance first'), findsOneWidget);
    expect(find.text('Newest first'), findsWidgets);
    expect(ticks(), [true, false, false]);
    await tester.tap(find.byKey(const ValueKey('parties-pending-order-balance')));
    await tester.pumpAndSettle();
    expect(app.pendingOrder, PendingOrder.balance);
    expect(ticks(), [false, true, false], reason: 'the menu is open again');
    await tester.tap(find.byKey(const ValueKey('parties-pending-order-newest')));
    await tester.pumpAndSettle();
    expect(ticks(), [false, false, true]);
    await tester.tap(find.byKey(const ValueKey('parties-pending-order-name')));
    await tester.pumpAndSettle();
    expect(ticks(), [true, false, false]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Arrange'), findsNothing);
    expect(app.pendingOrder, PendingOrder.name);

    // Settled Bilal alone: the chosen list has nothing to print.
    app.setSearch('Bilal');
    await tester.pumpAndSettle();
    await choose('parties-pending-all');
    expect(find.text('No pending balances'), findsOneWidget);
    // Nor did his balance change on the day (once the first message is gone).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('No pending balances'), findsNothing);
    await choose('parties-pending-day');
    expect(find.text('No pending balance changed on this day'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    // The detailed day sheet draws Latin beside Urdu in Arial (Manrope where
    // it is missing); test mode draws squares for a font it has not loaded.
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
        final plain = pendingReport(
          app,
          visibleParties(app, 'All', false),
          urdu: urdu,
          asOf: app.selectedDate,
        );
        // Every opening is today's, so all are shaded: print every third
        // shaded instead, to see them beside plain rows. The shading note
        // keeps the page as full as it can be.
        expect(plain.sections, hasLength(plain.rows.length));
        final report = Report(
          title: plain.title,
          business: plain.business,
          subtitle: plain.subtitle,
          columns: plain.columns,
          rows: plain.rows,
          notes: plain.notes,
          urdu: urdu,
          sections: {
            for (var i = 0; i < plain.rows.length; i += 3) i,
          },
          grids: plain.grids,
          flex: plain.flex,
        );
        expect(report.notes, hasLength(2));
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
      // Two full grids and the totals under them are one page, in Urdu too
      // (its heading and totals are taller); one more goes to a second page.
      Future<void> add(int i) => app.saveMaster('party', {
        'name': 'Party ${i + 1}',
        'customer': true,
      }, opening: 100 * (i + 1));
      for (var i = 36; i < 2 * ReportExporter.gridRows - 4; i++) {
        await add(i);
      }
      expect(pagesOf(await build(false, 'preview-pending-full.pdf')), 1);
      expect(pagesOf(await build(true, 'preview-pending-full-urdu.pdf')), 1);
      await add(2 * ReportExporter.gridRows - 4);
      expect(pagesOf(await build(false, 'preview-pending-long.pdf')), 2);
      // The day sheet (every opening above is today's), plain and detailed.
      for (final urdu in [false, true]) {
        final day = pendingReport(
          app,
          visibleParties(app, 'All', false),
          day: app.selectedDate,
          urdu: urdu,
        );
        expect(
          day.rows.length,
          pendingReport(app, visibleParties(app, 'All', false)).rows.length,
        );
        for (final (report, name) in [
          (day, 'day'),
          (day.withCompact(true), 'day-details'),
        ]) {
          final bytes = await ReportExporter().pdf(report);
          expect(String.fromCharCodes(bytes.take(4)), '%PDF');
          await File(
            'build/preview-pending-$name${urdu ? '-urdu' : ''}.pdf',
          ).writeAsBytes(bytes);
        }
      }
      app.dispose();
      await db.close();
    });
  });
}
