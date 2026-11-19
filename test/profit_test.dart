// Profit with what the khata does not know (asked for by the user on
// 19 November 2026): gas sold before its purchase (negative stock) or from
// stock entered without a cost counts at a purchase price the user enters,
// hospitality comes off every ton sold, and so do office and other kharcha.
// "How profit is calculated" shows it after Hisab Mel and on the Stock page.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/profit.dart';
import 'package:zubair_khata_management/features/reports/daily_report.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/profit_ui.dart';
import 'package:zubair_khata_management/ui/roznamcha_widgets.dart' show dmy, rs;
import 'package:zubair_khata_management/ui/settings_page.dart';

const day = '2026-11-02';

Record doc(String id, String type, Json data, {String date = day, int t = 1}) =>
    Record(id, 'document', {
      'type': type,
      'date': date,
      'occurredAt': t,
      ...data,
    });

Record cylinderSale(String id, int count, {String date = day, int t = 1}) =>
    doc(
      id,
      'sale',
      {
        'party': 'p',
        'quantities': {'11800': count},
        'customerOwned': true,
        'rate': 577000,
      },
      date: date,
      t: t,
    );

/// Rs 5,720 per 11.8 kg.
Record purchase(String id, int grams, {String date = day, int t = 0}) => doc(
  id,
  'purchase',
  {'party': 'ju', 'grams': grams, 'rate': 572000, 'rateUnit': 11800},
  date: date,
  t: t,
);

Future<AppController> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  addTearDown(app.close);
  app.setDate(day);
  await app.saveMaster('party', {'name': 'JU Gas'});
  await app.saveMaster('party', {'name': 'Ali'});
  return app;
}

String id(AppController app, String name) => app.partyByName(name)!.id;

/// [count] 11.8 kg cylinders to Ali at Rs 5,770.
Json sale(AppController app, int count, {int t = 1, String date = day}) => {
  'type': 'sale',
  'date': date,
  'occurredAt': t,
  'party': id(app, 'Ali'),
  'quantities': {'11800': count},
  'customerOwned': true,
  'rate': 577000,
};

