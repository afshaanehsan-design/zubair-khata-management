import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:excel/excel.dart' as xls;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/controller.dart';
import '../../core/l10n.dart';
import '../../core/models.dart';
import '../ledger/book.dart' show Book;
import '../ledger/entry_facts.dart'
    show
        directFor,
        directHeadline,
        directTitle,
        directDestination,
        entryHeadline,
        entryTitle,
        entryTypeLabel;
import '../ledger/roznamcha.dart';

String money(int minor) => NumberFormat('#,##0.##', 'en').format(minor / 100);
String kg(int grams) => NumberFormat('#,##0.###', 'en').format(grams / 1000);

class Cell {
  final String text;
  final num? numeric;
  const Cell(this.text, [this.numeric]);
  factory Cell.amount(int minor) => Cell(money(minor), minor / 100);
  factory Cell.weight(int grams) => Cell(kg(grams), grams / 1000);
}

class Report {
  final String title;
  final String business;
  final String subtitle;
  final List<String> columns;
  final List<List<Cell>> rows;
  final List<String> notes;
  final bool urdu;
  const Report({
    required this.title,
    required this.business,
    required this.subtitle,
    required this.columns,
    required this.rows,
    this.notes = const [],
    this.urdu = false,
  });
}

const reportNames = [
  'Daily roznamcha',
  'Cash book',
  'Bank book',
  'Party statement',
  'Customer balances',
  'Overdue',
  'Udhari',
  'Daily customer balances',
  'Sales register',
  'Purchase register',
  'Office expenses',
  'Gas stock',
  'FIFO allocations',
  'Profit report',
  'Cylinder custody',
  'Deposit liabilities',
  'Audit trail',
];

