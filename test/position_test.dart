// "What we have" (asked for by the user on 21 November 2026): the profit
// sections' Detailed view adds cash, banks, what parties owe and are owed,
// stock, cylinder deposits and hospitality (paid outside the app, so it comes
// off) into what the business has at the end of a day, and shows how the
// profit of the period became the change since the day before. Cylinders
// are counted, never valued.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/position.dart';
import 'package:zubair_khata_management/features/ledger/profit.dart';
import 'package:zubair_khata_management/features/reports/daily_report.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/profit_ui.dart';

const day = '2026-11-02', before = '2026-11-01', after = '2026-11-03';

Future<AppController> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  addTearDown(app.close);
  app.setDate(day);
  for (final name in ['JU Gas', 'Ali', 'Sadiq']) {
    await app.saveMaster('party', {'name': name});
  }
  return app;
}

String id(AppController app, String name) => app.partyByName(name)!.id;

/// [count] 11.8 kg cylinders to Ali at Rs 5,770, [cash] paid.
Json sale(
  AppController app,
  int count, {
  String date = day,
  int t = 1,
  int cash = 0,
}) => {
  'type': 'sale',
  'date': date,
  'occurredAt': t,
  'party': id(app, 'Ali'),
  'quantities': {'11800': count},
  'customerOwned': true,
  'rate': 577000,
  if (cash != 0) 'cash': cash,
};

/// From JU Gas at Rs 5,720 per 11.8 kg, [paid] from cash.
Json purchase(
  AppController app,
  int grams, {
  String date = day,
  int t = 0,
  int paid = 0,
}) => {
  'type': 'purchase',
  'date': date,
  'occurredAt': t,
  'party': id(app, 'JU Gas'),
  'grams': grams,
  'rate': 572000,
  'rateUnit': 11800,
  'account': 'cash',
  if (paid != 0) 'amount': paid,
};

/// The change of [from] to [to] adds up: what we had, the profit and what
/// is entered without being profit give what we have, with nothing left.
void expectAddsUp(AppController app, String from, String to) {
  final c = app.positionChange(from, to);
  expect(
    c.start.total + c.profit.net + c.entered + c.shares - c.historical,
    c.end.total,
    reason: '$from to $to',
  );
  expect(c.other, 0, reason: '$from to $to');
}

