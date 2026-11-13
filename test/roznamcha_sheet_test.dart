// The Roznamcha PDF is the original page's "Roznamcha History (Date wise)"
// print: the user's printed sheet of 25-10-2026 is rebuilt here cell by cell.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/l10n.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/features/reports/roznamcha_sheet.dart';

Future<(AppController, KhataDatabase)> start() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

/// Rupees to paisa.
int rs(int rupees) => rupees * 100;

List<String> heads(SheetTable t) => [for (final c in t.head) c.text];
List<List<String>> cells(List<List<SheetCell>> rows) => [
  for (final r in rows) [for (final c in r) c.text],
];

Future<String> account(AppController app, String name, String bank) async {
  await app.saveMaster('account', {'name': name, 'bank': bank});
  return app.ofKind('account').firstWhere((a) => a.name == name).id;
}

Future<String> party(
  AppController app,
  String name, {
  bool company = false,
}) async {
  await app.saveMaster('party', {
    'name': name,
    if (company) ...{'customer': false, 'supplier': true},
  });
  return app.partyByName(name)!.id;
}

const day = '2026-10-25';

/// The entries of the user's printed sheet of 25-10-2026, in their order,
/// on the opening it shows (the day before's closing).
Future<void> referenceDay(AppController app) async {
  final luqman = await account(app, 'LUQMAN HBL', 'HBL BANK');
  final abuSaad = await account(app, 'ABU SAAD Meezan', 'MEEZAN BANK');
  final qaisar = await account(app, 'QAISAR ABBAS Meezan', 'MEEZAN BANK');
  await app.post({
    'date': '2026-10-24',
    'type': 'adjustment',
    'target': 'money:cash',
    'amount': rs(2660690),
    'note': 'Opening',
    'occurredAt': 0,
    'form': 'opening',
  });
  var at = 1;
  for (final (name, amount, to) in [
    ('rana saleem', 73000, luqman),
    ('Umer Noshera road', 150000, abuSaad),
    ('mohsan al', 70000, qaisar),
  ]) {
    await app.post({
      'date': day,
      'occurredAt': at++,
      'type': 'receipt',
      'party': await party(app, name),
      'bank': rs(amount),
      'bankAccount': to,
      'form': 'aamad',
    });
  }
  await app.post({
    'date': day,
    'occurredAt': at++,
    'type': 'receipt',
    'party': await party(app, 'asmat baryar'),
    'cash': rs(260000),
    'form': 'aamad',
  });
  await app.post({
    'date': day,
    'occurredAt': at++,
    'type': 'expense',
    'account': 'cash',
    'amount': rs(10000),
    'category': 'General',
    'note': 'Zubair Ahmad Naqad',
    'form': 'kharcha',
  });
  await app.post({
    'date': day,
    'occurredAt': at++,
    'type': 'expense',
    'account': 'cash',
    'amount': rs(300),
    'category': 'Office',
    'note': 'Talha',
    'form': 'office',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('The PDF sheet is the old Roznamcha History print', () async {
    final (app, db) = await start();
    await referenceDay(app);
    app.setDate('2026-10-26');
    final snapshot = Record('saved', 'snapshot', {
      'date': day,
      'savedAt': '2026-10-26T10:20:21.000',
      'documents': [
        for (final d in app.book.documents.where((d) => d.date == day))
          d.record.toJson(),
      ],
    });
    final sheet = snapshotReport(app, snapshot).sheets.single;

    expect(sheet.title, 'Roznamcha History — Roznamcha History (Date wise)');
    expect(
      sheet.stamp,
      matches(
        RegExp(r'^Date: 26-10-2026 \| Print: \d\d/\d\d/\d{4}, \d\d:\d\d:\d\d$'),
      ),
    );
    expect(
      sheet.heading,
      '25-10-2026 Saved: 26/10/2026, 10:20:21 Safi Baqaya: Rs. 2,910,390',
    );

    expect(heads(sheet.summary), [
      'OPENING',
      'A: KUL AAMAD',
      'B: KHARCHA + BANK JAMA',
      'SAFI BAQAYA',
    ]);
    expect(cells(sheet.summary.body), [
      [
        'Rs. 2,660,690 Bank Nikali 0',
        'Rs. 3,213,690 Cash 260,000 | Bank 293,000',
        'Rs. 303,300 Kharcha 10,300 | Bank Jama 293,000',
        'Rs. 2,910,390 Bank Baqi 293,000',
      ],
    ]);
    // "Rs. X" in bold, its note in the smaller type.
    final opening = sheet.summary.body.single.first.lines.single;
    expect([opening.first.bold, opening.last.small], [true, true]);

    expect(sheet.tables.map((t) => t.title), [
      'A: Aamad / Wasooli',
      'B: Kharcha + Bank Jama',
    ]);
    final a = sheet.tables.first;
    expect(heads(a), [
      '#',
      'PARCHI',
      'CUSTOMER / PARTY',
      '11.8K',
      '15K',
      '45K',
      'RATE',
      'BILL',
      'CASH',
      'BANK / ACCOUNT',
      'KUL WASOOLI',
    ]);
    expect(cells(a.body), [
      [
        '1', '-', 'rana saleem', '—', '—', '—', '—', '—', '—', //
        '73,000 HBL BANK LUQMAN HBL', '73,000',
      ],
      [
        '2', '-', 'Umer Noshera road', '—', '—', '—', '—', '—', '—', //
        '150,000 MEEZAN BANK ABU SAAD Meezan', '150,000',
      ],
      [
        '3', '-', 'mohsan al', '—', '—', '—', '—', '—', '—', //
        '70,000 MEEZAN BANK QAISAR ABBAS Meezan', '70,000',
      ],
      [
        '4', '-', 'asmat baryar', '—', '—', '—', '—', '—', '260,000', //
        '—', '260,000',
      ],
    ]);
    expect(cells(a.foot), [
      ['Total', '0', '0', '0', '', '0', '260,000', '293,000', '553,000'],
    ]);
    expect(a.foot.single.first.span, 3);
    // Bold as printed: the customer, the bank badge and Kul Wasooli.
    final first = a.body.first;
    expect(first[2].lines.first.single.bold, isTrue);
    expect(first[9].lines.single[2].text, 'HBL BANK');
    expect(
      [first[9].lines.single[2].bold, first[9].lines.single[2].small],
      [true, true],
    );
    expect(first[10].lines.single.single.bold, isTrue);

    final b = sheet.tables.last;
    expect(heads(b), ['#', 'TYPE', 'BANK', 'PARTY', 'TAFSEEL', 'RAQAM']);
    expect(cells(b.body), [
      ['1', 'CASH KHARCHA', 'CASH', '—', 'Zubair Ahmad Naqad', '10,000'],
      ['2', 'OFFICE', 'CASH', '—', 'Talha', '300'],
      [
        '3', 'BANK JAMA', 'HBL BANK', 'LUQMAN HBL', //
        'Wasooli — rana saleem → LUQMAN HBL', '73,000',
      ],
      [
        '4', 'BANK JAMA', 'MEEZAN BANK', 'ABU SAAD Meezan', //
        'Wasooli — Umer Noshera road → ABU SAAD Meezan', '150,000',
      ],
      [
        '5', 'BANK JAMA', 'MEEZAN BANK', 'QAISAR ABBAS Meezan', //
        'Wasooli — mohsan al → QAISAR ABBAS Meezan', '70,000',
      ],
    ]);
    expect(cells(b.foot), [
      ['Kul Kharcha + Bank Jama', '303,300'],
    ]);
    expect(b.foot.single.first.span, 5);

    // Safi Baqaya is the ledger's cash in hand that day.
    expect(app.bookAt(day).money('cash'), rs(2910390));
    app.dispose();
    await db.close();
  });

  test('Entries the old page did not have are printed on their day', () async {
    final (app, db) = await start();
    const date = '2026-11-01';
    final hbl = await account(app, 'Zubair', 'HBL');
    final umer = await party(app, 'Umer');
    final supreme = await party(app, 'Supreme Petroleum', company: true);
    await app.post({
      'date': '2026-10-31',
      'type': 'adjustment',
      'target': 'money:cash',
      'amount': rs(100000),
      'note': 'Opening',
      'occurredAt': 0,
      'form': 'opening',
    });
    var at = 0;
    Future<void> post(Json data) =>
        app.post({'date': date, 'occurredAt': at++, ...data});
    await post({
      'type': 'adjustment',
      'party': umer,
      'target': 'ar:$umer',
      'amount': rs(1500),
      'note': 'Opening balance',
      'form': 'opening',
    });
    await post({
      'type': 'sale',
      'party': umer,
      'quantities': {'11800': 2, '45000': 1},
      'returned': {'11800': 2, '45000': 1},
      'extraGrams': 5000,
      'rate': rs(4640),
      'cash': rs(10000),
      'bank': rs(5000),
      'bankAccount': hbl,
      'direct': rs(3000),
      'directParty': supreme,
      'directBank': 'Meezan',
      'vehicle': 'LES-1234',
      'note': 'Thursday',
      'form': 'aamad',
    });
    await post({
      'type': 'transfer',
      'account': hbl,
      'toAccount': 'cash',
      'amount': rs(2000),
      'note': 'Office ke liye',
      'form': 'nikali',
    });
    await post({
      'type': 'discount',
      'party': umer,
      'amount': rs(500),
      'note': 'Rate farq',
      'form': 'less',
    });
    await post({
      'type': 'receipt',
      'party': umer,
      'bank': rs(1000),
      'bankAccount': hbl,
      'form': 'less',
    });
    await post({
      'type': 'payment',
      'party': supreme,
      'amount': rs(7000),
      'account': 'cash',
      'supplierPayment': true,
      'note': 'Bill clear',
      'branch': 'Main',
      'customerNote': 'Umer',
      'form': 'companyPay',
    });
    await post({
      'type': 'expense',
      'account': hbl,
      'amount': rs(300),
      'category': 'General',
      'note': 'Bank charges',
      'form': 'kharcha',
    });
    await post({
      'type': 'transfer',
      'account': 'cash',
      'toAccount': hbl,
      'amount': rs(4000),
      'form': 'bankJama',
    });
    await post({
      'type': 'purchase',
      'party': supreme,
      'grams': 100000,
      'rate': rs(300),
      'rateUnit': 1000,
      'amount': rs(9000),
      'account': 'cash',
    });
    await post({
      'type': 'stockAdjustment',
      'grams': 50000,
      'note': 'Opening stock',
    });

    app.setDate(date);
    final sheet = buildReport(app, 'Daily roznamcha', date, date).sheets.single;
    expect(sheet.heading, '01-11-2026 Safi Baqaya: Rs. 92,000');
    expect(cells(sheet.summary.body), [
      [
        'Rs. 100,000 Bank Nikali 2,000',
        'Rs. 120,000 Cash 10,000 | Bank 5,000 | Direct 3,000',
        'Rs. 28,000 Kharcha 16,000 | Bank Jama 9,000 | Direct 3,000',
        'Rs. 92,000 Bank Baqi 7,700',
      ],
    ]);
    expect(app.bookAt(date).money('cash'), rs(92000));
    expect(sheet.tables.map((t) => t.title), [
      'A: Aamad / Wasooli',
      'Bank Nikali / Less / Opening',
      'B: Kharcha + Bank Jama',
      'Baqi entries (gas, stock, transfer)',
    ]);

    // A gets the Direct to Party column on this day only.
    final a = sheet.tables[0];
    expect(heads(a), [
      '#',
      'PARCHI',
      'CUSTOMER / PARTY',
      '11.8K',
      '15K',
      '45K',
      'RATE',
      'BILL',
      'CASH',
      'BANK / ACCOUNT',
      'DIRECT TO PARTY',
      'KUL WASOOLI',
    ]);
    expect(a.wrap, {2, 9, 10});
    expect(cells(a.body), [
      [
        '1', 'LES-1234', 'Umer\nBulk 5 KG · Thursday', '2', '—', '1', //
        '4,640', '28,941', '10,000', '5,000 HBL Zubair', //
        '3,000 MEEZAN Supreme Petroleum', '18,000',
      ],
    ]);
    expect(cells(a.foot), [
      [
        'Total',
        '2',
        '0',
        '1',
        '',
        '28,941',
        '10,000',
        '5,000',
        '3,000',
        '18,000',
      ],
    ]);

    expect(cells(sheet.tables[1].body), [
      ['1', 'Bank se Nikali', 'HBL', 'Zubair', 'Office ke liye', '2,000'],
      ['2', 'Less (Cash)', 'CASH', '—', 'Umer — Rate farq', '500'],
      ['3', 'Less (Bank)', 'HBL', 'Zubair', 'Umer', '1,000'],
      ['4', 'Opening balance', '—', 'Umer', 'Customer owes you', '1,500'],
    ]);

    final b = sheet.tables[2];
    expect(cells(b.body), [
      [
        '1', 'COMPANY', 'CASH', 'Supreme Petroleum', //
        'Bill clear · Customer: Umer · Branch: Main', '7,000',
      ],
      ['2', 'KHARCHA', 'HBL', '—', 'Bank charges', '300'],
      ['3', 'BANK JAMA', 'HBL', 'Zubair', 'Cash jama → Zubair', '4,000'],
      [
        '4', 'PURCHASE PAYMENT', 'CASH', 'Supreme Petroleum', //
        '100 KG · Rate 300 per KG', '9,000',
      ],
      ['5', 'BANK JAMA', 'HBL', 'Zubair', 'Wasooli — Umer → Zubair', '5,000'],
      [
        '6', 'DIRECT TO PARTY', 'MEEZAN', 'Supreme Petroleum', //
        'Wasooli — Umer → Supreme Petroleum', '3,000',
      ],
    ]);
    // The bank-paid kharcha is listed but is not in cash's B total.
    expect(cells(b.foot), [
      ['Kul Kharcha + Bank Jama + Direct', '28,000'],
      ['Bank se diye kharcha (sirf bank ghata, cash par asar nahi)', '300'],
    ]);

    expect(cells(sheet.tables[3].body), [
      [
        '1', 'Purchase', 'Supreme Petroleum', '100 KG · Rate 300 per KG', //
        '30,000',
      ],
      [
        '2',
        'Stock adjustment',
        '—',
        'Gas added to stock · Opening stock',
        '+50 KG',
      ],
    ]);

    // In Urdu every label is translated; only "#" and the sizes stay.
    final urdu = buildReport(
      app,
      'Daily roznamcha',
      date,
      date,
      urdu: true,
    ).sheets.single;
    final script = RegExp(r'[\u0600-\u06ff]');
    for (final t in [urdu.summary, ...urdu.tables]) {
      for (final h in t.head) {
        if (!['#', '11.8K', '15K', '45K'].contains(h.text)) {
          expect(h.text, matches(script), reason: h.text);
        }
      }
      for (final f in t.foot) {
        expect(f.first.text, matches(script), reason: f.first.text);
      }
      if (t.title.isNotEmpty) expect(t.title, matches(script));
    }
    for (final t in urdu.tables.skip(1).take(2)) {
      for (final r in t.body) {
        expect(r[1].text, matches(script), reason: r[1].text);
      }
    }
    expect(urdu.title, matches(script));
    expect(urdu.stamp, matches(script));
    expect(urdu.heading, matches(script));
    // The Urdu sheet reads right to left, and so does its arrow.
    expect(urdu.tables[2].body[4][4].text, endsWith('Umer ← Zubair'));

    app.dispose();
    await db.close();
  });

  test(
    'A live print says when the day was saved only while it matches',
    () async {
      final (app, db) = await start();
      await referenceDay(app);
      app.setDate(day);
      String heading() =>
          buildReport(app, 'Daily roznamcha', day, day).sheets.single.heading;
      expect(heading(), '25-10-2026 Safi Baqaya: Rs. 2,910,390');
      await app.saveSnapshot();
      final saved = '${app.ofKind('snapshot').single.data['savedAt']}';
      expect(
        heading(),
        '25-10-2026 Saved: ${rozSavedTime(saved)} Safi Baqaya: Rs. 2,910,390',
      );
      expect(
        rozSavedTime(saved),
        matches(RegExp(r'^\d\d/\d\d/\d{4}, \d\d:\d\d:\d\d$')),
      );
      // A later entry: the printout is no longer the saved copy.
      await app.post({
        'date': day,
        'type': 'expense',
        'account': 'cash',
        'amount': rs(100),
        'category': 'General',
        'note': 'Chai',
        'form': 'kharcha',
      });
      expect(heading(), '25-10-2026 Safi Baqaya: Rs. 2,910,290');
      app.dispose();
      await db.close();
    },
  );

  test(
    'A range prints each day with entries; one asked-for day always',
    () async {
      final (app, db) = await start();
      await referenceDay(app);
      final range = buildReport(
        app,
        'Daily roznamcha',
        '2026-10-20',
        '2026-10-27',
      );
      expect(range.sheets.map((s) => s.date), ['2026-10-24', day]);
      // The day before holds only the starting cash.
      final before = range.sheets.first;
      expect(cells(before.table('Bank Nikali / Less / Opening')!.body), [
        [
          '1',
          'Opening balance',
          'CASH',
          '—',
          'Cash in hand · Opening',
          '2,660,690',
        ],
      ]);
      expect(
        before.summary.body.single.first.text,
        startsWith('Rs. 2,660,690 '),
      );

      // An empty day still prints, on the opening carried forward.
      final empty = buildReport(
        app,
        'Daily roznamcha',
        '2026-10-27',
        '2026-10-27',
      );
      expect(empty.rows, isEmpty);
      final sheet = empty.sheets.single;
      expect(sheet.heading, '27-10-2026 Safi Baqaya: Rs. 2,910,390');
      final a = sheet.tables.first, b = sheet.tables.last;
      expect(cells(a.body), [
        ['— Koi Aamad nahi —'],
      ]);
      expect(a.body.single.single.span, 11);
      expect(cells(b.body), [
        ['— Koi Kharcha nahi —'],
      ]);
      expect(b.body.single.single.span, 6);
      expect(cells(a.foot), [
        ['Total', '0', '0', '0', '', '0', '0', '0', '0'],
      ]);
      expect(
        cells(sheet.summary.body).single.first,
        'Rs. 2,910,390 Bank Nikali 0',
      );
      // Other reports have no sheets: their PDF stays the table.
      expect(buildReport(app, 'Cash book', day, day).sheets, isEmpty);
      app.dispose();
      await db.close();
    },
  );

  test('Every label of the sheet has an Urdu translation', () {
    final missing = <String>{};
    final source = File('lib/features/reports/roznamcha_sheet.dart')
        .readAsStringSync();
    for (final match in RegExp(r"\bt\('([^'\$\r\n]+)'\)").allMatches(source)) {
      final key = match.group(1)!;
      if (!Words.hasUrdu(key)) missing.add(key);
    }
    expect(missing, isEmpty);
  });

  testWidgets('The sheet prints in English and Urdu', (tester) async {
    for (final (family, asset) in [
      ('Manrope', 'assets/fonts/Manrope.ttf'),
      ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    // Windows draws the Latin part of Urdu names in Arial: so does the
    // preview, where this machine has it (Manrope stands in otherwise).
    final arial = [
      for (final name in ['arial.ttf', 'arialbd.ttf'])
        File('C:/Windows/Fonts/$name'),
    ].where((f) => f.existsSync());
    if (arial.isNotEmpty) {
      final loader = FontLoader('Arial');
      for (final f in arial) {
        loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      }
      await loader.load();
    }
    final (app, db) = (await tester.runAsync(start))!;
    await tester.runAsync(() async {
      await referenceDay(app);
      // The user's printed sheet itself, as saved and printed on 26-10-2026,
      // to hold beside the photo.
      app.setDate('2026-10-26');
      final saved = Record('saved', 'snapshot', {
        'date': day,
        'savedAt': '2026-10-26T10:20:21.000',
        'documents': [
          for (final d in app.book.documents.where((d) => d.date == day))
            d.record.toJson(),
        ],
      });
      await File('build/preview-roznamcha-reference.pdf')
          .writeAsBytes(await ReportExporter().pdf(snapshotReport(app, saved)));
      // Names as the business types them: Urdu with English.
      final luqman = await account(app, 'لقمان احمد Luqman Ahmad', 'HBL');
      final ali = await party(app, 'علی رضا Ali Raza');
      await app.post({
        'date': day,
        'occurredAt': 50,
        'type': 'sale',
        'party': ali,
        'quantities': {'11800': 4, '45000': 2},
        'returned': {'11800': 4, '45000': 2},
        'extraGrams': 14500,
        'rate': rs(4640),
        'cash': rs(30000),
        'bank': rs(25000),
        'bankAccount': luqman,
        'vehicle': '12',
        'note': 'میاں صاحب کا آرڈر',
        'form': 'aamad',
      });
      app.setDate('2026-10-26');
      // Names with Urdu are isolated inside a longer text, so two of them
      // around the arrow cannot run together and swap sides.
      final lri = String.fromCharCode(0x2066),
          pdi = String.fromCharCode(0x2069);
      expect(
        buildReport(
          app,
          'Daily roznamcha',
          day,
          day,
        ).sheets.single.tables.last.body.last[4].text,
        'Wasooli — $lriعلی رضا Ali Raza$pdi → $lriلقمان احمد Luqman Ahmad$pdi',
      );
      for (final urdu in [false, true]) {
        final report = buildReport(
          app,
          'Daily roznamcha',
          day,
          day,
          urdu: urdu,
        );
        final bytes = await ReportExporter().pdf(report);
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        await File(
          'build/preview-roznamcha-sheet-${urdu ? 'urdu' : 'english'}.pdf',
        ).writeAsBytes(bytes);
      }
      // Closing the preview stops the export.
      final stopped = ReportExporter()..cancelled = true;
      await expectLater(
        stopped.pdf(buildReport(app, 'Daily roznamcha', day, day)),
        throwsA(isA<ReportCancelled>()),
      );
      app.dispose();
      await db.close();
    });
  });
}