Report buildReport(
  AppController app,
  String kind,
  String from,
  String to, {
  String? party,
  String? account,
  bool urdu = false,
}) {
  final t = Words(urdu), book = app.bookAt(to);
  final docs = book.documents
      .where((d) => d.date.compareTo(from) >= 0 && d.date.compareTo(to) <= 0)
      .toList();
  List<String> columns = [];
  final rows = <List<Cell>>[];
  final notes = <String>[];
  void add(List<dynamic> values) =>
      rows.add(values.map((v) => v is Cell ? v : Cell('$v')).toList());
  switch (kind) {
    case 'Overdue':
      columns = ['Name', 'Reference', 'Date', 'Due date', 'Outstanding'];
      for (final d in book.documents.where(
        (d) =>
            d.type == EntryType.sale &&
            '${d.data['dueDate'] ?? ''}'.isNotEmpty &&
            '${d.data['dueDate']}'.compareTo(to) < 0 &&
            (book.invoiceDue[d.id] ?? 0) > 0,
      )) {
        add([
          app.name(d.party),
          d.reference,
          d.date,
          d.data['dueDate'],
          Cell.amount(book.invoiceDue[d.id] ?? 0),
        ]);
      }
    case 'Cash book' || 'Bank book' || 'Party statement':
      columns = [
        'Date',
        'Reference',
        'Description',
        'Debit',
        'Credit',
        'Balance',
      ];
      if (kind != 'Party statement') {
        rows.addAll(
          _statement(
            app,
            book,
            t,
            {kind == 'Cash book' ? 'money:cash' : 'money:${account ?? ''}'},
            from,
            showParty: true,
          ),
        );
      } else {
        // One khata, like the party screen: what the party owes you (`ar:`)
        // net of what you owe it (`ap:`), with one running balance.
        String owed(int b) => b > 0
            ? '${t('Owes you')} ${money(b)}'
            : b < 0
            ? '${t('You owe')} ${money(-b)}'
            : t('Settled');
        rows.addAll(
          _statement(
            app,
            book,
            t,
            {'ar:${party ?? ''}', 'ap:${party ?? ''}'},
            from,
            khata: party,
            balance: (b) => Cell(owed(b), b / 100),
          ),
        );
        // Deposits are refundable, not part of what is owed: their own
        // section, and only for a party that has any.
        final deposit = _statement(
          app,
          book,
          t,
          {'deposit:${party ?? ''}'},
          from,
          sign: -1,
        );
        if (deposit.isNotEmpty) {
          add(['', '', t('Refundable deposit'), '', '', '']);
          rows.addAll(deposit);
        }
      }
    case 'Daily customer balances':
      columns = [
        'Date',
        'Name',
        'Phone',
        'Opening',
        'Cylinder billing',
        'Extra-KG billing',
        'Cash',
        'Bank',
        'Direct to party',
        'Closing',
      ];
      final dates = {from, to, ...docs.map((d) => d.date)}.toList()..sort();
      for (final date in dates) {
        final opening = app.bookAt(
          DateTime.parse(date)
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10),
        );
        final closing = app.bookAt(date);
        for (final p in app.ofKind('party', archived: true)) {
          final activity = docs.where((d) => d.date == date && d.party == p.id);
          add([
            date,
            p.name,
            p.data['phone'] ?? '',
            Cell.amount(opening.receivable(p.id)),
            Cell.amount(
              activity
                  .where((d) => d.type == EntryType.sale)
                  .fold(0, (v, d) => v + d.cylinderRevenue),
            ),
            Cell.amount(
              activity
                  .where((d) => d.type == EntryType.sale)
                  .fold(0, (v, d) => v + d.bulkRevenue),
            ),
            Cell.amount(activity.fold(0, (v, d) => v + d.value('cash'))),
            Cell.amount(activity.fold(0, (v, d) => v + d.bankIn)),
            Cell.amount(activity.fold(0, (v, d) => v + d.direct)),
            Cell.amount(closing.receivable(p.id)),
          ]);
        }
      }
    case 'Customer balances' || 'Udhari':
      columns = [
        'Name',
        'Phone',
        if (kind == 'Daily customer balances') 'Opening',
        'Receivable',
        'Payable',
        'Refundable deposit',
      ];
      final before = app.bookAt(
        DateTime.parse(from)
            .subtract(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10),
      );
      for (final p in app.ofKind('party', archived: true)) {
        if (kind == 'Udhari' && p.data['udhari'] != true) continue;
        add([
          p.name,
          p.data['phone'] ?? '',
          if (kind == 'Daily customer balances')
            Cell.amount(before.receivable(p.id)),
          Cell.amount(book.receivable(p.id)),
          Cell.amount(book.payable(p.id)),
          Cell.amount(book.deposits(p.id)),
        ]);
      }
    case 'Sales register':
      columns = [
        'Date',
        'Reference',
        'Name',
        'KG sold',
        'Cylinder billing',
        'Extra-KG billing',
        'Bill total',
        'Cash',
        'Bank',
        'Direct to party',
        'Balance',
      ];
      for (final d in docs.where(
        (d) => [
          EntryType.sale,
          EntryType.historicalSale,
          EntryType.creditNote,
        ].contains(d.type),
      )) {
        final sign = d.type == EntryType.creditNote ? -1 : 1;
        add([
          d.date,
          d.reference,
          app.name(d.party),
          Cell.weight(
            d.type == EntryType.historicalSale
                ? d.value('grams')
                : d.type == EntryType.creditNote &&
                      d.data['stockReturned'] != true
                ? 0
                : sign * d.cylinderGrams,
          ),
          Cell.amount(
            sign *
                (d.type == EntryType.historicalSale
                    ? d.total
                    : d.cylinderRevenue),
          ),
          Cell.amount(sign * d.bulkRevenue),
          Cell.amount(sign * d.total),
          Cell.amount(d.value('cash')),
          Cell.amount(d.bankIn),
          Cell.amount(d.direct),
          Cell.amount(book.invoiceDue[d.id] ?? 0),
        ]);
      }
    case 'Purchase register':
      columns = [
        'Date',
        'Reference',
        'Name',
        'Vehicle / parchi',
        'Weight (KG)',
        'Rate',
        'Bill total',
        'Paid now',
      ];
      for (final d in docs.where((d) => d.type == EntryType.purchase)) {
        add([
          d.date,
          d.reference,
          app.name(d.party),
          d.data['vehicle'] ?? '',
          Cell.weight(d.value('grams')),
          Cell.amount(d.rate),
          Cell.amount(d.purchaseBill),
          Cell.amount(d.value('amount')),
        ]);
      }
    case 'Office expenses':
      columns = ['Date', 'Reference', 'Description', 'From account', 'Amount'];
      for (final d in docs.where(
        (d) => d.type == EntryType.expense && d.data['category'] == 'Office',
      )) {
        add([
          d.date,
          d.reference,
          d.note,
          app.name(d.account),
          Cell.amount(d.total),
        ]);
      }
    case 'Gas stock':
      columns = ['Date', 'Reference', 'Description', 'Weight (KG)', 'Balance'];
      var running = app
          .bookAt(
            DateTime.parse(from)
                .subtract(const Duration(days: 1))
                .toIso8601String()
                .substring(0, 10),
          )
          .gasGrams;
      final opening = running;
      for (final d in docs) {
        final change = switch (d.type) {
          EntryType.purchase || EntryType.stockAdjustment => d.value('grams'),
          EntryType.sale => -d.cylinderGrams,
          EntryType.creditNote =>
            d.data['stockReturned'] == true ? d.cylinderGrams : 0,
          EntryType.historicalSale => -d.value('grams'),
          _ => 0,
        };
        if (change != 0) {
          running += change;
          add([
            d.date,
            d.reference,
            t(entryLabel(d.type.name)),
            Cell.weight(change),
            Cell.weight(running),
          ]);
        }
      }
      // Newest first, with the stock brought forward (if any) at the bottom.
      final entries = rows.reversed.toList();
      rows
        ..clear()
        ..addAll(entries);
      if (opening != 0) add([from, '', t('Opening'), '', Cell.weight(opening)]);
    case 'FIFO allocations':
      columns = ['Sale reference', 'Purchase lot', 'Weight (KG)', 'Cost'];
      for (final a in book.allocations.where(
        (a) => docs.any((d) => d.id == a.sale),
      )) {
        add([
          app.record(a.sale) == null
              ? a.sale
              : Document(app.record(a.sale)!).reference,
          Document(app.record(a.lot)!).reference,
          Cell.weight(a.grams),
          Cell.amount(a.cost),
        ]);
      }
      for (final e in book.uncostedSales.entries.where(
        (e) => docs.any((d) => d.id == e.key),
      )) {
        add([
          Document(app.record(e.key)!).reference,
          t('Unvalued quantity'),
          Cell.weight(e.value),
          '—',
        ]);
      }
    case 'Profit report':
      columns = ['Description', 'Amount'];
      final ids = docs.map((d) => d.id).toSet();
      int sum(String prefix) => book.postings
          .where(
            (p) => ids.contains(p.document) && p.account.startsWith(prefix),
          )
          .fold(0, (v, p) => v + p.debit);
      final sales = -sum('revenue:gas'),
          cogs = sum('cogs'),
          expense = sum('expense:');
      add([t('Cylinder billing'), Cell.amount(sales)]);
      add([t('Cost of gas sold'), Cell.amount(cogs)]);
      add([t('Gross profit'), Cell.amount(sales - cogs)]);
      add([t('Operating expenses'), Cell.amount(expense)]);
      add([t('Net profit'), Cell.amount(sales - cogs - expense)]);
      add([t('Extra-KG billing'), Cell.amount(-sum('revenue:bulk'))]);
      if (book.profitIncomplete) {
        notes.add(
          t(
            'Uncosted stock and extra-KG billing are excluded from complete profit.',
          ),
        );
      }
    case 'Cylinder custody':
      columns = ['Name', 'Size', 'Full', 'Empty', 'Customer-held'];
      for (final size in sizes) {
        add([
          t('Stock'),
          sizeLabel(size),
          book.full['$size'] ?? 0,
          book.empty['$size'] ?? 0,
          '',
        ]);
      }
      for (final p in app.ofKind('party', archived: true)) {
        for (final size in sizes) {
          if ((book.held['${p.id}:$size'] ?? 0) != 0) {
            add([p.name, sizeLabel(size), '', '', book.held['${p.id}:$size']]);
          }
        }
      }
    case 'Deposit liabilities':
      columns = ['Name', 'Phone', 'Refundable deposit'];
      for (final p in app.ofKind('party', archived: true)) {
        add([p.name, p.data['phone'] ?? '', Cell.amount(book.deposits(p.id))]);
      }
    case 'Audit trail':
      columns = ['Date', 'Reference', 'Description', 'Note / reason'];
      final remoteIds = <String>{};
      for (final a in app.ofKind('audit')) {
        remoteIds.add('${a.data['command_id']}');
        add([
          a.data['receivedAt'],
          a.data['command_id'],
          '${a.data['action']} · ${a.data['device']}',
          a.data['reason'] ?? '',
        ]);
      }
      for (final c in app.commands) {
        if (remoteIds.contains(c.id)) continue;
        add([
          DateTime.fromMicrosecondsSinceEpoch(c.created).toIso8601String(),
          c.id,
          '${c.action} · ${c.status}',
          c.reason,
        ]);
      }
    case 'Daily roznamcha':
      // Printed like the original page: A (Aamad), B (Kharcha), Safi Baqaya.
      columns = ['Date', 'Reference', 'Description', 'Name', 'Amount'];
      final cash = book.ledger('money:cash');
      String name(Document d) => d.party.isEmpty ? '' : app.name(d.party);
      String join(List<String> parts) =>
          parts.where((p) => p.trim().isNotEmpty).join(' · ');
      for (final date in docs.map((d) => d.date).toSet().toList()..sort()) {
        final opening = cash
            .where((p) => p.date.compareTo(date) < 0)
            .fold(0, (v, p) => v + p.debit);
        final day = RoznamchaDay(
          date,
          opening,
          docs.where((d) => d.date == date),
        );
        add([date, '', t('A: Aamad / Wasooli'), '', '']);
        for (final d in day.aamad) {
          final deposit = d.type == EntryType.deposit;
          final cashIn = deposit
              ? (d.account == 'cash' ? d.value('amount') : 0)
              : d.value('cash');
          final bankIn = deposit
              ? (d.account == 'cash' ? 0 : d.value('amount'))
              : d.bankIn;
          add([
            date,
            d.reference,
            join([
              t(
                rozFormOf(d) == RozForm.companyIn
                    ? 'Company se Wasooli'
                    : deposit
                    ? 'Deposit'
                    : 'Wasooli / Sale',
              ),
              if ('${d.data['vehicle'] ?? ''}'.isNotEmpty)
                '${t('Parchi')} ${d.data['vehicle']}',
              for (final s in sizes)
                if (integer((d.data['quantities'] as Map?)?['$s']) > 0)
                  '${sizeLabel(s)} × ${integer((d.data['quantities'] as Map?)?['$s'])}',
              if (d.extraGrams > 0) '${t('Bulk')} ${kg(d.extraGrams)} KG',
              if (d.type == EntryType.sale)
                '${t('Rate')} ${money(d.rate)} · ${t('Bill')} ${money(d.total)}',
              if (cashIn > 0) '${t('Cash')} ${money(cashIn)}',
              if (deposit && bankIn > 0)
                '${t('Bank')} ${money(bankIn)} (${app.name(d.account)})',
              for (final l in d.bankLines)
                l.direct
                    ? '${t('Direct to party')} ${money(l.amount)} (${directDestination(app, l)})'
                    : '${t('Bank')} ${money(l.amount)} (${app.name(l.account)})',
              d.note,
            ]),
            name(d),
            Cell.amount(cashIn + bankIn + d.direct),
          ]);
        }
        for (final d in day.nikali) {
          add([
            date,
            d.reference,
            join([t('Bank se Nikali'), app.name(d.account), d.note]),
            '',
            Cell.amount(d.value('amount')),
          ]);
        }
        for (final d in day.less) {
          final bank = d.type == EntryType.receipt;
          add([
            date,
            d.reference,
            join([
              t('Less / Kami'),
              t(
                bank
                    ? 'Bank deposit (account mein jama)'
                    : 'Khata se minus (discount)',
              ),
              if (bank) app.name(d.bankAccount),
              d.note,
            ]),
            name(d),
            Cell.amount(
              -(bank ? d.value('cash') + d.bankIn : d.value('amount')),
            ),
          ]);
        }
        for (final d in day.openings) {
          final target = '${d.data['target'] ?? ''}';
          final id = target.substring(target.indexOf(':') + 1);
          add([
            date,
            d.reference,
            join([
              t(isOpeningBalance(d) ? 'Opening balance' : 'Adjustment'),
              rozNote(d),
            ]),
            app.name(id),
            Cell.amount(
              target.startsWith('ap:') ? -d.value('amount') : d.value('amount'),
            ),
          ]);
        }
        add([
          date,
          '',
          t(
            day.direct > 0
                ? 'Aaj ki Wasooli (cash + bank + direct)'
                : 'Aaj ki Wasooli (cash + bank)',
          ),
          '',
          Cell.amount(day.wasooli),
        ]);
        add([
          date,
          '',
          t('Opening (sabiqa) + Bank se Nikali'),
          '',
          Cell.amount(day.opening + day.cashAdj + day.wd),
        ]);
        add([
          date,
          '',
          t('Kul Aamad (Wasooli + Opening + Nikali)'),
          '',
          Cell.amount(day.left),
        ]);
        add([date, '', t('B: Kharcha'), '', '']);
        for (final d in day.kharcha) {
          add([
            date,
            d.reference,
            join([
              t(rozTypeLabel(d)),
              d.note,
              if (d.account != 'cash')
                '[${t('Bank se')}: ${app.name(d.account)}]',
            ]),
            name(d),
            Cell.amount(d.value('amount')),
          ]);
        }
        for (final l in day.bankJama) {
          add([
            date,
            l.document.reference,
            l.automatic
                ? '${t('Bank jama')} · ${t('Wasooli')} — ${name(l.document)} → ${app.name(l.account)}'
                : join([
                    '${t('Bank jama')} → ${app.name(l.account)}',
                    l.document.note,
                  ]),
            app.name(l.account),
            Cell.amount(l.amount),
          ]);
        }
        // Paid by a customer straight to a party: in B like the automatic
        // bank jama, so A − B is still the cash in hand.
        for (final l in day.directLines) {
          final d = l.document;
          final destination = join([app.name(l.party), l.bankName]);
          add([
            date,
            d.reference,
            '${t('Direct to party')} · ${t('Wasooli')} — ${name(d)} → $destination',
            destination,
            Cell.amount(l.amount),
          ]);
        }
        add([
          date,
          '',
          t(
            day.direct > 0
                ? 'Kul Kharcha + Bank Jama + Direct'
                : 'Kul Kharcha + Bank Jama',
          ),
          '',
          Cell.amount(day.rightTotal),
        ]);
        add([
          date,
          '',
          t('Safi Baqaya = A − B (Cash in Hand)'),
          '',
          Cell.amount(day.safi),
        ]);
        if (day.kharchaBank > 0) {
          add([
            date,
            '',
            t('Bank se diye kharcha (sirf bank ghata, cash par asar nahi)'),
            '',
            Cell.amount(day.kharchaBank),
          ]);
        }
        for (final d in day.other) {
          add([
            date,
            d.reference,
            t(entryLabel(d.type.name)),
            name(d),
            Cell.amount(d.total == 0 ? d.collected : d.total),
          ]);
        }
      }
    default:
      columns = [
        'Date',
        'Reference',
        'Description',
        'Name',
        'Amount',
        'Cash',
        'Bank',
        'Note / reason',
      ];
      for (final d in docs) {
        add([
          d.date,
          d.reference,
          t(entryLabel(d.type.name)),
          app.name(d.party),
          Cell.amount(d.total == 0 ? d.collected : d.total),
          Cell.amount(
            book.postings
                .where((p) => p.document == d.id && p.account == 'money:cash')
                .fold(0, (v, p) => v + p.debit),
          ),
          Cell.amount(
            book.postings
                .where(
                  (p) =>
                      p.document == d.id &&
                      p.account.startsWith('money:') &&
                      p.account != 'money:cash',
                )
                .fold(0, (v, p) => v + p.debit),
          ),
          d.note,
        ]);
      }
  }
  final totals = switch (kind) {
    'Sales register' => [3, 4, 5, 6, 7, 8, 9, 10],
    'Purchase register' => [4, 6, 7],
    'Customer balances' || 'Udhari' => [2, 3, 4],
    'Office expenses' => [4],
    'Deposit liabilities' => [2],
    _ => <int>[],
  };
  if (totals.isNotEmpty && rows.isNotEmpty) {
    add([
      for (var i = 0; i < columns.length; i++)
        if (i == 0)
          t('Total')
        else if (totals.contains(i))
          Cell(
            NumberFormat(
              '#,##0.###',
              'en',
            ).format(rows.fold<num>(0, (v, r) => v + (r[i].numeric ?? 0))),
            rows.fold<num>(0, (v, r) => v + (r[i].numeric ?? 0)),
          )
        else
          '',
    ]);
  }
  return Report(
    title: t(kind),
    business: app.businessName,
    subtitle:
        '$from — $to${party == null ? '' : ' · ${app.name(party)}'}${account == null ? '' : ' · ${app.name(account)}'}',
    columns: columns.map(t.call).toList(),
    rows: rows,
    notes: notes,
    urdu: urdu,
  );
}

