import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/entry_facts.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController app;
  late String today;
  String daysAgo(int n) =>
      DateTime.parse(today)
          .subtract(Duration(days: n))
          .toIso8601String()
          .substring(0, 10);
  Future<void> post(int ago, Map<String, dynamic> data) =>
      app.post({'date': daysAgo(ago), ...data});
  List<String> texts(List<Cell> row) => row.map((c) => c.text).toList();

  setUp(() async {
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    app = AppController(db);
    await app.initialize();
    today = app.selectedDate;
  });

  test(
    'Udhari party: one khata, newest first, no empty sections or zero openings',
    () async {
      await app.saveMaster('party', {
        'name': 'Ustad Usman',
        'customer': false,
        'udhari': true,
      });
      final usman = app.partyByName('Ustad Usman')!.id;
      await post(11, {
        'type': 'adjustment',
        'party': usman,
        'target': 'ap:$usman',
        'amount': -322500000,
        'occurredAt': 0,
        'note': 'Opening balance',
      });
      await post(10, {
        'type': 'payment',
        'party': usman,
        'amount': 150000000,
        'account': 'cash',
        'supplierPayment': true,
        'form': 'udharWapsi',
        'note': 'Malik Abbas le gaya',
      });
      final r = buildReport(
        app,
        'Party statement',
        daysAgo(11),
        today,
        party: usman,
      );
      expect(r.rows, hasLength(2));
      final wapsi = r.rows[0], opening = r.rows[1];
      expect(wapsi[0].text, daysAgo(10));
      expect(wapsi[2].text, contains('Udhar wapsi'));
      expect(wapsi[2].text, contains('Malik Abbas le gaya'));
      expect(wapsi[3].numeric, 1500000);
      expect(wapsi[4].text, '');
      expect(wapsi[5].text, 'You owe 1,725,000');
      expect(wapsi[5].numeric, -1725000);
      expect(opening[0].text, daysAgo(11));
      expect(opening[2].text, contains('Opening balance'));
      expect(opening[3].text, '');
      expect(opening[4].numeric, 3225000);
      expect(opening[5].text, 'You owe 3,225,000');
      for (final row in r.rows) {
        expect(texts(row), isNot(contains('Opening')));
        expect(texts(row), isNot(contains('Trade payable')));
        expect(texts(row), isNot(contains('Refundable deposit')));
      }
      // Same balance as the party screen's running balance.
      final newest = app.book.documents.lastWhere((d) => d.party == usman);
      expect(
        wapsi[5].numeric,
        partyBalances(app.book, usman)[newest.id]! / 100,
      );
    },
  );

  test('A sale paid in part is one row; the opening brought forward is last, '
      'and deposits get their own section', () async {
    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
    await app.saveMaster('party', {'name': 'Ali Traders'});
    final ali = app.partyByName('Ali Traders')!.id;
    await post(5, {
      'type': 'sale',
      'party': ali,
      'quantities': {'11800': 1},
      'returned': {'11800': 1},
      'rate': 464000,
    });
    await post(3, {
      'type': 'sale',
      'party': ali,
      'quantities': {'11800': 2},
      'returned': {'11800': 2},
      'rate': 464000,
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

    final r = buildReport(
      app,
      'Party statement',
      daysAgo(4),
      today,
      party: ali,
    );
    // Sale (one row), Opening brought forward, deposit heading, deposit row.
    expect(r.rows, hasLength(4));
    final sale = r.rows[0];
    expect(sale[0].text, daysAgo(3));
    expect(sale[2].text, contains('11.8'));
    expect(sale[3].numeric, 9280);
    expect(sale[4].numeric, 5000);
    expect(sale[5].text, 'Owes you 8,920'); // 4,640 brought forward + 4,280
    expect(texts(r.rows[1]), [
      daysAgo(4),
      '',
      'Opening',
      '',
      '',
      'Owes you 4,640',
    ]);
    expect(r.rows[2][2].text, 'Refundable deposit');
    expect(r.rows[3][4].numeric, 3000);
    expect(r.rows[3][5].numeric, 3000);
    expect(r.rows.where((row) => row[2].text == 'Opening'), hasLength(1));

    // From the first entry there is nothing to bring forward.
    final all = buildReport(
      app,
      'Party statement',
      daysAgo(5),
      today,
      party: ali,
    );
    expect(all.rows.where((row) => row[2].text == 'Opening'), isEmpty);
    expect(all.rows.first[0].text, daysAgo(3));
    expect(all.rows[1][0].text, daysAgo(5));

    // A party with no deposits has no deposit section.
    await app.saveMaster('party', {'name': 'Bilal'});
    final bilal = app.partyByName('Bilal')!.id;
    await post(1, {
      'type': 'sale',
      'party': bilal,
      'quantities': {'11800': 1},
      'returned': {'11800': 1},
      'rate': 464000,
    });
    final b = buildReport(
      app,
      'Party statement',
      daysAgo(5),
      today,
      party: bilal,
    );
    expect(b.rows, hasLength(1));
  });

  test('Cash book and Gas stock list the newest entry first', () async {
    await post(4, {
      'type': 'adjustment',
      'target': 'money:cash',
      'amount': 5000000,
      'occurredAt': 0,
      'note': 'Opening balance',
    });
    await post(2, {
      'type': 'expense',
      'account': 'cash',
      'amount': 50000,
      'category': 'General',
      'note': 'Chai pani',
    });
    await post(3, {
      'type': 'stockAdjustment',
      'grams': 100000,
      'note': 'Found',
    });
    await post(1, {'type': 'stockAdjustment', 'grams': -5000, 'note': 'Leak'});

    final cash = buildReport(app, 'Cash book', daysAgo(4), today);
    expect(cash.rows.map((r) => r[0].text), [daysAgo(2), daysAgo(4)]);
    expect(cash.rows.first[2].text, contains('Chai pani'));
    expect(cash.rows.first[5].numeric, 49500);

    final gas = buildReport(app, 'Gas stock', daysAgo(4), today);
    expect(gas.rows.map((r) => r[0].text), [daysAgo(1), daysAgo(3)]);
    expect(gas.rows.first[4].numeric, 95);

    // Starting later brings the earlier balance forward as the last row.
    final later = buildReport(app, 'Gas stock', daysAgo(2), today);
    expect(texts(later.rows.last), [daysAgo(2), '', 'Opening', '', '100']);
  });
}
