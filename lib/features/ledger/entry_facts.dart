import '../../core/controller.dart';
import '../../core/l10n.dart';
import '../../core/models.dart';
import '../reports/reports.dart' show kg, money;
import 'book.dart';
import 'roznamcha.dart' show RozForm, isOpeningBalance, rozFormOf, rozNote;

// Plain-language description of one entry, shared by the details dialog, the
// entry lists and the review of pending changes. It only reads documents and
// the Book projection; nothing here changes accounting. Every label passed
// through the translator in this file needs an Urdu entry in l10n.dart
// (test/l10n_test.dart and test/entry_facts_test.dart check).

/// A labelled line. [openId] makes it tappable: it names a document to open.
class Fact {
  final String label, value;
  final bool strong;
  final String? openId;
  const Fact(this.label, this.value, {this.strong = false, this.openId});
}

/// A line of the bill: one cylinder size, extra KG, rounding or deposit.
class BillRow {
  final String label;
  final String? caption;
  final int amount;
  const BillRow(this.label, this.caption, this.amount);
}

/// The one-word state of an entry: Paid, Due Rs X, You owe Rs X or Voided.
class EntryStatus {
  final String label;
  final bool warning;
  const EntryStatus(this.label, this.warning);
}

String rs(int minor) =>
    minor < 0 ? '-Rs ${money(-minor)}' : 'Rs ${money(minor)}';

/// A change with its sign ("+Rs 1,000"), so it is not read as a balance.
String signedRs(int minor) => minor > 0
    ? '+Rs ${money(minor)}'
    : minor < 0
    ? '-Rs ${money(-minor)}'
    : 'Rs 0';

String _signed(int n) => n > 0 ? '+$n' : '$n';
String _signedKg(int grams) =>
    '${grams > 0
        ? '+'
        : grams < 0
        ? '-'
        : ''}${kg(grams.abs())} KG';
String _join(Iterable<String> parts, [String separator = ' · ']) =>
    parts.where((p) => p.trim().isNotEmpty).join(separator);
String _text(Document d, String key) => '${d.data[key] ?? ''}'.trim();

String accountName(AppController app, String id, Words t) {
  if (id == 'cash') return t('Cash');
  final r = app.record(id);
  if (r == null) return id;
  final bank = '${r.data['bank'] ?? ''}'.trim();
  return bank.isEmpty ||
          AppController.nameKey(r.name).contains(AppController.nameKey(bank))
      ? r.name
      : '${r.name} · $bank';
}

String _rateUnit(Document d, Words t) => t(switch (d.value('rateUnit')) {
  1000 => 'per KG',
  1000000 => 'per tonne',
  _ => 'per 11.8 KG',
});

int _cylinderCount(Document d) => [
  d.value('fullDelta').abs(),
  d.value('emptyDelta').abs(),
  d.value('heldDelta').abs(),
].reduce((a, b) => a > b ? a : b);

/// What kind of entry this is, in words ("Opening balance" rather than the
/// bookkeeping type "adjustment").
String entryTypeLabel(Document d, Words t) {
  if (d.type == EntryType.adjustment) {
    return t(isOpeningBalance(d) ? 'Opening balance' : 'Adjustment');
  }
  if (d.type == EntryType.receipt && d.data['supplierRefund'] == true) {
    return t('Supplier refund');
  }
  if (d.type == EntryType.payment && d.data['supplierPayment'] == true) {
    return t(
      rozFormOf(d) == RozForm.udharWapsi ? 'Udhar wapsi' : 'Supplier payment',
    );
  }
  return t(entryLabel(d.type.name));
}

/// An Udhari party that is not also a company: its payable side is money
/// borrowed (udhar), not a supplier balance.
bool _udhariParty(AppController app, String id) {
  final data = app.record(id)?.data;
  return data?['udhari'] == true && data?['supplier'] != true;
}

/// The balance an adjustment applies to: an account or a party.
String adjustmentTarget(AppController app, Document d, Words t) {
  final target = '${d.data['target'] ?? ''}';
  final i = target.indexOf(':');
  final id = i < 0 ? d.party : target.substring(i + 1);
  return target.startsWith('money:') ? accountName(app, id, t) : app.name(id);
}