/// The rows of a running-balance statement over [accounts], newest first:
/// one row per document, its postings summed into Debit and Credit, then a
/// single Opening row with the balance brought forward from before [from],
/// left out when it is 0. Balances are shown times [sign], so −1 reads a
/// credit balance (deposits held) as positive. Empty when there is nothing
/// to show.
List<List<Cell>> _statement(
  AppController app,
  Book book,
  Words t,
  Set<String> accounts,
  String from, {
  int sign = 1,
  bool showParty = false,
  String? khata,
  Cell Function(int balance) balance = Cell.amount,
}) {
  var opening = 0;
  final groups = <String, (int, int)>{};
  for (final p in book.postings) {
    if (!accounts.contains(p.account)) continue;
    if (p.date.compareTo(from) < 0) {
      opening += p.debit;
      continue;
    }
    final (debit, credit) = groups[p.document] ?? (0, 0);
    groups[p.document] = p.debit >= 0
        ? (debit + p.debit, credit)
        : (debit, credit - p.debit);
  }
  final byId = {for (final d in book.documents) d.id: d};
  Cell amount(int v) => v == 0 ? const Cell('') : Cell.amount(v);
  final rows = <List<Cell>>[];
  var running = opening;
  for (final MapEntry(key: id, value: (debit, credit)) in groups.entries) {
    final d = byId[id]!;
    running += debit - credit;
    rows.add([
      Cell(d.date),
      Cell(d.reference),
      Cell(_statementText(app, d, t, showParty: showParty, khata: khata)),
      amount(debit),
      amount(credit),
      balance(sign * running),
    ]);
  }
  return [
    ...rows.reversed,
    if (opening != 0)
      [
        Cell(from),
        const Cell(''),
        Cell(t('Opening')),
        const Cell(''),
        const Cell(''),
        balance(sign * opening),
      ],
  ];
}