/// From JU Gas at Rs 5,720 per 11.8 kg.
Json juPurchase(AppController app, int grams, {int t = 0, String date = day}) =>
    {
      'type': 'purchase',
      'date': date,
      'occurredAt': t,
      'party': id(app, 'JU Gas'),
      'grams': grams,
      'rate': 572000,
      'rateUnit': 11800,
      'account': 'cash',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Gas sold before its purchase counts at the price entered, until the '
      'purchase brings its real cost', () async {
    final app = await start();
    await app.post(sale(app, 3));
    var p = app.profit(day, day);
    expect(p.sales, 1731000);
    expect(p.cost, 0);
    expect(p.waitingGrams, 35400);
    expect(p.unpricedGrams, 35400);
    expect(p.complete, isFalse);
    expect(p.soldGrams, 35400);
    // 35.4 kg × Rs 1,200 per ton.
    expect(p.hospitality, 4248);
    expect(p.net, 1731000 - 4248);
    expect(app.book.warnings, contains('Profit is incomplete'));
    expect(profitPriced(app.book, app.profitSettings), isFalse);

    await app.saveProfitSettings(
      app.profitSettings.withPrices(
        waiting: const GasPrice(560000, 11800, setOn: day),
      ),
    );
    p = app.profit(day, day);
    // 35.4 kg at Rs 5,600 per 11.8 kg.
    expect(p.waitingCost, 1680000);
    expect(p.unpricedGrams, 0);
    expect(p.complete, isTrue);
    expect(p.gross, 51000);
    expect(p.net, 51000 - 4248);
    expect(profitPriced(app.book, app.profitSettings), isTrue);
    // Nothing in the khata changed for it.
    expect(app.book.uncostedSales.values.single, 35400);
    expect(app.book.balance('cogs'), 0);
    expect(app.book.gasGrams, -35400);

    // The purchase comes the next day: its cost replaces the price.
    await app.post(juPurchase(app, 1180000, date: '2026-11-03'));
    p = app.profit(day, day);
    expect(p.waitingGrams, 0);
    expect(p.estimated, 0);
    expect(p.cost, 1716000);
    expect(p.net, 1731000 - 1716000 - 4248);
    expect(profitPriced(app.book, app.profitSettings), isFalse);
    // The price stays for the next time the stock goes negative.
    expect(app.profitSettings.waiting?.rate, 560000);
  });

  test(
    'Gas sold from stock entered without a cost has a price of its own',
    () async {
      final app = await start();
      await app.post({
        'type': 'stockAdjustment',
        'date': day,
        'occurredAt': 0,
        'grams': 23600,
        'costKnown': false,
        'note': 'opening gas',
      });
      await app.post(sale(app, 3));
      final opening = app.book.documents.first, sold = app.book.documents.last;
      // 23.6 kg came from the opening gas; 11.8 kg wait for a purchase.
      expect(app.book.uncostedSources[sold.id], {opening.id: 23600, '': 11800});
      final (waiting, lots) = gasWithoutCost(app.book);
      expect(waiting, 11800);
      expect(lots, {opening.id: 23600});
      var p = app.profit(day, day);
      expect(p.noCostGrams, 23600);
      expect(p.waitingGrams, 11800);
      expect(p.unpricedGrams, 35400);

      await app.saveProfitSettings(
        app.profitSettings.withPrices(noCost: const GasPrice(590000, 11800)),
      );
      p = app.profit(day, day);
      expect(p.noCostCost, 1180000);
      // The negative stock still has no price.
      expect(p.unpricedGrams, 11800);
      expect(profitPriced(app.book, app.profitSettings), isFalse);

      await app.saveProfitSettings(
        app.profitSettings.withPrices(
          waiting: const GasPrice(47500, 1000),
          noCost: app.profitSettings.noCost,
        ),
      );
      p = app.profit(day, day);
      // Rs 475 per KG.
      expect(p.waitingCost, 560500);
      expect(p.estimated, 1180000 + 560500);
      expect(p.complete, isTrue);
      expect(profitPriced(app.book, app.profitSettings), isTrue);
    },
  );

  test('Gas that waited and then came from stock of unknown cost is priced as '
      'that stock', () {
    final book = Book([
      cylinderSale('s', 2),
      doc('found', 'stockAdjustment', {
        'grams': 100000,
        'costKnown': false,
        'note': 'found',
      }, t: 5),
    ]);
    expect(book.uncostedSources, {
      's': {'found': 23600},
    });
    expect(book.shortageGrams, 0);
    // A purchase share waiting for stock is never among them.
    final shared = Book([
      doc('share', 'sale', {
        'party': 'p',
        'quantities': <String, int>{},
        'extraGrams': 5000,
        'bulkAtCost': true,
        'bulkCost': 0,
      }),
    ]);
    expect(shared.uncostedShares, {'share': 5000});
    expect(shared.uncostedSources, isEmpty);
  });

  test('Hospitality is on gas sold, at the rate of its day, less gas returned '
      'and never on purchase shares', () {
    final book = Book([
      purchase('ju', 1180000, date: '2026-11-01'),
      cylinderSale('a', 10),
      doc('share', 'sale', {
        'party': 'p',
        'quantities': <String, int>{},
        'extraGrams': 50000,
        'bulkAtCost': true,
        'bulkCost': 0,
      }, t: 2),
      doc('bulk', 'sale', {
        'party': 'p',
        'quantities': <String, int>{},
        'extraGrams': 20000,
        'rate': 577000,
      }, date: '2026-11-03'),
      doc(
        'cn',
        'creditNote',
        {
          'party': 'p',
          'sourceInvoice': 'a',
          'stockReturned': true,
          'quantities': {'11800': 10},
          'rate': 577000,
          'note': 'came back',
        },
        date: '2026-11-03',
        t: 2,
      ),
    ]);
    final settings = const ProfitSettings().withHospitality(
      150000,
      '2026-11-03',
    );
    expect(settings.hospitality, [('', 120000), ('2026-11-03', 150000)]);
    expect(settings.hospitalityOn('2026-11-02'), 120000);
    expect(settings.hospitalityOn('2026-11-03'), 150000);
    expect(settings.hospitalityOn('2026-12-31'), 150000);
    final days = profitByDay(book, settings, '2026-11-01', '2026-11-03');
    expect(days['2026-11-02']!.soldGrams, 118000);
    // 118 kg × Rs 1,200 per ton.
    expect(days['2026-11-02']!.hospitality, 14160);
    expect(days['2026-11-02']!.sharedGrams, 50000);
    // 20 kg sold, 118 kg back, at Rs 1,500 per ton.
    expect(days['2026-11-03']!.soldGrams, -98000);
    expect(days['2026-11-03']!.hospitality, -14700);
    final total = profitOf(book, settings, '2026-11-01', '2026-11-03');
    expect(total.hospitality, 14160 - 14700);
    expect(total.hospitalityRates, {120000, 150000});
    // The returned invoice's sale and cost are taken back too.
    expect(days['2026-11-03']!.cylinderSales, -5770000);
    final bulkCost = book.allocations
        .where((a) => a.sale == 'bulk')
        .fold(0, (v, a) => v + a.cost);
    expect(days['2026-11-03']!.cost, bulkCost - 5720000);
    // One rate for every day replaces the schedule; the same rate again
    // changes nothing.
    expect(settings.withHospitality(100000, '').hospitality, [('', 100000)]);
    expect(settings.withHospitality(120000, '2026-11-10').hospitality, [
      ('', 120000),
      ('2026-11-03', 150000),
      ('2026-11-10', 120000),
    ]);
    expect(
      const ProfitSettings().withHospitality(120000, '2026-11-10').hospitality,
      [('', 120000)],
    );
  });

  test('Office kharcha and every other kharcha come off the profit', () async {
    final app = await start();
    await app.post(juPurchase(app, 1180000));
    await app.post(sale(app, 10));
    await app.post({
      'type': 'expense',
      'date': day,
      'amount': 200000,
      'account': 'cash',
      'category': 'Office',
      'note': 'Roti',
      'form': 'office',
    });
    await app.post({
      'type': 'expense',
      'date': day,
      'amount': 50000,
      'account': 'cash',
      'category': 'General',
      'note': 'Labour',
    });
    await app.post({
      'type': 'discount',
      'date': day,
      'party': id(app, 'Ali'),
      'amount': 10000,
    });
    final p = app.profit(day, day);
    expect(p.sales, 5770000);
    expect(p.cost, 5720000);
    expect(p.gross, 50000);
    expect(p.hospitality, 14160);
    expect(p.office, 200000);
    expect(p.expenses, {'General': 50000, 'Write-off': 10000});
    expect(p.net, 50000 - 14160 - 200000 - 60000);
    final report = buildReport(app, 'Profit report', day, day);
    num? row(String label) =>
        report.rows.firstWhere((r) => r[0].text.startsWith(label))[1].numeric;
    expect(row('Cost of gas sold'), 57200);
    expect(row('Gross profit'), 500);
    expect(row('Hospitality'), 141.6);
    expect(
      report.rows.any((r) => r[0].text.contains('0.118 ton × Rs. 1,200')),
      isTrue,
    );
    expect(row('Office kharcha'), 2000);
    expect(row('Cash kharcha'), 500);
    expect(row('Less / discount'), 100);
    expect(row('Net profit'), p.net / 100);
    expect(report.notes, isEmpty);
    final urdu = buildReport(app, 'Profit report', day, day, urdu: true);
    expect(urdu.rows.first.first.text, Words(true)('Cylinder billing'));
  });

  test('The daily view of the Profit report adds up to the range', () async {
    final app = await start();
    await app.saveProfitSettings(
      app.profitSettings.withPrices(waiting: const GasPrice(560000, 11800)),
    );
    await app.post(juPurchase(app, 11800, date: '2026-11-01'));
    await app.post(sale(app, 2, date: '2026-11-01'));
    await app.post(sale(app, 3));
    await app.post({
      'type': 'expense',
      'date': day,
      'amount': 37000,
      'account': 'cash',
      'category': 'Office',
      'note': 'Tea',
    });
    final detailed = buildReport(app, 'Profit report', '2026-11-01', day);
    final daily = buildReportView(
      app,
      'Profit report',
      '2026-11-01',
      day,
      compact: true,
    );
    expect(daily.columns.last, 'Net profit');
    expect(daily.rows, hasLength(3));
    final net = detailed.rows.firstWhere((r) => r[0].text == 'Net profit');
    expect(daily.rows.last.last.numeric, net[1].numeric);
    final total = app.profit('2026-11-01', day);
    expect(
      net[1].numeric,
      (app.profit('2026-11-01', '2026-11-01').net + app.profit(day, day).net) /
          100,
    );
    expect(total.waitingGrams, 4 * 11800);
    expect(
      detailed.rows.any((r) => r[0].text.startsWith('Negative stock')),
      isTrue,
    );
  });

  test('Profit settings live on the business profile: a backup keeps them and '
      'Reset all data erases them', () async {
    final app = await start();
    await app.saveProfitSettings(
      const ProfitSettings()
          .withHospitality(150000, '')
          .withPrices(waiting: const GasPrice(560000, 11800, setOn: day)),
    );
    expect(app.settings['profit'], isA<Map>());
    expect(app.settings['name'], AppController.defaultBusinessName);
    await app.reload();
    expect(app.profitSettings.hospitality, [('', 150000)]);
    expect(app.profitSettings.waiting!.rate, 560000);
    expect(app.profitSettings.waiting!.setOn, day);
    final copy = await app.backup();
    await app.resetAll();
    expect(app.settings['profit'], isNull);
    expect(app.profitSettings.hospitality, [
      ('', ProfitSettings.defaultHospitality),
    ]);
    expect(app.profitSettings.waiting, isNull);
    await app.restoreBackup(copy);
    expect(app.profitSettings.waiting!.rate, 560000);
    expect(app.profitSettings.hospitality, [('', 150000)]);
  });

  test('Damaged profit settings read as the defaults', () {
    expect(ProfitSettings.of({}).hospitality, [('', 120000)]);
    expect(ProfitSettings.of({'profit': 'x'}).waiting, isNull);
    final s = ProfitSettings.of({
      'profit': {
        'hospitality': [
          {'from': 'bad', 'rate': 1},
          {'from': '2026-11-03', 'rate': -5},
          {'from': '2026-11-04', 'rate': 130000},
          'x',
        ],
        'waiting': {'rate': 0, 'unit': 11800},
        'noCost': {'rate': 1, 'unit': 7},
      },
    });
    expect(s.hospitality, [('', 120000), ('2026-11-04', 130000)]);
    expect(s.waiting, isNull);
    expect(s.noCost, isNull);
    expect(s.toJson().containsKey('waiting'), isFalse);
  });

  test('Profit labels have Urdu translations', () {
    final missing = <String>{};
    final pattern = RegExp(r"\bt\('([^'\$\r\n]+)'\)");
    final reports = File('lib/features/reports/reports.dart')
        .readAsStringSync();
    final start = reports.indexOf("case 'Profit report':");
    final sources = [
      File('lib/ui/profit_ui.dart').readAsStringSync(),
      reports.substring(start, reports.indexOf("case 'Cylinder custody':")),
    ];
    for (final source in sources) {
      for (final match in pattern.allMatches(source)) {
        if (!Words.hasUrdu(match.group(1)!)) missing.add(match.group(1)!);
      }
    }
    for (final key in [
      'How profit is calculated',
      'Sale − gas ki khareed − hospitality − kharcha = munafa.',
      'Profit uses your purchase price',
      'Gas at your price',
      'Other kharcha',
      for (final category in ['General', 'Write-off', 'Stock loss'])
        expenseLabel(category),
      for (final unit in GasPrice.units) priceUnit(unit),
      for (final period in ProfitPeriod.values) period.label,
    ]) {
      if (!Words.hasUrdu(key)) missing.add(key);
    }
    expect(missing, isEmpty);
  });

  testWidgets('The stock warning offers the purchase price, and the day\'s '
      'profit, hospitality and the business profile follow it', (tester) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1440, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    await app.saveMaster('party', {'name': 'Ali'});
    await app.post({...sale(app, 3, date: app.selectedDate), 'occurredAt': 1});
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    Future<void> settle() async {
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const ValueKey('roz-profit')), findsOneWidget);
    // Report buttons (asked for by the user on 19 November 2026): Hisab Mel
    // opens the day's Cash book, the profit section the day's Profit report.
    for (final (key, kind) in [
      ('roz-safi-report', 'Cash book'),
      ('roz-profit-report', 'Profit report'),
    ]) {
      final button = find.byKey(ValueKey(key));
      expect(button, findsOneWidget);
      expect((tester.widget(button) as ReportButton).kind, kind);
      expect(
        find.descendant(of: button, matching: find.text('Report')),
        findsOneWidget,
      );
    }
    expect(
      find.text('Negative gas stock · Profit is incomplete'),
      findsOneWidget,
    );
    expect(find.text('35.4 KG: purchase price not entered'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notice-purchase-price')));
    await tester.pumpAndSettle();
    expect(
      find.text('35.4 KG were sold before their purchase was entered.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('gas-price-waiting')),
      '5600',
    );
    await tester.pumpAndSettle();
    expect(find.text('= Rs 16,800 for 35.4 KG'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gas-price-save')));
    await settle();
    expect(app.profitSettings.waiting!.rate, 560000);
    expect(app.profitSettings.waiting!.unit, 11800);
    expect(app.profitSettings.waiting!.setOn, businessDate());
    expect(
      find.text('Negative gas stock · Profit uses your purchase price'),
      findsOneWidget,
    );
    final today = app.selectedDate;
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('roz-profit-net'))).data,
      rs(app.profit(today, today).net),
    );
    expect(
      find.textContaining('35.4 KG × Rs 5,600 per 11.8 KG'),
      findsOneWidget,
    );

    // Hospitality: the first change is for every day.
    await tester.tap(find.byKey(const ValueKey('profit-hospitality')));
    await tester.pumpAndSettle();
    expect(find.text('For every day'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('hospitality-rate')),
      '1500',
    );
    await tester.tap(find.byKey(const ValueKey('hospitality-save')));
    await settle();
    expect(app.profitSettings.hospitality, [('', 150000)]);
    expect(app.profit(today, today).hospitality, 5310);

    // Saving the business profile keeps the profit settings.
    unawaited(editProfile(tester.element(find.byType(Workspace)), app));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Save'),
      ),
    );
    await settle();
    expect(app.profitSettings.waiting!.rate, 560000);
    expect(app.profitSettings.hospitality, [('', 150000)]);

    // The Stock page: the same lines, for the day, the month or everything.
    app.go('stock');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-purchase-price')), findsOneWidget);
    expect(app.profitPeriod, ProfitPeriod.month);
    await tester.tap(find.byKey(const ValueKey('profit-period-day')));
    await tester.pumpAndSettle();
    expect(app.profitPeriod, ProfitPeriod.day);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('stock-profit-net'))).data,
      rs(app.profit(today, today).net),
    );
    final stockReport = tester.widget<ReportButton>(
      find.byKey(const ValueKey('stock-profit-report')),
    );
    expect(
      (stockReport.kind, stockReport.from, stockReport.to),
      ('Profit report', today, today),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });

  // Reported by the user on 19 November 2026: once the purchase had covered
  // the negative stock, the dialog still showed the negative-stock price.
  testWidgets('The purchase price dialog asks only for gas that has no cost '
      'now, and keeps a price it does not ask for', (tester) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1440, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> settle() async {
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    Future<AppController> open() async {
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      await app.saveMaster('party', {'name': 'JU Gas'});
      await app.saveMaster('party', {'name': 'Ali'});
      return app;
    }

    Future<void> close(AppController app) async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await app.db.close();
    }

    // Opening gas without a cost, a sale of more than it, a price for the
    // negative stock while it waits, then the purchase.
    var app = await open();
    final date = app.selectedDate;
    await app.post({
      'type': 'stockAdjustment',
      'date': date,
      'occurredAt': 0,
      'grams': 11800,
      'costKnown': false,
      'note': 'opening gas',
    });
    await app.post({...sale(app, 3, date: date), 'occurredAt': 1});
    await app.saveProfitSettings(
      app.profitSettings.withPrices(
        waiting: const GasPrice(560000, 11800, setOn: '2026-11-18'),
      ),
    );
    await app.post({...juPurchase(app, 1180000, date: date), 'occurredAt': 2});
    expect(app.book.gasGrams, greaterThan(0));
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    // Only the opening gas still has no cost.
    expect(find.text('Profit is incomplete'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notice-purchase-price')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gas-price-waiting')), findsNothing);
    expect(
      find.text('Negative stock (gas sold before its purchase)'),
      findsNothing,
    );
    expect(
      find.text(
        '11.8 KG were sold from stock entered without a cost: '
        'Stock adjustment "opening gas" · ${dmy(date)}',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('gas-price-noCost')),
      '5900',
    );
    await tester.tap(find.byKey(const ValueKey('gas-price-save')));
    await settle();
    expect(app.profitSettings.noCost!.rate, 590000);
    // The negative-stock price it did not ask for is kept for next time.
    expect(app.profitSettings.waiting!.rate, 560000);
    expect(find.text('Profit uses your purchase price'), findsOneWidget);
    expect(app.profit(date, date).complete, isTrue);
    await close(app);

    // Every KG sold has its cost: no button, and nothing to enter.
    app = await open();
    await app.post({...sale(app, 1, date: app.selectedDate), 'occurredAt': 1});
    await app.post({
      ...juPurchase(app, 1180000, date: app.selectedDate),
      'occurredAt': 2,
    });
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notice-purchase-price')), findsNothing);
    app.go('stock');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-purchase-price')), findsNothing);
    unawaited(editGasPrices(tester.element(find.byType(Workspace)), app));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'All gas sold has its purchase price now. There is nothing to enter.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('gas-price-save')), findsNothing);
    await tester.tap(find.text('Close'));
    await settle();
    await close(app);
  });
}
