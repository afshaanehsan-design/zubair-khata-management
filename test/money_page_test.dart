// The Money page: archiving, reconciliation, the top-bar date, bank-to-bank
// transfers, clickable balance cards, Total bank and the money statement.
import 'dart:convert';
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
import 'package:zubair_khata_management/ui/components.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';

String dayBefore(String date) =>
    DateTime.parse(date)
        .subtract(const Duration(days: 1))
        .toIso8601String()
        .substring(0, 10);

/// The app on the Money page with Cash Rs 111,000 and Faisal (Alfalah)
/// Rs 129,600, both entered as opening balances yesterday.
Future<(AppController, KhataDatabase)> openMoney(WidgetTester tester) async {
  await initializeDateFormatting('en');
  tester.view.physicalSize = const Size(1440, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  final today = app.selectedDate;
  app.setDate(dayBefore(today));
  await app.post({
    'type': 'adjustment',
    'date': app.selectedDate,
    'target': 'money:cash',
    'amount': 11100000,
    'note': 'Opening',
    'occurredAt': 0,
  });
  await app.saveMaster('account', {
    'name': 'Faisal',
    'bank': 'Alfalah',
  }, opening: 12960000);
  app.setDate(today);
  await tester.pumpWidget(KhataApp(app));
  await tester.pumpAndSettle();
  app.go('money');
  await tester.pumpAndSettle();
  return (app, db);
}

Future<void> close(
  WidgetTester tester,
  AppController app,
  KhataDatabase db,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  app.dispose();
  await db.close();
}

/// Lets a closing dialog finish, then waits past the short delay a text
/// dialog keeps before it hands back its answer.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Lets messages at the bottom of the screen time out.
Future<void> clearMessages(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

/// Picks [item] from the ••• menu of an account row.
Future<void> choose(WidgetTester tester, String account, String item) async {
  await tester.tap(
    find.descendant(
      of: find.ancestor(
        of: find.text(account),
        matching: find.byType(ListTile),
      ),
      matching: find.byIcon(Icons.more_horiz),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Archive needs Rs 0, asks first, and can be undone', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);
    final faisal = app.ofKind('account').firstWhere((a) => a.name == 'Faisal');

    // Money in the account: refused, so no money disappears from the page.
    await choose(tester, 'Faisal', 'Archive');
    expect(find.textContaining('Faisal still has Rs 129,600'), findsOneWidget);
    expect(find.text('Pakka?'), findsNothing);
    expect(app.record(faisal.id)!.archived, isFalse);
    await clearMessages(tester);

    await app.saveMaster('account', {'name': 'Old HBL', 'bank': 'HBL'});
    await tester.pumpAndSettle();
    final old = app.ofKind('account').firstWhere((a) => a.name == 'Old HBL');

    // An empty account: asks first, and "Nahi" keeps it.
    await choose(tester, 'Old HBL', 'Archive');
    expect(find.text('Pakka?'), findsOneWidget);
    await tester.tap(find.text('Nahi'));
    await tester.pumpAndSettle();
    expect(app.record(old.id)!.archived, isFalse);

    await choose(tester, 'Old HBL', 'Archive');
    await tester.tap(find.text('Haan'));
    await tester.pumpAndSettle();
    expect(app.record(old.id)!.archived, isTrue);
    expect(find.text('Account archived'), findsOneWidget);
    expect(find.text('Old HBL'), findsNothing);

    // It is listed under Archived and comes back with Restore.
    await tester.tap(find.text('Archived (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Old HBL'), findsOneWidget);
    await choose(tester, 'Old HBL', 'Restore');
    expect(app.record(old.id)!.archived, isFalse);
    expect(find.text('Archived (1)'), findsNothing);
    expect(find.text('Old HBL'), findsNWidgets(2)); // card and row
    await close(tester, app, db);
  });

  testWidgets('Reconciliation saves only a confirmed difference', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);
    int corrections() => app.book.documents
        .where(
          (d) =>
              d.type == EntryType.adjustment &&
              d.data['target'] == 'money:cash',
        )
        .length;
    final before = corrections();

    Future<void> count(String value) async {
      await choose(tester, 'Cash', 'Account reconciliation');
      expect(find.text('111000.00'), findsOneWidget); // the app's balance
      await tester.enterText(find.byType(TextField).last, value);
      await tester.tap(find.text('Confirm'));
      await settle(tester);
    }

    // The count matches: nothing to save.
    await count('111000');
    expect(find.text('Balance matches. Nothing to correct.'), findsOneWidget);
    expect(corrections(), before);
    await clearMessages(tester);

    // Cancelling the reason saves nothing and does not say "Saved".
    await count('110500');
    expect(find.text('Reason for correction (-Rs 500)'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text('Saved'), findsNothing);
    expect(corrections(), before);

    // A confirmed difference is saved as a correction.
    await count('110500');
    await tester.enterText(find.byType(TextField).last, 'Drawer counted');
    await tester.tap(find.text('Confirm'));
    await settle(tester);
    expect(find.text('Saved'), findsOneWidget);
    expect(corrections(), before + 1);
    expect(app.book.money('cash'), 11050000);
    await close(tester, app, db);
  });

  testWidgets('Every number follows the top-bar date', (tester) async {
    final (app, db) = await openMoney(tester);
    final today = app.selectedDate, yesterday = dayBefore(today);
    await app.saveMaster('party', {'name': 'Ali'});
    await app.post({
      'type': 'receipt',
      'date': today,
      'party': app.partyByName('Ali')!.id,
      'cash': 100000,
    });
    await tester.pumpAndSettle();

    // Today: the latest balance and today's change, with no stray "·".
    expect(find.text('Rs 112,000'), findsNWidgets(2)); // card and row
    expect(find.text('Change today: +Rs 1,000'), findsOneWidget);
    expect(find.text('Alfalah · Change today: Rs 0'), findsOneWidget);
    expect(find.textContaining('not today'), findsNothing);

    // Yesterday: balances at the end of yesterday, labelled with its date.
    app.setDate(yesterday);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, yesterday), findsOneWidget);
    expect(find.text('Rs 111,000'), findsNWidgets(2));
    expect(find.text('Change on $yesterday: +Rs 111,000'), findsOneWidget);
    expect(
      find.text('These balances are for the end of $yesterday, not today.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Go to today'));
    await tester.pumpAndSettle();
    expect(app.selectedDate, today);
    expect(find.text('Rs 112,000'), findsNWidgets(2));
    await close(tester, app, db);
  });

  testWidgets('Bank se bank transfer offers bank accounts only', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);

    // One bank account: nothing to transfer between.
    await tester.tap(find.text('Bank se bank transfer'));
    await tester.pumpAndSettle();
    expect(
      find.text('Add a second bank account to transfer between banks.'),
      findsOneWidget,
    );
    expect(find.byType(EntryComposer), findsNothing);

    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank se bank transfer'));
    await tester.pumpAndSettle();
    expect(find.byType(EntryComposer), findsOneWidget);
    final banks = [
      for (final a in app.ofKind('account'))
        if (a.id != 'cash') a.id,
    ];
    for (final label in ['From account', 'To account']) {
      final dropdown = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(DropdownButtonFormField<String>),
          ),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(dropdown.value, isNull, reason: '$label starts empty, not Cash');
      expect([
        for (final i in dropdown.items!) i.value,
      ], unorderedEquals(banks));
    }
    await close(tester, app, db);
  });

  testWidgets('Only clickable cards show the arrow', (tester) async {
    final (app, db) = await openMoney(tester);
    final arrows = find.descendant(
      of: find.byType(Metric),
      matching: find.byIcon(Icons.north_east_rounded),
    );
    // Cash and Faisal open their statements, Total bank the money statement.
    expect(arrows, findsNWidgets(3));
    for (final card in tester.widgetList<Metric>(find.byType(Metric))) {
      expect(card.onTap, isNotNull);
    }
    app.go('stock');
    await tester.pumpAndSettle();
    expect(find.byType(Metric), findsWidgets);
    expect(arrows, findsNothing);
    await close(tester, app, db);
  });

  testWidgets('Total bank comes right after Cash and adds up every bank', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);
    await app.saveMaster('account', {
      'name': 'Zubair',
      'bank': 'HBL',
    }, opening: 5000000);
    await tester.pumpAndSettle();
    expect(
      [for (final m in tester.widgetList<Metric>(find.byType(Metric))) m.label],
      ['Cash', 'Total bank', 'Faisal', 'Zubair'],
    );
    final total = find.byKey(const ValueKey('money-total-bank'));
    // Faisal 129,600 + Zubair 50,000.
    expect(
      find.descendant(of: total, matching: find.text('Rs 179,600')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: total, matching: find.text('Banks: 2')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('money-statement')), findsOneWidget);
    // Yesterday Zubair did not exist yet.
    app.setDate(dayBefore(app.selectedDate));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: total, matching: find.text('Rs 129,600')),
      findsOneWidget,
    );
    await close(tester, app, db);
  });

  /// Cash 111,000, Faisal (Alfalah) 129,600 and Old (HBL) 5,000 yesterday.
  /// Today Ali pays 1,000 cash, Old's 5,000 moves to Faisal and Old is
  /// archived.
  Future<(AppController, KhataDatabase, String)> statementDays() async {
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    final today = app.selectedDate;
    app.setDate(dayBefore(today));
    await app.post({
      'type': 'adjustment',
      'date': app.selectedDate,
      'target': 'money:cash',
      'amount': 11100000,
      'note': 'Opening',
      'occurredAt': 0,
    });
    await app.saveMaster('account', {
      'name': 'Faisal',
      'bank': 'Alfalah',
    }, opening: 12960000);
    await app.saveMaster('account', {
      'name': 'Old',
      'bank': 'HBL',
    }, opening: 500000);
    app.setDate(today);
    String id(String name) =>
        app.ofKind('account').firstWhere((a) => a.name == name).id;
    final faisal = id('Faisal'), old = id('Old');
    await app.saveMaster('party', {'name': 'Ali'});
    await app.post({
      'type': 'receipt',
      'date': today,
      'party': app.partyByName('Ali')!.id,
      'cash': 100000,
    });
    await app.post({
      'type': 'transfer',
      'date': today,
      'account': old,
      'toAccount': faisal,
      'amount': 500000,
    });
    final record = app.record(old)!;
    await app.saveMaster('account', {
      ...record.data,
      'archived': true,
    }, existing: record);
    return (app, db, today);
  }

  test('The money statement gives every account, Cash, Total bank and '
      'Total', () async {
    final (app, db, today) = await statementDays();
    final yesterday = dayBefore(today);
    List<List<String>> table(Report r) => [
      for (final row in r.rows) [for (final c in row) c.text],
    ];

    final report = moneyReport(app, today);
    expect(report.title, 'Cash and bank statement');
    expect(report.columns, [
      'Account',
      'Bank',
      'Opening',
      'Money in',
      'Money out',
      'Closing',
    ]);
    // Opening + in − out = closing; Old moved its money today, so it is
    // still listed although archived.
    expect(table(report), [
      ['Cash', '', '111,000', '1,000', '0', '112,000'],
      ['Faisal', 'Alfalah', '129,600', '5,000', '0', '134,600'],
      ['Old', 'HBL', '5,000', '0', '5,000', '0'],
      ['Cash', '', '111,000', '1,000', '0', '112,000'],
      ['Total bank', '', '134,600', '5,000', '5,000', '134,600'],
      ['Total (Cash + Bank)', '', '245,600', '6,000', '5,000', '246,600'],
    ]);
    // The same Total bank as the page's card.
    expect(app.bookAt(today).bankMoney, 13460000);

    // The PDF: one Roznamcha-style sheet.
    final sheet = report.sheets.single;
    expect(sheet.title, 'Cash and bank statement');
    expect(sheet.stamp, startsWith('Date: ${rozDmy(today)} | Print: '));
    expect(
      sheet.heading,
      '${rozDmy(today)} Total (Cash + Bank): Rs. 246,600',
    );
    expect([for (final c in sheet.summary.head) c.text], [
      'CASH',
      'TOTAL BANK',
      'TOTAL (CASH + BANK)',
    ]);
    expect([for (final c in sheet.summary.body.single) c.text], [
      'Rs. 112,000 Opening 111,000',
      'Rs. 134,600 Opening 134,600',
      'Rs. 246,600 Cash 112,000 | Bank 134,600',
    ]);
    final accounts = sheet.table('Cash and bank accounts')!;
    expect([for (final c in accounts.head) c.text], [
      '#',
      'ACCOUNT',
      'BANK',
      'OPENING',
      'MONEY IN',
      'MONEY OUT',
      'CLOSING',
    ]);
    expect(
      [
        for (final row in accounts.body) [for (final c in row) c.text],
      ],
      [
        ['1', 'Cash', '—', '111,000', '1,000', '—', '112,000'],
        ['2', 'Faisal', 'ALFALAH', '129,600', '5,000', '—', '134,600'],
        ['3', 'Old\nArchived', 'HBL', '5,000', '—', '5,000', '0'],
      ],
    );
    expect(
      [
        for (final row in accounts.foot) [for (final c in row) c.text],
      ],
      [
        ['Cash', '111,000', '1,000', '0', '112,000'],
        ['Total bank', '134,600', '5,000', '5,000', '134,600'],
        ['Total (Cash + Bank)', '245,600', '6,000', '5,000', '246,600'],
      ],
    );
    expect(accounts.foot.first.first.span, 3);
    // Not a Roznamcha day: no Compact switch.
    expect(report.roznamchaSheets, isNull);

    // Yesterday: Old still held its 5,000, and both totals count it.
    final before = moneyReport(app, yesterday);
    expect(table(before).skip(3), [
      ['Cash', '', '0', '111,000', '0', '111,000'],
      ['Total bank', '', '0', '134,600', '0', '134,600'],
      ['Total (Cash + Bank)', '', '0', '245,600', '0', '245,600'],
    ]);
    expect(app.bookAt(yesterday).bankMoney, 13460000);

    // Tomorrow Old is archived, empty and unmoved: left out.
    final tomorrow = DateTime.parse(
      today,
    ).add(const Duration(days: 1)).toIso8601String().substring(0, 10);
    expect(table(moneyReport(app, tomorrow)).map((r) => r.first), [
      'Cash',
      'Faisal',
      'Cash',
      'Total bank',
      'Total (Cash + Bank)',
    ]);

    // Urdu headings.
    final urdu = moneyReport(app, today, urdu: true);
    expect(urdu.title, 'نقد اور بینک کی تفصیل');
    expect(urdu.rows.last.first.text, 'کل (نقد + بینک)');
    expect(urdu.sheets.single.summary.head[1].text, 'کل بینک');
    app.dispose();
    await db.close();
  });

  testWidgets('Money statement PDF: one page, English and Urdu', (
    tester,
  ) async {
    for (final (family, asset) in [
      ('Manrope', 'assets/fonts/Manrope.ttf'),
      ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    // Latin beside Urdu is drawn in Arial (Manrope where it is missing);
    // test mode draws squares for a font it has not loaded.
    final arial = [
      for (final name in ['arial.ttf', 'arialbd.ttf'])
        File('C:/Windows/Fonts/$name'),
    ].where((f) => f.existsSync());
    final loader = FontLoader('Arial');
    for (final file in arial) {
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
    }
    if (arial.isEmpty) {
      loader.addFont(rootBundle.load('assets/fonts/Manrope.ttf'));
    }
    await loader.load();
    int pagesOf(List<int> bytes) =>
        RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length;
    await tester.runAsync(() async {
      final (app, db, today) = await statementDays();
      // An Urdu account name too.
      await app.saveMaster('account', {
        'name': 'لقمان احمد',
        'bank': 'HBL',
      }, opening: 17693900);
      for (final (urdu, file) in [
        (false, 'preview-money-statement.pdf'),
        (true, 'preview-money-statement-urdu.pdf'),
      ]) {
        final bytes = await ReportExporter().pdf(
          moneyReport(app, today, urdu: urdu),
        );
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        await File('build/$file').writeAsBytes(bytes);
        expect(pagesOf(bytes), 1);
      }
      app.dispose();
      await db.close();
    });
  });
}