/// What a statement row is: the kind of entry, who or what it is about (in
/// a cash or bank book), what it contained and its note.
String _statementText(
  AppController app,
  Document d,
  Words t, {
  required bool showParty,
  String? khata,
}) {
  // In the khata of a party that a customer paid directly, the row is that
  // payment, not the customer's sale or receipt.
  if (directFor(d, khata)) {
    return [
      directTitle(t),
      directHeadline(app, d, khata!, t),
      rozNote(d),
    ].where((s) => s.isNotEmpty).join(' · ');
  }
  final type = entryTypeLabel(d, t), title = entryTitle(app, d, t);
  return [
    type,
    if (showParty && title != type) title,
    entryHeadline(app, d, t),
    // An adjustment's headline already ends with its note.
    if (d.type != EntryType.adjustment) rozNote(d),
  ].where((s) => s.isNotEmpty).join(' · ');
}

Report snapshotReport(AppController app, Record snapshot, {bool urdu = false}) {
  final t = Words(urdu);
  final docs = (snapshot.data['documents'] as List).map(
    (v) => Document(Record.fromJson(Map<String, dynamic>.from(v as Map))),
  );
  return Report(
    title: t('Daily roznamcha'),
    business: app.businessName,
    subtitle: '${snapshot.data['date']} · ${snapshot.data['savedAt']}',
    columns: [
      'Reference',
      'Description',
      'Name',
      'Amount',
      'Cash',
      'Bank',
      'Note / reason',
    ].map(t.call).toList(),
    rows: [
      for (final d in docs)
        [
          Cell(d.reference),
          Cell(t(entryLabel(d.type.name))),
          Cell(app.name(d.party)),
          Cell.amount(d.total == 0 ? d.collected : d.total),
          Cell.amount(d.value('cash')),
          Cell.amount(d.bankIn),
          Cell(d.note),
        ],
    ],
    urdu: urdu,
  );
}

