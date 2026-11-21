import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/roznamcha_widgets.dart'
    show nextDate;

Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

/// The day the Roznamcha page shows for [date] (`_page()`), built the
/// page's way: the opening is the closing cash less the day's movement.
RoznamchaDay pageDay(AppController app, String date) {
  final book = app.bookAt(date);
  final closing = book.money('cash');
  return RoznamchaDay(
    date,
    closing - book.dayMovement(date, 'money:cash'),
    book.documents.where((d) => d.date == date),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Daily roznamcha starts each day with the page overview', () async {
    final (app, db) = await start();
    final d3 = businessDate(), d2 = nextDate(d3, -1), d1 = nextDate(d3, -2);
    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    await app.saveMaster('party', {'name': 'Ali Traders'});
    await app.saveMaster('party', {
      'name': 'PSO',
      'customer': false,
      'supplier': true,
    });
    final ali = app.partyByName('Ali Traders')!.id;
    final pso = app.partyByName('PSO')!.id;
    Future<void> post(String date, Map<String, dynamic> data) =>
        app.post({'date': date, ...data});

    // Day 1: starting cash, gas in (stock + purchase), a sale with bulk KG.
    await post(d1, {
      'type': 'adjustment',
      'target': 'money:cash',
      'amount': 5000000,
      'note': 'Opening',
      'occurredAt': 0,
      'form': 'opening',
    });
    await post(d1, {
      'type': 'stockAdjustment',
      'grams': 100000,
      'note': 'Opening stock',
    });
    await post(d1, {
      'type': 'purchase',
      'party': pso,
      'grams': 200000,
      'rate': 30000,
      'rateUnit': 1000,
    });
    await post(d1, {
      'type': 'sale',
      'party': ali,
      'quantities': {'11800': 3, '45000': 1},
      'returned': {'11800': 3, '45000': 1},
      'extraGrams': 5000,
      'rate': 464000,
      'cash': 1000000,
      'bank': 500000,
      'bankAccount': hbl,
      'form': 'aamad',
    });
    // Day 2: nikali, a cash sale, cash and bank kharcha, bank jama, a leak.
    await post(d2, {
      'type': 'transfer',
      'account': hbl,
      'toAccount': 'cash',
      'amount': 200000,
      'form': 'nikali',
    });
    await post(d2, {
      'type': 'sale',
      'party': ali,
      'quantities': {'15000': 2},
      'returned': {'15000': 2},
      'rate': 464000,
      'cash': 500000,
      'form': 'aamad',
    });
    await post(d2, {
      'type': 'expense',
      'account': 'cash',
      'amount': 50000,
      'category': 'General',
      'note': 'Chai',
      'form': 'kharcha',
    });
    await post(d2, {
      'type': 'expense',
      'account': hbl,
      'amount': 30000,
      'category': 'General',
      'note': 'Bank charges',
      'form': 'kharcha',
    });
    await post(d2, {
      'type': 'transfer',
      'account': 'cash',
      'toAccount': hbl,
      'amount': 100000,
      'form': 'bankJama',
    });
    await post(d2, {
      'type': 'stockAdjustment',
      'grams': -10000,
      'note': 'Leak',
    });
    // Day 3: a cash count correction and a kharcha; no gas moves.
    await post(d3, {
      'type': 'adjustment',
      'target': 'money:cash',
      'amount': 10000,
      'note': 'Cash count',
      'occurredAt': DateTime.now().millisecondsSinceEpoch,
      'form': 'opening',
    });
    await post(d3, {
      'type': 'expense',
      'account': 'cash',
      'amount': 20000,
      'category': 'General',
      'note': 'Rickshaw',
      'form': 'kharcha',
    });

    final report = buildReport(app, 'Daily roznamcha', d1, d3);
    List<List<Cell>> of(String date) =>
        report.rows.where((r) => r[0].text == date).toList();
    num? total(String date, String label) =>
        of(date).firstWhere((r) => r[2].text == label)[4].numeric;

    final gasText = {
      d1: 'Gas (KG) — Opening 0 + 300 − 85.4 = 214.6',
      d2: 'Gas (KG) — Opening 214.6 + 0 − 40 = 174.6',
      d3: 'Gas (KG) — Opening 174.6 + 0 − 0 = 174.6',
    };
    for (final date in [d1, d2, d3]) {
      final rows = of(date), day = pageDay(app, date);
      final labels = rows.map((r) => r[2].text).toList();
      // Overview first, in the page's order, then the A section.
      expect(labels[0], 'Overview');
      expect(labels[1], startsWith('Opening (sabiqa)'));
      expect(labels[2], startsWith('A: Aamad (Opening + Wasooli + Nikali) — '));
      expect(labels[3], startsWith('B: Kharcha + Bank Jama — '));
      expect(labels[4], startsWith('Closing = A − B (Cash in Hand) — '));
      expect(labels[5], startsWith('Total Sale — '));
      expect(labels[6], startsWith('Total Gas Dispatch (KG) — '));
      expect(labels[7], gasText[date]);
      expect(labels[8], 'A: Aamad / Wasooli');
      // The amounts are the page's, and agree with the totals below them.
      expect(rows[1][4].numeric, (day.opening + day.cashAdj) / 100);
      expect(rows[2][4].numeric, day.left / 100);
      expect(
        rows[2][4].numeric,
        total(date, 'Kul Aamad (Wasooli + Opening + Nikali)'),
      );
      expect(rows[3][4].numeric, day.rightTotal / 100);
      expect(rows[3][4].numeric, total(date, 'Kul Kharcha + Bank Jama'));
      expect(rows[4][4].numeric, app.bookAt(date).money('cash') / 100);
      expect(
        rows[4][4].numeric,
        total(date, 'Closing = A − B (Cash in Hand)'),
      );
      expect(rows[5][4].numeric, day.bill / 100);
      expect(
        rows[5][2].text,
        'Total Sale — Cylinder ${money(day.cylinderBill)} · '
        'Bulk ${money(day.bulkBill)}',
      );
      // The gas line closes on the book's stock for that day.
      expect(gasText[date], endsWith(kg(app.bookAt(date).gasGrams)));
      // Weights are never put in the rupee column.
      expect(rows[6][4].text, '');
      expect(rows[7][4].text, '');
      // Overview, A and B head their sections.
      final start = report.rows.indexOf(rows.first);
      expect(
        report.sections
            .where((i) => i >= start && i < start + rows.length)
            .map((i) => report.rows[i][2].text),
        ['Overview', 'A: Aamad / Wasooli', 'B: Kharcha'],
      );
    }
    expect(report.sections, hasLength(9));

    // Day 1: the starting cash alone, bank wasooli, bulk KG billed.
    final one = of(d1).map((r) => r[2].text).toList();
    expect(one[1], 'Opening (sabiqa)');
    expect(of(d1)[1][4].numeric, 50000);
    expect(
      one[2],
      'A: Aamad (Opening + Wasooli + Nikali) — '
      'Cash 10,000 · Bank 5,000 · Nikali 0',
    );
    expect(
      one[3],
      'B: Kharcha + Bank Jama — Kharcha (cash) 0 · Bank jama 5,000',
    );
    expect(
      one[6],
      'Total Gas Dispatch (KG) — 85.4 kg · 11.8 KG: 3 · 15 KG: 0 · 45 KG: 1 · Bulk 5 kg',
    );
    expect(pageDay(app, d1).bulkBill, greaterThan(0));
    // Day 2: nikali added to the opening, kharcha paid from the bank, and
    // the leak is gas out but not dispatch.
    final two = of(d2).map((r) => r[2].text).toList();
    expect(two[1], 'Opening (sabiqa) 60,000 + Bank se Nikali 2,000 = 62,000');
    expect(of(d2)[1][4].numeric, 60000);
    expect(
      two[3],
      'B: Kharcha + Bank Jama — '
      'Kharcha (cash) 500 · Bank jama 1,000 · Bank se diye 300',
    );
    expect(
      two[4],
      'Closing = A − B (Cash in Hand) — Cash: 65,500 · Bank (aaj): -1,300',
    );
    expect(
      two[6],
      'Total Gas Dispatch (KG) — 30 kg · 11.8 KG: 0 · 15 KG: 2 · 45 KG: 0',
    );
    // Day 3: a later cash correction is explained beside the opening.
    expect(
      of(d3)[1][2].text,
      'Opening (sabiqa) (pichla closing 65,500, Adjustment +100)',
    );
    expect(of(d3)[1][4].numeric, 65600);

    // One day printed alone (the page's Print / PDF) is the same as that
    // day inside a longer range.
    final single = buildReport(app, 'Daily roznamcha', d2, d2);
    expect(
      single.rows.map((r) => r.map((c) => c.text).toList()).toList(),
      of(d2).map((r) => r.map((c) => c.text).toList()).toList(),
    );
    expect(single.sections, hasLength(3));

    app.dispose();
    await db.close();
  });

  test('No gas line before any gas stock, as on the page', () async {
    final (app, db) = await start();
    final date = businessDate();
    await app.post({
      'date': date,
      'type': 'adjustment',
      'target': 'money:cash',
      'amount': 100000,
      'note': 'Opening',
      'occurredAt': 0,
      'form': 'opening',
    });
    final labels = buildReport(
      app,
      'Daily roznamcha',
      date,
      date,
    ).rows.map((r) => r[2].text).toList();
    expect(labels.any((l) => l.startsWith('Gas (KG)')), isFalse);
    expect(
      labels,
      contains(
        'Total Gas Dispatch (KG) — 0 kg · 11.8 KG: 0 · 15 KG: 0 · 45 KG: 0',
      ),
    );
    expect(labels[labels.indexOf('Overview') + 7], 'A: Aamad / Wasooli');
    app.dispose();
    await db.close();
  });

  testWidgets('The overview prints in English and Urdu PDFs', (tester) async {
    for (final (family, asset) in [
      ('Manrope', 'assets/fonts/Manrope.ttf'),
      ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final (app, db) = (await tester.runAsync(start))!;
    final date = app.selectedDate;
    await tester.runAsync(() async {
      await app.saveMaster('party', {'name': 'محسن عالم چوک'});
      final party = app.partyByName('محسن عالم چوک')!.id;
      await app.post({
        'date': date,
        'type': 'adjustment',
        'target': 'money:cash',
        'amount': 200773000,
        'note': 'Opening',
        'occurredAt': 0,
        'form': 'opening',
      });
      await app.post({
        'date': date,
        'type': 'stockAdjustment',
        'grams': 500000,
        'note': 'Opening stock',
      });
      await app.post({
        'date': date,
        'type': 'sale',
        'party': party,
        'quantities': {'11800': 4, '45000': 2},
        'rate': 464000,
        'cash': 3000000,
        'form': 'aamad',
      });
      await app.post({
        'date': date,
        'type': 'expense',
        'account': 'cash',
        'amount': 150000,
        'category': 'General',
        'note': 'Chai pani',
        'form': 'kharcha',
      });
      for (final urdu in [false, true]) {
        final report = buildReport(
          app,
          'Daily roznamcha',
          date,
          date,
          urdu: urdu,
        );
        expect(
          report.rows[report.sections.first][2].text,
          Words(urdu)('Overview'),
        );
        final bytes = await ReportExporter().pdf(report);
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        await File('build/preview-roznamcha-${urdu ? 'urdu' : 'english'}.pdf')
            .writeAsBytes(bytes);
      }
      app.dispose();
      await db.close();
    });
  });
}