/// What an adjustment's amount means for the business. With [app], the
/// payable of an Udhari party is called udhar rather than a company balance.
String adjustmentMeaning(Document d, Words t, [AppController? app]) {
  final target = '${d.data['target'] ?? 'ar:'}';
  final amount = d.value('amount');
  if (target.startsWith('money:')) {
    return t(target == 'money:cash' ? 'Cash in hand' : 'Money in account');
  }
  if (target.startsWith('ap:')) {
    if (app != null && _udhariParty(app, target.substring(3))) {
      return t(
        amount <= 0
            ? 'Udhar liya — aap ne dena hai'
            : 'Udhar diya — aap ne lena hai',
      );
    }
    return t(amount <= 0 ? 'You owe the company' : 'Company owes you');
  }
  if (target.startsWith('deposit:')) return t('Deposit held for customer');
  return t(amount >= 0 ? 'Customer owes you' : 'You owe the customer');
}

/// Whether [party] is the one a customer paid directly with this entry (and
/// not the customer itself). In that party's khata the entry is a payment it
/// received, not the customer's sale or receipt.
bool directFor(Document d, String? party) =>
    party != null &&
    party.isNotEmpty &&
    d.directParties.contains(party) &&
    d.party != party;

/// What a direct payment is called in the khata of the party that got it.
String directTitle(Words t) => t('Bank payment');

/// The banks used for this company, followed by the customer who paid it.
String directHeadline(AppController app, Document d, String party, Words t) =>
    _join([
      ...{
        for (final l in d.bankLines)
          if (l.direct && l.party == party && l.bankName.trim().isNotEmpty)
            l.bankName.trim(),
      },
      '${t('Customer')}: ${app.name(d.party)}',
    ]);

String directDestination(AppController app, BankLine l) =>
    _join([app.name(l.party), l.bankName]);

/// The first line of a list row: the party, or what the entry is about.
String entryTitle(AppController app, Document d, Words t) {
  if (d.party.isNotEmpty) return app.name(d.party);
  switch (d.type) {
    case EntryType.adjustment:
      return adjustmentTarget(app, d, t);
    case EntryType.expense:
      final category = _text(d, 'category');
      return category.isEmpty ? entryTypeLabel(d, t) : category;
    case EntryType.transfer:
      return '${accountName(app, d.account, t)} → ${accountName(app, '${d.data['toAccount']}', t)}';
    default:
      return entryTypeLabel(d, t);
  }
}

/// One line saying what the entry contains: the cylinders and rate of a sale,
/// the weight of a purchase, how a payment was made…
String entryHeadline(AppController app, Document d, Words t) {
  final note = rozNote(d);
  switch (d.type) {
    case EntryType.sale:
      return _join([
        _join([
          d.saleLines
              .map((l) => '${sizeLabel(l.size)} × ${l.count}')
              .join(', '),
          if (d.extraGrams > 0) '+${kg(d.extraGrams)} KG ${t('Extra KG')}',
        ], ', '),
        '${t('Rate')} ${money(d.rate)}',
        for (final l in d.bankLines)
          if (l.direct)
            '${t('Direct to party')} ${money(l.amount)} (${directDestination(app, l)})',
      ]);
    case EntryType.creditNote:
      return _join([
        d.saleLines.map((l) => '${sizeLabel(l.size)} × ${l.count}').join(', '),
        if (d.data['stockReturned'] == true) t('Return gas to stock'),
      ]);
    case EntryType.receipt:
      return _join([
        if (d.value('cash') > 0) '${t('Cash')} ${money(d.value('cash'))}',
        for (final l in d.bankLines)
          l.direct
              ? '${t('Direct to party')} ${money(l.amount)} (${directDestination(app, l)})'
              : '${t('Bank')} ${money(l.amount)} (${accountName(app, l.account, t)})',
      ]);
    case EntryType.payment:
      return _join([
        '${t('Paid from')} ${accountName(app, d.account, t)}',
        _text(d, 'branch'),
      ]);
    case EntryType.expense:
      return '${t('Paid from')} ${accountName(app, d.account, t)}';
    case EntryType.purchase:
      return _join([
        '${kg(d.value('grams'))} KG',
        '${t('Rate')} ${money(d.rate)} ${_rateUnit(d, t)}',
      ]);
    case EntryType.transfer:
      return '';
    case EntryType.discount:
      return t('Khata se minus (discount)');
    case EntryType.deposit:
      return '${t('Received into')} ${accountName(app, d.account, t)}';
    case EntryType.depositRefund:
      return '${t('Paid from')} ${accountName(app, d.account, t)}';
    case EntryType.adjustment:
      return _join([adjustmentMeaning(d, t, app), note]);
    case EntryType.stockAdjustment:
      return _join([
        t(
          d.value('grams') > 0
              ? 'Gas added to stock'
              : 'Gas removed from stock',
        ),
        if (d.data['costKnown'] == true && d.value('cost') > 0)
          '${t('Cost')} ${money(d.value('cost'))}',
        note,
      ]);
    case EntryType.cylinder:
      return _join([
        sizeLabel(d.value('size')),
        t('${d.data['cylinderMode'] ?? 'Loss / correction'}'),
        if (d.value('fullDelta') != 0)
          '${t('Full')} ${_signed(d.value('fullDelta'))}',
        if (d.value('emptyDelta') != 0)
          '${t('Empty')} ${_signed(d.value('emptyDelta'))}',
        if (d.value('heldDelta') != 0)
          '${t('Customer-held')} ${_signed(d.value('heldDelta'))}',
      ]);
    case EntryType.historicalSale:
      return '${kg(d.value('grams'))} KG';
  }
}