Report invoiceReport(AppController app, Document d, {bool urdu = false}) {
  final t = Words(urdu), rows = <List<Cell>>[];
  void total(String label, int amount, {String detail = ''}) => rows.add([
    Cell(t(label)),
    Cell(detail),
    const Cell(''),
    const Cell(''),
    Cell.amount(amount),
  ]);
  if (d.type == EntryType.sale) {
    for (final line in d.saleLines) {
      rows.add([
        Cell(sizeLabel(line.size)),
        Cell('${line.count}', line.count),
        Cell.weight(line.grams),
        Cell.amount(d.rate),
        Cell.amount(line.amount),
      ]);
    }
    if (d.lineRounding != 0) total('Rounding', d.lineRounding);
    if (d.extraGrams > 0) {
      rows.add([
        Cell(t('Extra KG (billing only)')),
        const Cell(''),
        Cell.weight(d.extraGrams),
        Cell.amount(d.rate),
        Cell.amount(d.bulkRevenue),
      ]);
    }
    if (d.value('depositCharge') != 0) {
      total('Deposit charged', d.value('depositCharge'));
    }
    total('Bill total', d.total);
    total('Cash received', d.value('cash'));
    for (final l in d.bankLines) {
      total(
        l.direct ? 'Paid directly to party' : 'Bank received',
        l.amount,
        detail: l.direct ? directDestination(app, l) : app.name(l.account),
      );
    }
    total('Outstanding', app.book.invoiceDue[d.id] ?? 0);
  } else {
    total(entryLabel(d.type.name), d.total == 0 ? d.collected : d.total);
    if (d.type == EntryType.receipt) {
      total('Cash received', d.value('cash'));
      for (final l in d.bankLines) {
        total(
          l.direct ? 'Paid directly to party' : 'Bank received',
          l.amount,
          detail: l.direct ? directDestination(app, l) : app.name(l.account),
        );
      }
    }
  }
  return Report(
    title:
        '${t(d.type == EntryType.creditNote ? 'Credit note' : 'Invoice / receipt')} ${d.reference}',
    business: app.businessName,
    subtitle:
        '${d.date} · ${app.name(d.party)} · ${app.record(d.party)?.data['phone'] ?? ''}',
    columns: [
      'Description',
      'Quantity',
      'Weight (KG)',
      'Rate per 11.8 KG',
      'Amount',
    ].map(t.call).toList(),
    rows: rows,
    notes: [
      if (d.note.isNotEmpty) d.note,
      if ('${d.data['vehicle'] ?? ''}'.isNotEmpty)
        '${t('Vehicle / parchi')}: ${d.data['vehicle']}',
      if ('${d.data['dueDate'] ?? ''}'.isNotEmpty)
        '${t('Due date')}: ${d.data['dueDate']}',
      if ('${app.settings['address'] ?? ''}'.isNotEmpty)
        '${app.settings['address']}',
      if ('${app.settings['phone'] ?? ''}'.isNotEmpty)
        '${app.settings['phone']}',
      if (d.voided) t('Voided'),
    ],
    urdu: urdu,
  );
}

