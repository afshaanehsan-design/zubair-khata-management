import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';

const day = '2026-11-07';
var _time = 0;
Record doc(String id, String type, Json data, {String date = day}) => Record(
  id,
  'document',
  {'type': type, 'date': date, 'occurredAt': ++_time, ...data},
);

const parties = [
  Record('ali', 'party', {'name': 'Ali', 'customer': true}),
  Record('bilal', 'party', {'name': 'Bilal', 'customer': true}),
  Record('pso', 'party', {'name': 'PSO', 'supplier': true}),
];
const accounts = [
  Record('cash', 'account', {'name': 'Cash'}),
  Record('hbl', 'account', {'name': 'Zubair', 'bank': 'HBL'}),
  Record('mzn', 'account', {'name': 'Luqman', 'bank': 'Meezan'}),
];

/// Rupees to paisa.
int rs(int rupees) => rupees * 100;

void main() {
  test(
    'Roznamcha totals follow the HTML computeDay() rules and Safi equals cash',
    () {
      final records = [
        ...parties,
        ...accounts,
        // Yesterday: opening cash of Rs 100,000.
        doc('open', 'adjustment', {
          'target': 'money:cash',
          'amount': rs(100000),
          'note': 'Opening',
        }, date: '2026-11-06'),
        // Today's opening correction (+200), shown inside the opening.
        doc('cashfix', 'adjustment', {
          'target': 'money:cash',
          'amount': rs(200),
          'note': 'Count',
          'occurredAt': 0,
        }),
        // A: Aamad — Ali 2 × 11.8 KG @ 4640, paid 5,000 cash + 4,280 bank.
        doc('ali-sale', 'sale', {
          'party': 'ali',
          'quantities': {'11800': 2},
          'returned': {'11800': 2},
          'rate': rs(4640),
          'cash': rs(5000),
          'bank': rs(4280),
          'bankAccount': 'hbl',
          'vehicle': '92',
        }),
        // Wasooli only (no cylinders): HTML Aamad row without a sale.
        doc('bilal-in', 'receipt', {'party': 'bilal', 'cash': rs(2000)}),
        // Company se wasooli: 1,000 cash + 3,000 bank.
        doc('pso-in', 'receipt', {
          'party': 'pso',
          'supplierRefund': true,
          'cash': rs(1000),
          'bank': rs(3000),
          'bankAccount': 'hbl',
        }),
        // Bank se nikali 10,000 from HBL.
        doc('nikali', 'transfer', {
          'account': 'hbl',
          'toAccount': 'cash',
          'amount': rs(10000),
        }),
        // Less: discount 280 for Ali, bank deposit 1,000 by Bilal.
        doc('ali-less', 'discount', {'party': 'ali', 'amount': rs(280)}),
        doc('bilal-less', 'receipt', {
          'party': 'bilal',
          'bank': rs(1000),
          'bankAccount': 'mzn',
          'form': 'less',
        }),
        // B: Kharcha.
        doc('tea', 'expense', {
          'account': 'cash',
          'amount': rs(500),
          'category': 'General',
          'note': 'Chai',
        }),
        doc('office', 'expense', {
          'account': 'cash',
          'amount': rs(300),
          'category': 'Office',
          'note': 'Bijli',
        }),
        doc('pso-pay', 'payment', {
          'party': 'pso',
          'supplierPayment': true,
          'account': 'cash',
          'amount': rs(20000),
        }),
        doc('bilal-pay', 'payment', {
          'party': 'bilal',
          'account': 'hbl',
          'amount': rs(700),
        }),
        doc('jama', 'transfer', {
          'account': 'cash',
          'toAccount': 'hbl',
          'amount': rs(15000),
        }),
        // Balance correction of a customer: no cash effect.
        doc('ali-adj', 'adjustment', {
          'party': 'ali',
          'target': 'ar:ali',
          'amount': rs(500),
          'note': 'Purana hisab',
        }),
      ];
      final book = Book(records, throughDate: day);
      final docs = book.documents.where((d) => d.date == day).toList();
      final opening = book.money('cash') - book.dayMovement(day, 'money:cash');
      final r = RoznamchaDay(day, opening, docs);

      expect(opening, rs(100000));
      expect(r.cashAdj, rs(200));
      expect(r.cashIn, rs(5000 + 2000 + 1000));
      expect(r.bankCust, rs(4280 + 3000));
      expect(r.wd, rs(10000));
      expect(r.left, rs(100000 + 200 + 8000 + 7280 + 10000));
      expect(r.kharchaCash, rs(500 + 300 + 20000));
      expect(r.officeCash, rs(300));
      expect(r.companyCash, rs(20000));
      expect(r.kharchaBank, rs(700));
      expect(r.depMan, rs(15000));
      expect(r.rightTotal, rs(20800 + 7280 + 15000));
      expect(r.safi, rs(82400));
      // The page and the ledger always agree on cash in hand.
      expect(r.safi, book.money('cash'));
      expect(r.lessDiscount, rs(280));
      expect(r.lessBank, rs(1000));
      expect(r.bankNet, rs(7280 + 15000 + 1000 - 10000 - 700));
      expect(r.bill, rs(9280));
      expect(r.cylinders[11800], 2);
      expect(r.cylinderGrams, 23600);

      expect(r.aamad.map((d) => d.id), ['ali-sale', 'bilal-in', 'pso-in']);
      expect(r.less.map((d) => d.id), ['ali-less', 'bilal-less']);
      expect(r.nikali.map((d) => d.id), ['nikali']);
      expect(r.openings.map((d) => d.id), ['cashfix', 'ali-adj']);
      expect(r.kharcha.map((d) => d.id), [
        'tea',
        'office',
        'pso-pay',
        'bilal-pay',
      ]);
      expect(r.bankJama.map((l) => (l.document.id, l.automatic, l.amount)), [
        ('ali-sale', true, rs(4280)),
        ('pso-in', true, rs(3000)),
        ('jama', false, rs(15000)),
      ]);
      expect(r.other, isEmpty);

      // Khata balances match the HTML customer / company formulas.
      expect(book.receivable('ali'), rs(9280 - 5000 - 4280 - 280 + 500));
      expect(book.receivable('bilal'), rs(-2000 - 1000 + 700));
      expect(book.payable('pso'), rs(4000 - 20000));
      expect(book.money('hbl'), rs(4280 + 3000 - 10000 + 15000 - 700));
      expect(book.money('mzn'), rs(1000));
    },
  );

  test('Bill uses the HTML formula: rate ÷ 11.8 × (cylinder KG + bulk KG)', () {
    final sale = Document(
      doc('s', 'sale', {
        'party': 'ali',
        'quantities': {'11800': 1, '15000': 2, '45000': 1},
        'rate': rs(4640),
        'extraGrams': 7500,
      }),
    );
    // Math.round(4640 / 11.8 * (11.8 + 30 + 45 + 7.5)) = Math.round(37080.68)
    expect(sale.bill, rs(37081));
    // Sales Khata uses cylinders only: Math.round(4640 / 11.8 * 86.8)
    expect(sale.cylinderRevenue, rs(34132));
  });

  test('Stored form wins only when it fits the entry; otherwise inferred', () {
    Document d(String type, Json data) => Document(doc('x', type, data));
    expect(rozFormOf(d('receipt', {'bank': 1, 'form': 'less'})), RozForm.less);
    expect(rozFormOf(d('receipt', {'bank': 1})), RozForm.aamad);
    expect(
      rozFormOf(d('receipt', {'supplierRefund': true, 'form': 'less'})),
      RozForm.companyIn,
    );
    expect(rozFormOf(d('expense', {'category': 'Office'})), RozForm.office);
    expect(
      rozFormOf(d('transfer', {'account': 'hbl', 'toAccount': 'mzn'})),
      isNull,
    );
    expect(
      rozFormOf(d('transfer', {'account': 'cash', 'toAccount': 'hbl'})),
      RozForm.bankJama,
    );
  });

  test('Udhar wapsi is a Kharcha row that reduces what you owe the party', () {
    final records = [
      ...parties,
      ...accounts,
      const Record('usman', 'party', {
        'name': 'Ustad Usman',
        'customer': false,
        'udhari': true,
      }),
      doc('borrowed', 'adjustment', {
        'party': 'usman',
        'target': 'ap:usman',
        'amount': rs(-3225000),
        'occurredAt': 0,
      }, date: '2026-10-31'),
      doc('cash-open', 'adjustment', {
        'target': 'money:cash',
        'amount': rs(2000000),
        'occurredAt': 0,
      }, date: '2026-10-31'),
      doc('wapsi', 'payment', {
        'party': 'usman',
        'amount': rs(1500000),
        'account': 'cash',
        'supplierPayment': true,
        'form': 'udharWapsi',
        'note': 'Malik Abbas le gaya',
      }),
    ];
    final book = Book(records);
    final wapsi = book.documents.firstWhere((d) => d.id == 'wapsi');
    expect(rozFormOf(wapsi), RozForm.udharWapsi);
    expect(rozTypeLabel(wapsi), 'Udhar wapsi');
    expect(book.payable('usman'), rs(3225000 - 1500000));
    expect(book.receivable('usman'), 0);

    final r = RoznamchaDay(
      day,
      rs(2000000),
      book.documents.where((d) => d.date == day),
    );
    expect(r.kharcha.map((d) => d.id), ['wapsi']);
    expect(r.kharchaCash, rs(1500000));
    expect(r.udharCash, rs(1500000));
    expect(r.companyCash, 0);
    expect(r.safi, book.money('cash'));

    // The form is display-only: without supplierPayment it cannot be an
    // Udhar wapsi, so the stored name is ignored.
    final wrong = Document(
      doc('x', 'payment', {'party': 'usman', 'form': 'udharWapsi'}),
    );
    expect(rozFormOf(wrong), RozForm.customerPay);
  });

  test('Cash paid with a purchase reaches Kharcha so Safi stays exact', () {
    final records = [
      ...parties,
      ...accounts,
      doc('p', 'purchase', {
        'party': 'pso',
        'grams': 100000,
        'rate': rs(300),
        'rateUnit': 1000,
        'amount': rs(5000),
        'account': 'cash',
      }),
    ];
    final book = Book(records);
    final r = RoznamchaDay(day, 0, book.documents);
    expect(r.kharchaCash, rs(5000));
    expect(r.companyCash, rs(5000));
    expect(r.safi, book.money('cash'));
    expect(r.other.single.id, 'p');
    expect(r.gasIn, 100000);
  });
}