/// Money of an entry, or 0 for entries that move only gas or cylinders.
int entryAmount(Document d) => d.total == 0 ? d.collected : d.total;

/// The figure shown at the end of a row: money, or the quantity for gas and
/// cylinder entries that have no money.
String entryAmountText(Document d) => switch (d.type) {
  EntryType.stockAdjustment => _signedKg(d.value('grams')),
  EntryType.cylinder => '${_cylinderCount(d)} × ${sizeLabel(d.value('size'))}',
  EntryType.adjustment => rs(d.value('amount')),
  _ => rs(entryAmount(d)),
};

bool entryAmountNegative(Document d) =>
    (d.type == EntryType.adjustment && d.value('amount') < 0) ||
    (d.type == EntryType.stockAdjustment && d.value('grams') < 0);

/// What the headline figure of the details dialog is called.
String entryAmountLabel(Document d, Words t) => t(switch (d.type) {
  EntryType.sale => 'Bill total',
  EntryType.creditNote => 'Credit note',
  EntryType.purchase => 'Purchase bill',
  EntryType.receipt => 'Amount received',
  EntryType.payment || EntryType.depositRefund => 'Amount paid',
  EntryType.stockAdjustment || EntryType.historicalSale => 'Gas',
  EntryType.cylinder => 'Cylinders',
  _ => 'Amount',
});

EntryStatus? entryStatus(AppController app, Document d, Words t) {
  if (d.voided) return EntryStatus(t('Voided'), true);
  if (d.type == EntryType.sale) {
    final due = app.book.invoiceDue[d.id] ?? 0;
    return due > 0
        ? EntryStatus('${t('Due')} ${rs(due)}', true)
        : EntryStatus(t('Paid'), false);
  }
  if (d.type == EntryType.purchase) {
    final owed = d.purchaseBill - d.value('amount');
    return owed > 0
        ? EntryStatus('${t('You owe')} ${rs(owed)}', true)
        : EntryStatus(t('Paid'), false);
  }
  return null;
}

/// The bill of a sale or credit note, line by line.
List<BillRow> billRows(Document d, Words t) => [
  for (final l in d.saleLines)
    BillRow('${sizeLabel(l.size)} × ${l.count}', '${kg(l.grams)} KG', l.amount),
  if (d.lineRounding != 0) BillRow(t('Rounding'), null, d.lineRounding),
  if (d.extraGrams > 0)
    BillRow(
      t('Extra KG (billing only)'),
      '${kg(d.extraGrams)} KG',
      d.bulkRevenue,
    ),
  if (d.type == EntryType.sale && d.value('depositCharge') != 0)
    BillRow(t('Deposit charged'), null, d.value('depositCharge')),
];

/// Cylinders handed over and taken back with a sale, and what the customer
/// holds in total now.
List<Fact> cylinderFacts(AppController app, Document d, Words t) {
  if (d.type != EntryType.sale) return [];
  if (d.data['customerOwned'] == true) {
    return [Fact(t('Customer-owned cylinders'), t('Yes'))];
  }
  final out = <Fact>[];
  for (final size in sizes) {
    final issued = integer((d.data['quantities'] as Map?)?['$size']);
    final returned = integer((d.data['returned'] as Map?)?['$size']);
    if (issued == 0 && returned == 0) continue;
    out.add(
      Fact(
        sizeLabel(size),
        '${t('Delivered')} $issued · ${t('Empties returned')} $returned',
      ),
    );
  }
  final holds = [
    for (final size in sizes)
      if ((app.book.held['${d.party}:$size'] ?? 0) != 0)
        '${sizeLabel(size)} × ${app.book.held['${d.party}:$size']}',
  ];
  if (holds.isNotEmpty) {
    out.add(Fact(t('Customer holds now'), holds.join(', '), strong: true));
  }
  return out;
}