abstract interface class PdfTextRenderer {
  Future<pw.Widget> render(String text, double width, {double fontSize = 9});
}

/// Flutter shapes the original Unicode paragraph; only complex text is rasterized.
class UrduPdfRenderer implements PdfTextRenderer {
  final pw.Font? latinFont;
  final bool rtl;
  UrduPdfRenderer({this.latinFont, this.rtl = false});
  final Map<String, pw.Widget> _cache = {};
  @override
  Future<pw.Widget> render(
    String text,
    double width, {
    double fontSize = 9,
  }) async {
    if (!RegExp(r'[\u0600-\u08ff\ufb50-\ufdff\ufe70-\ufeff]').hasMatch(text)) {
      return pw.Text(
        text,
        style: pw.TextStyle(fontSize: fontSize, font: latinFont),
        textAlign: rtl || RegExp(r'^-?[\d,.]+$').hasMatch(text)
            ? pw.TextAlign.right
            : pw.TextAlign.left,
        softWrap: true,
      );
    }
    final key = '$text|$width|$fontSize';
    if (_cache.containsKey(key)) return _cache[key]!;
    final painter =
        TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontFamily: 'NotoUrdu',
              fontSize: fontSize,
              height: 1.9,
              color: Colors.black,
            ),
          ),
          textDirection: TextDirection.rtl,
          locale: const Locale('ur'),
        )..layout(
          minWidth: math.max(16, width - 8),
          maxWidth: math.max(16, width - 8),
        );
    final recorder = ui.PictureRecorder(), canvas = Canvas(recorder);
    const scale = 300 / 72;
    final height = painter.height + fontSize * 2;
    canvas.scale(scale);
    painter.paint(canvas, Offset(4, fontSize / 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (width * scale).ceil(),
      (height * scale).ceil(),
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final result = pw.Image(
      pw.MemoryImage(png!.buffer.asUint8List()),
      width: width,
      height: height,
    );
    image.dispose();
    picture.dispose();
    painter.dispose();
    _cache[key] = result;
    return result;
  }
}