Record doc(String id, String type, Json data, {String date = day, int t = 1}) =>
    Record(id, 'document', {
      'type': type,
      'date': date,
      'occurredAt': t,
      ...data,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'What we have adds money, what parties owe, stock and deposits, less '
    'what the business owes and the hospitality paid outside the app',
    () async {
      final app = await start();
      app.setDate(before);
      await app.saveMaster('account', {
        'name': 'HBL',
        'bank': 'HBL',
        'bankAccount': '1234',
      });
      final hbl = app.ofKind('account').firstWhere((r) => r.name == 'HBL').id;
      for (final (target, amount) in [
        ('money:cash', 10000000),
        ('money:$hbl', 5000000),
      ]) {
        await app.post({
          'type': 'adjustment',
          'date': before,
          'target': target,
          'amount': amount,
          'note': 'Opening',
          'occurredAt': 0,
        });
      }
      app.setDate(day);
      // 10 cylinders' gas from JU for Rs 57,200, Rs 20,000 of it paid.
      await app.post(purchase(app, 118000, paid: 2000000));
      // 4 cylinders to Ali for Rs 23,080, Rs 10,000 in cash.
      await app.post(sale(app, 4, cash: 1000000));
      await app.post({
        'type': 'expense',
        'date': day,
        'occurredAt': 3,
        'category': 'Office',
        'amount': 50000,
        'account': 'cash',
      });
      await app.post({
        'type': 'deposit',
        'date': day,
        'occurredAt': 4,
        'party': id(app, 'Ali'),
        'amount': 300000,
        'account': 'cash',
      });

      final p = app.position(day);
      expect(p.cash, 10000000 - 2000000 + 1000000 - 50000 + 300000);
      expect(p.cash, app.book.money('cash'));
      expect(p.bank, 5000000);
      expect(p.banks, {hbl: 5000000});
      expect(p.receive, 2308000 - 1000000);
      expect(p.receivers, [(id(app, 'Ali'), 1308000)]);
      expect(p.pay, 5720000 - 2000000);
      expect(p.payees, [(id(app, 'JU Gas'), 3720000)]);
      // 70.8 kg left of the 118 kg, at its share of the bill.
      expect(p.stockGrams, 70800);
      expect(p.stockValue, 5720000 - 2288000);
      expect(p.deposits, 300000);
      expect(p.depositParties, 1);
      // Rs 1,200 per ton on the 47.2 kg sold.
      expect(p.hospitality, 5664);
      expect(p.owedGrams, 0);
      expect(
        p.total,
        9250000 + 5000000 + 1308000 + 3432000 - 3720000 - 300000 - 5664,
      );

      // The day: what we had the evening before, plus the day's profit.
      final c = app.positionChange(day, day);
      expect(c.start.date, before);
      expect(c.start.total, 15000000);
      expect(c.profit.net, 2308000 - 2288000 - 5664 - 50000);
      expect(c.entered, 0);
      expectAddsUp(app, day, day);
      // Everything: from nothing, the opening balances are entered, not
      // earned.
      final all = app.positionChange('2000-01-01', day);
      expect(all.start.empty, isTrue);
      expect(all.start.total, 0);
      expect(all.entered, 15000000);
      expectAddsUp(app, '2000-01-01', day);
      expectAddsUp(app, '2026-11-01', day);

      // The lines say what each figure is and why it is added or taken off.
      final (lines, notes) = whatWeHaveLines(
        p,
        app.profitSettings,
        const Words(false),
        rs: (v) => 'Rs ${money(v)}',
        name: app.name,
        date: (d) => d,
      );
      String detail(String label) =>
          lines.firstWhere((l) => l.label.endsWith(label)).detail!;
      expect(detail('Cash in hand'), 'Closing of the Roznamcha on $day');
      expect(detail('Banks'), 'HBL Rs 50,000');
      expect(detail('You will receive'), contains('Ali Rs 13,080'));
      expect(detail('You will pay'), contains('JU Gas Rs 37,200'));
      expect(detail('Gas stock'), startsWith('70.8 KG in stock'));
      expect(detail('Hospitality'), startsWith('0.047 ton × Rs 1,200 per ton'));
      expect(lines.last.label, '= What we have');
      expect(lines.last.amount, p.total);
      expect(notes, isEmpty);
      final bridge = whyLines(c, const Words(false), date: (d) => d);
      expect(bridge.first.label, 'What we had at the end of $before');
      expect(bridge.map((l) => l.amount), [15000000, c.profit.net, p.total]);
      expect(bridge.last.label, '= What we have at the end of $day');
    },
  );

  test('Gas sold before its purchase comes off at the price entered, then at '
      'the cost its purchase brought', () async {
    final app = await start();
    await app.post(sale(app, 3));
    var p = app.position(day);
    expect(p.receive, 1731000);
    expect(p.owedGrams, 35400);
    expect(p.owedUnpriced, 35400);
    expect(p.owedValue, 0);
    expectAddsUp(app, day, day);

    await app.saveProfitSettings(
      app.profitSettings.withPrices(
        waiting: const GasPrice(560000, 11800, setOn: day),
      ),
    );
    p = app.position(day);
    expect(p.owedUnpriced, 0);
    expect(p.owedWaiting, 35400);
    expect(p.owedValue, 1680000);
    expect(p.total, 1731000 - 1680000 - 4248);
    expect(app.profit(day, day).net, p.total);
    expectAddsUp(app, day, day);

    // The purchase comes the next day: the day's gas now has its real cost.
    await app.post(purchase(app, 118000, date: after));
    p = app.position(day);
    expect(p.owedWaiting, 0);
    expect(p.owedValue, 1716000);
    expect(p.total, 1731000 - 1716000 - 4248);
    expectAddsUp(app, day, day);
    final next = app.position(after);
    expect(next.owedGrams, 0);
    expect(next.pay, 5720000);
    expect(next.stockValue, 5720000 - 1716000);
    // Buying gas on credit changes nothing in what we have.
    expect(next.total, p.total);
    expectAddsUp(app, after, after);
    expectAddsUp(app, day, after);
  });

  test('A purchase share entered before its purchase comes off until the '
      'purchase, and its charge against its cost is its own line', () async {
    final app = await start();
    await app.post(purchase(app, 1180000, date: after, t: 9));
    final ju = app.book.documents.firstWhere(
      (d) => d.type == EntryType.purchase,
    );
    await app.post({
      'type': 'sale',
      'date': day,
      'occurredAt': 5,
      'party': id(app, 'Sadiq'),
      'quantities': <String, int>{},
      'extraGrams': 145000,
      'bulkAtCost': true,
      'sharePurchase': ju.reference,
    });
    final share = app.book.documents.firstWhere((d) => d.bulkAtCost);
    final p = app.position(day);
    expect(p.receive, share.shareCharge);
    expect(p.owedGrams, 145000);
    // Its gas comes from the purchase of the next day, at that bill.
    expect(p.owedValue, app.book.shareCosts[share.id]);
    expectAddsUp(app, day, day);
    expectAddsUp(app, after, after);
    expectAddsUp(app, day, after);
    expect(
      app.positionChange(day, day).shares,
      share.shareCharge - p.owedValue,
    );
  });

  test('Stock entered without a cost counts at its price, which is entered, '
      'not earned', () async {
    final app = await start();
    await app.post({
      'type': 'stockAdjustment',
      'date': day,
      'occurredAt': 0,
      'grams': 23600,
      'costKnown': false,
      'note': 'opening gas',
    });
    var p = app.position(day);
    expect(p.noCostGrams, 23600);
    expect(p.noCostValue, isNull);
    expect(p.stockGrams, 0);
    expectAddsUp(app, day, day);
    await app.saveProfitSettings(
      app.profitSettings.withPrices(noCost: const GasPrice(590000, 11800)),
    );
    p = app.position(day);
    expect(p.noCostValue, 1180000);
    expect(app.positionChange(day, day).entered, 1180000);
    expectAddsUp(app, day, day);

    await app.post(sale(app, 1, date: after));
    p = app.position(after);
    expect(p.noCostGrams, 11800);
    expect(p.noCostValue, 590000);
    expect(app.profit(after, after).noCostCost, 590000);
    expectAddsUp(app, after, after);
    expectAddsUp(app, day, after);
  });

  test('Historical summaries and customer cylinders', () {
    final records = [
      doc('ju', 'purchase', {
        'party': 'ju',
        'grams': 118000,
        'rate': 572000,
        'rateUnit': 11800,
      }, date: before),
      doc('h', 'historicalSale', {'grams': 11800, 'amount': 600000}),
      doc('s', 'sale', {
        'party': 'ali',
        'quantities': {'11800': 2},
        'returned': {'11800': 0},
        'rate': 577000,
      }, t: 2),
    ];
    final all = Book(records);
    Position at(String date) => positionAt(
      Book(records, throughDate: date),
      all,
      const ProfitSettings(),
      profitOf(all, const ProfitSettings(), '2000-01-01', date),
      date,
    );
    final start = at(before), end = at(day);
    final c = positionChangeOf(
      start: start,
      end: end,
      startBook: Book(records, throughDate: before),
      endBook: Book(records, throughDate: day),
      all: all,
      settings: const ProfitSettings(),
      profit: profitOf(all, const ProfitSettings(), day, day),
      from: day,
      to: day,
    );
    expect(c.historical, 600000);
    expect(c.other, 0);
    // Two of our cylinders went with Ali: counted, never valued.
    expect(end.held, {11800: 2});
    final (_, notes) = whatWeHaveLines(
      end,
      const ProfitSettings(),
      const Words(false),
      rs: (v) => money(v),
      name: (id) => id,
      date: (d) => d,
    );
    expect(notes, [
      'Cylinders with customers: 11.8 KG: 2. They are counted, not valued in money.',
    ]);
  });

  test('Banks and parties are listed biggest first, whatever the order of '
      'their entries', () {
    final records = [
      for (final (id, target, amount) in [
        ('a', 'money:small', 100000),
        ('b', 'money:big', 900000),
        ('c', 'money:empty', 0),
        ('d', 'ar:ali', 200000),
        ('e', 'ar:bilal', 700000),
      ])
        doc(id, 'adjustment', {
          'target': target,
          'amount': amount,
          'note': 'Opening',
        }, t: 0),
    ];
    final book = Book(records);
    final p = positionAt(
      book,
      book,
      const ProfitSettings(),
      profitOf(book, const ProfitSettings(), '2000-01-01', day),
      day,
    );
    expect(p.banks.keys, ['big', 'small']);
    expect(p.receivers.map((r) => r.$1), ['bilal', 'ali']);
    final (lines, _) = whatWeHaveLines(
      p,
      const ProfitSettings(),
      const Words(false),
      rs: money,
      name: (id) => id,
      date: (d) => d,
    );
    expect(lines[1].detail, 'big 9,000 · small 1,000');
  });

  test('Every line is translated', () async {
    final app = await start();
    await app.post(sale(app, 3));
    await app.post({
      'type': 'stockAdjustment',
      'date': day,
      'occurredAt': 0,
      'grams': 11800,
      'costKnown': false,
      'note': 'found',
    });
    await app.post({
      'type': 'deposit',
      'date': day,
      'occurredAt': 4,
      'party': id(app, 'Ali'),
      'amount': 300000,
      'account': 'cash',
    });
    await app.post(purchase(app, 1180000, date: after, paid: 100000));
    final c = app.positionChange(day, after);
    const urdu = Words(true);
    String digits(int v) => '${v.abs()}';
    final (have, notes) = whatWeHaveLines(
      c.end,
      app.profitSettings,
      urdu,
      rs: digits,
      name: (_) => 'ن',
      date: (_) => '1',
    );
    final bridge = whyLines(c, urdu, date: (_) => '1');
    final latin = RegExp('[A-Za-z]');
    for (final text in [
      for (final l in [...have, ...bridge]) ...[l.label, ?l.detail],
      ...notes,
    ]) {
      // "KG" is how the app writes weights in both languages.
      expect(text.replaceAll('KG', ''), isNot(contains(latin)), reason: text);
    }
    for (final key in ['Simple', 'Detailed', 'Explanation']) {
      expect(Words.hasUrdu(key), isTrue, reason: key);
    }
  });

  test('The Profit report prints What we have and Why when Detailed', () async {
    final app = await start();
    await app.post(purchase(app, 118000, paid: 2000000));
    await app.post(sale(app, 4, cash: 1000000));
    final simple = buildReport(app, 'Profit report', day, day);
    expect(simple.sheetSwitch, 'Detailed');
    expect(simple.compact, isFalse);
    final tables = simple.sheets.single.tables.length;
    final detailed = buildReport(
      app,
      'Profit report',
      day,
      day,
      detailed: true,
    );
    expect(detailed.compact, isTrue);
    final sheet = detailed.sheets.single;
    // What changed, part by part was removed at the user's request.
    expect(sheet.tables.length, tables + 2);
    expect(sheet.tables.map((t) => t.title).skip(tables), [
      'What we have at the end of 02-11-2026',
      'Why: how profit became what we have',
    ]);
    expect(sheet.heading, contains('What we have: Rs. '));
    // The table, Excel and CSV keep the profit rows.
    expect(detailed.rows.length, simple.rows.length);
    // The preview's switch takes them off and puts them back.
    expect(detailed.withCompact(false).sheets.single.tables.length, tables);
    expect(simple.withCompact(true).sheets.single.tables.length, tables + 2);
    // The Reports page keeps its Compact switch.
    final page = buildReportView(app, 'Profit report', day, day);
    expect(page.sheetSwitch, 'Compact');
  });

  testWidgets('Simple or Detailed on the profit sections', (tester) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1440, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    await app.saveMaster('party', {'name': 'Ali'});
    final today = app.selectedDate;
    await app.post({
      'type': 'sale',
      'date': today,
      'occurredAt': 1,
      'party': app.partyByName('Ali')!.id,
      'quantities': {'11800': 3},
      'customerOwned': true,
      'rate': 577000,
    });
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();

    expect(app.profitDetailed, isFalse);
    expect(find.byKey(const ValueKey('position-have')), findsNothing);
    expect(
      find.text(
        'Detailed adds cash, banks, pendings and stock: how much we have, and why.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('profit-view-Detailed')));
    await tester.pumpAndSettle();
    expect(app.profitDetailed, isTrue);
    expect(find.byKey(const ValueKey('position-have')), findsOneWidget);
    expect(find.byKey(const ValueKey('position-why')), findsOneWidget);
    expect(find.text('= What we have'), findsOneWidget);
    expect(find.text('+ You will receive'), findsOneWidget);
    // Removed at the user's request (21 November 2026): they want to see
    // what they own, not each part's change.
    expect(find.text('What changed, part by part'), findsNothing);
    // The gas has no purchase yet: its price can be entered right there.
    expect(find.text('− Gas sold before its purchase'), findsOneWidget);
    expect(find.byKey(const ValueKey('position-price-0')), findsOneWidget);
    // The Profit report follows the choice.
    final report = tester.widget<ReportButton>(
      find.byKey(const ValueKey('roz-profit-report')),
    );
    expect(report.kind, 'Profit report');

    // The Stock page shares the choice.
    app.go('stock');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('position-have')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profit-view-Simple')));
    await tester.pumpAndSettle();
    expect(app.profitDetailed, isFalse);
    expect(find.byKey(const ValueKey('position-have')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });
}