/// Cash and bank taken with a sale or receipt, what the customer paid
/// directly to another party, and what is still due.
List<Fact> paymentFacts(AppController app, Document d, Words t) {
  final sale = d.type == EntryType.sale;
  if (!sale && d.type != EntryType.receipt) return [];
  final cash = d.value('cash');
  return [
    if (cash > 0) Fact(t('Cash received'), rs(cash)),
    for (final l in d.bankLines)
      Fact(
        t(l.direct ? 'Paid directly to party' : 'Bank received'),
        _join([
          rs(l.amount),
          l.direct ? directDestination(app, l) : accountName(app, l.account, t),
        ]),
      ),
    if (sale && d.collected == 0) Fact(t('Received at sale'), rs(0)),
    if (sale && !d.voided)
      Fact(
        t('Still due on this bill'),
        rs(app.book.invoiceDue[d.id] ?? 0),
        strong: true,
      ),
  ];
}

/// Why the money taken with an entry did not reduce this bill: collections go
/// to the oldest balance first, so an opening balance can absorb them.
List<String> paymentNotes(AppController app, Document d, Words t) {
  final sale = d.type == EntryType.sale;
  if (d.voided ||
      (!sale && d.type != EntryType.receipt) ||
      d.data['supplierRefund'] == true) {
    return [];
  }
  final received = d.collected;
  final applied = (app.book.receiptAllocations[d.id] ?? const <(String, int)>[])
      .fold(0, (sum, a) => sum + a.$2);
  final older = received - applied;
  if (older <= 0) return [];
  return [
    t(
      sale
          ? 'Rs {amount} of the money received here went to the older balance first (or is kept as advance), not to this bill.'
          : 'Rs {amount} went to the older balance (or is kept as advance).',
    ).replaceAll('{amount}', money(older)),
  ];
}

/// Later (or earlier, if kept as advance) payments, credits and discounts
/// applied to this bill. What was taken with the sale itself is left out: the
/// Payment card shows it.
List<Fact> billPayments(AppController app, Document d, Words t) {
  if (d.type != EntryType.sale || d.voided) return [];
  final book = app.book;
  final position = {
    for (var i = 0; i < book.documents.length; i++) book.documents[i].id: i,
  };
  final paid = <String, int>{};
  for (final e in book.receiptAllocations.entries) {
    if (e.key == d.id) continue;
    for (final (claim, amount) in e.value) {
      if (claim == d.id) {
        paid.update(e.key, (v) => v + amount, ifAbsent: () => amount);
      }
    }
  }
  final sources = paid.keys.where(position.containsKey).toList()
    ..sort((a, b) => position[a]!.compareTo(position[b]!));
  return [
    for (final id in sources)
      Fact(
        _join([
          entryTypeLabel(book.documents[position[id]!], t),
          book.documents[position[id]!].date,
          book.documents[position[id]!].reference,
        ]),
        rs(paid[id]!),
        openId: id,
      ),
  ];
}

/// The other bills this entry's money was applied to.
List<Fact> appliedFacts(AppController app, Document d, Words t) {
  if (d.voided) return [];
  return [
    for (final (claim, amount)
        in app.book.receiptAllocations[d.id] ?? const <(String, int)>[])
      if (claim != d.id)
        Fact(
          app.record(claim) == null
              ? claim
              : _join([
                  t('Sale'),
                  Document(app.record(claim)!).date,
                  Document(app.record(claim)!).reference,
                ]),
          rs(amount),
          openId: claim,
        ),
  ];
}