class ReportCancelled implements Exception {}

const _gridLine = PdfColor.fromInt(0xffa9b8b2);
const _gridOuter = PdfColor.fromInt(0xff7f918a);

class ReportExporter {
  bool cancelled = false;
  final void Function(double)? progress;
  ReportExporter({this.progress});
  Future<Uint8List> pdf(Report report) async {
    final latinFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Manrope.ttf'),
    );
    final renderer = UrduPdfRenderer(latinFont: latinFont, rtl: report.urdu);
    final landscape = report.columns.length > 6;
    final format = landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
    final available = format.width - 56;
    final width = available / report.columns.length;
    final tableRows = <pw.TableRow>[];
    Future<pw.TableRow> row(List<String> cells, {bool header = false}) async {
      final widgets = <pw.Widget>[];
      for (final cell in (report.urdu ? cells.reversed : cells)) {
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.all(4),
            child: await renderer.render(
              cell,
              width - 8,
              fontSize: header ? 9 : 8,
            ),
          ),
        );
      }
      return pw.TableRow(
        repeat: header,
        decoration: header
            ? const pw.BoxDecoration(color: PdfColor.fromInt(0xffe0efeb))
            : null,
        children: widgets,
      );
    }

    tableRows.add(await row(report.columns, header: true));
    for (var index = 0; index < report.rows.length; index++) {
      if (cancelled) throw ReportCancelled();
      // Bound each physical row. Continued cells keep long notes printable.
      final fragments = report.rows[index]
          .map((c) => _chunks(c.text, width))
          .toList();
      final count = fragments.fold(1, (n, p) => math.max(n, p.length));
      for (var part = 0; part < count; part++) {
        tableRows.add(
          await row(
            fragments.map((p) => part < p.length ? p[part] : '').toList(),
          ),
        );
      }
      progress?.call((index + 1) / math.max(1, report.rows.length));
      if (index % 15 == 0) await Future<void>.delayed(Duration.zero);
    }
    final heading = await renderer.render(
      report.business,
      available,
      fontSize: 17,
    );
    final title = await renderer.render(report.title, available, fontSize: 12);
    final subtitle = await renderer.render(
      report.subtitle,
      available,
      fontSize: 9,
    );
    final noteWidgets = <pw.Widget>[];
    for (final note in report.notes) {
      noteWidgets.add(await renderer.render(note, available));
    }
    final doc = pw.Document(
      title: report.title,
      author: report.business,
      theme: pw.ThemeData.withFont(base: latinFont, bold: latinFont),
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(28),
        maxPages: 10000,
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            heading,
            title,
            pw.SizedBox(height: 6),
            subtitle,
            pw.SizedBox(height: 12),
          ],
        ),
        footer: (context) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Zubair Khata · PKR',
              style: const pw.TextStyle(fontSize: 8),
            ),
            pw.Text(
              '${context.pageNumber} / ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ],
        ),
        build: (_) => [
          pw.Table(
            // An Excel-like grid: a line between every row and every column,
            // heavy enough to survive PdfPreview's on-screen rasterising.
            border: const pw.TableBorder(
              left: pw.BorderSide(color: _gridOuter, width: 1),
              right: pw.BorderSide(color: _gridOuter, width: 1),
              top: pw.BorderSide(color: _gridOuter, width: 1),
              bottom: pw.BorderSide(color: _gridOuter, width: 1),
              horizontalInside: pw.BorderSide(color: _gridLine, width: .75),
              verticalInside: pw.BorderSide(color: _gridLine, width: .75),
            ),
            columnWidths: {
              for (var i = 0; i < report.columns.length; i++)
                i: pw.FixedColumnWidth(width),
            },
            children: tableRows,
          ),
          pw.SizedBox(height: 12),
          ...noteWidgets,
        ],
      ),
    );
    return doc.save();
  }

  List<String> _chunks(String text, double width) {
    // Measure through Flutter to respect Nastaliq shaping and final column width.
    final rtl = RegExp(r'[\u0600-\u08ff]').hasMatch(text);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: rtl ? 'NotoUrdu' : null,
          fontSize: 8,
          height: rtl ? 1.9 : 1.2,
        ),
      ),
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    )..layout(maxWidth: math.max(16, width - 16));
    final lines = painter.computeLineMetrics();
    if (painter.height < 240 || lines.isEmpty) {
      painter.dispose();
      return [text];
    }
    final result = <String>[];
    var start = 0;
    double top = 0;
    for (final line in lines) {
      if (line.baseline - top > 200) {
        final position = painter.getPositionForOffset(
          Offset(rtl ? width : 0, line.baseline - line.ascent),
        );
        final boundary = painter.getLineBoundary(position).start;
        if (boundary > start) {
          result.add(text.substring(start, boundary));
          start = boundary;
          top = line.baseline;
        }
      }
    }
    if (start < text.length) result.add(text.substring(start));
    painter.dispose();
    return result;
  }

  Uint8List excel(Report report) {
    final workbook = xls.Excel.createExcel();
    final sheet = workbook['Report'];
    workbook.delete('Sheet1');
    sheet.appendRow([xls.TextCellValue(report.business)]);
    sheet.appendRow([xls.TextCellValue(report.title)]);
    sheet.appendRow([xls.TextCellValue(report.subtitle)]);
    sheet.appendRow(report.columns.map(xls.TextCellValue.new).toList());
    for (final row in report.rows) {
      sheet.appendRow(
        row
            .map(
              (c) => c.numeric == null
                  ? xls.TextCellValue(c.text)
                  : xls.DoubleCellValue(c.numeric!.toDouble()),
            )
            .toList(),
      );
    }
    for (final note in report.notes) {
      sheet.appendRow([xls.TextCellValue(note)]);
    }
    return Uint8List.fromList(workbook.encode()!);
  }

  String csv(Report report) {
    String escape(String value) => '"${value.replaceAll('"', '""')}"';
    // Prefix potential spreadsheet formula text, while preserving typed amounts.
    String safe(Cell c) =>
        c.numeric == null && RegExp(r'^[=+\-@\t\r]').hasMatch(c.text)
        ? "'${c.text}"
        : c.text;
    return '\uFEFF${[report.columns, ...report.rows.map((r) => r.map(safe).toList())].map((r) => r.map(escape).join(',')).join('\r\n')}';
  }

  Uint8List csvBytes(Report report) =>
      Uint8List.fromList(utf8.encode(csv(report)));
}