/// Everything else worth knowing about an entry, by type. Empty values are
/// left out, so a row never shows a label with nothing next to it.
List<Fact> detailFacts(AppController app, Document d, Words t) {
  final out = <Fact>[];
  void add(String label, String value, {String? openId}) {
    if (value.trim().isNotEmpty) {
      out.add(Fact(t(label), value, openId: openId));
    }
  }

  final account = accountName(app, d.account, t);
  switch (d.type) {
    case EntryType.sale:
      add('Vehicle / parchi', _text(d, 'vehicle'));
      add('Due date', _text(d, 'dueDate'));
    case EntryType.creditNote:
      final source = app.record('${d.data['sourceInvoice']}');
      if (source != null) {
        add('Original invoice', Document(source).reference, openId: source.id);
      }
      add(
        'Return gas to stock',
        t(d.data['stockReturned'] == true ? 'Yes' : 'No'),
      );
    case EntryType.receipt:
      add('Vehicle / parchi', _text(d, 'vehicle'));
    case EntryType.payment:
      add('Paid from', account);
      add('Branch', _text(d, 'branch'));
      add('Customer annotation', _text(d, 'customerNote'));
    case EntryType.expense:
      add('Category', _text(d, 'category'));
      add('Paid from', account);
    case EntryType.purchase:
      final owed = d.purchaseBill - d.value('amount');
      add('Weight (KG)', kg(d.value('grams')));
      add('Rate', '${rs(d.rate)} ${_rateUnit(d, t)}');
      add('Purchase bill', rs(d.purchaseBill));
      if (d.value('amount') > 0) {
        add('Paid now', _join([rs(d.value('amount')), account]));
      }
      if (owed > 0) add('Still owed to supplier', rs(owed));
      add('Vehicle / parchi', _text(d, 'vehicle'));
    case EntryType.transfer:
      add('From account', account);
      add('To account', accountName(app, '${d.data['toAccount']}', t));
    case EntryType.deposit:
      add('Received into', account);
    case EntryType.depositRefund:
      add('Paid from', account);
    case EntryType.adjustment:
      add('Applies to', adjustmentTarget(app, d, t));
      add('Meaning', adjustmentMeaning(d, t, app));
    case EntryType.stockAdjustment:
      add('Gas', _signedKg(d.value('grams')));
      if (d.data['costKnown'] == true && d.value('cost') > 0) {
        add('Cost', rs(d.value('cost')));
      } else if (d.value('grams') > 0) {
        add('Cost', t('Not known'));
      }
    case EntryType.cylinder:
      add('Size', sizeLabel(d.value('size')));
      add(
        'Cylinder movement',
        t('${d.data['cylinderMode'] ?? 'Loss / correction'}'),
      );
      if (d.value('fullDelta') != 0) {
        add('Full', _signed(d.value('fullDelta')));
      }
      if (d.value('emptyDelta') != 0) {
        add('Empty', _signed(d.value('emptyDelta')));
      }
      if (d.value('heldDelta') != 0) {
        add('Customer-held', _signed(d.value('heldDelta')));
      }
    case EntryType.historicalSale:
      add('Weight (KG)', kg(d.value('grams')));
    case EntryType.discount:
      break;
  }
  add('Note / reason', rozNote(d));
  return out;
}

/// Names a ledger account in words ("Ali Raza owes you", "Gas sales").
String postingLabel(AppController app, String key, Words t) {
  final i = key.indexOf(':');
  final kind = i < 0 ? key : key.substring(0, i);
  final id = i < 0 ? '' : key.substring(i + 1);
  return switch (kind) {
    'cogs' => t('Cost of gas sold'),
    'inventory' => t('Gas stock'),
    'ar' => t('{name} owes you').replaceAll('{name}', app.name(id)),
    'ap' => t('You owe {name}').replaceAll('{name}', app.name(id)),
    'deposit' => t(
      'Deposit held for {name}',
    ).replaceAll('{name}', app.name(id)),
    'money' => id == 'cash' ? t('Cash in hand') : accountName(app, id, t),
    'revenue' => t(id == 'bulk' ? 'Extra-KG billing' : 'Gas sales'),
    'expense' => '${t('Expense')} · ${t(id)}',
    'equity' => t('Opening balance'),
    _ => key,
  };
}

/// How a posting changes its account, with increases positive: revenue,
/// payables, deposits and equity grow on the credit side.
int postingEffect(String key, int debit) =>
    const ['revenue', 'ap', 'deposit', 'equity'].contains(key.split(':').first)
    ? -debit
    : debit;

/// What the party owed after each of its documents (document id → balance;
/// negative when you owe the party). Gives the party ledger a running balance.
/// It is the net of both sides, what the party owes you (`ar:`) less what
/// you owe it (`ap:`), so the entries of a company or an Udhari party (udhar
/// and udhar wapsi) show one too. Deposits are listed apart.
Map<String, int> partyBalances(Book book, String party) {
  final out = <String, int>{};
  var running = 0;
  for (final p in book.postings) {
    if (p.account != 'ar:$party' && p.account != 'ap:$party') continue;
    running += p.debit;
    out[p.document] = running;
  }
  return out;
}

/// What a party owes you and what you owe the party, both never negative.
/// A customer's advance counts as "pay"; an overpaid company as "receive".
/// Matches the "You will pay" side of [Book.payables].
({int receive, int pay}) partyOwed(Book book, String party) {
  final receivable = book.receivable(party), payable = book.payable(party);
  return (
    receive: (receivable > 0 ? receivable : 0) + (payable < 0 ? -payable : 0),
    pay: (payable > 0 ? payable : 0) + (receivable < 0 ? -receivable : 0),
  );
}

String balanceText(int balance, Words t) => balance > 0
    ? '${t('Owes you')} ${rs(balance)}'
    : balance < 0
    ? '${t('You owe')} ${rs(-balance)}'
    : t('Settled');
