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
import 'report_sheet.dart';
import 'roznamcha_sheet.dart';

String money(int minor) => NumberFormat('#,##0.##', 'en').format(minor / 100);
String kg(int grams) => NumberFormat('#,##0.###', 'en').format(grams / 1000);

/// Whether [text] has Urdu (Arabic-script) letters.
bool hasUrduScript(String text) => UrduPdfRenderer._script.hasMatch(text);

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

  /// Indexes of [rows] that head a section (the Roznamcha's Overview, A and
  /// B). The PDF and the on-screen table shade them.
  final Set<int> sections;

  /// More than 1 prints the PDF like the business's paper sheets: that many
  /// narrow grids side by side on each page, with one-line rows of a fixed
  /// height that fill the first grid, then the next (pending balances). The
  /// first column is a centred row number; [notes] go under the last grids.
  final int grids;

  /// Relative column widths inside one grid; equal when empty.
  final List<double> flex;

  /// Days of the Roznamcha printed like the original page's history sheet
  /// (`roznamcha_sheet.dart`), or the Money page's statement in the same
  /// design ([moneyReport]). When there are any, the PDF is these sheets;
  /// the table, Excel and CSV still use [columns] and [rows].
  final List<RozSheet> sheets;
  final bool compact;

  /// Rebuild only the printed sheets when switching the PDF preview mode.
  final List<RozSheet> Function(bool)? roznamchaSheets;

  /// What the PDF preview calls the switch that sets [compact]: Compact for
  /// the Roznamcha, Details for the day's pending balances.
  final String sheetSwitch;

  /// Which report this is, in English whatever the language ('Party
  /// statement', 'Pending balances', 'Invoice'...). The PDF preview remembers
  /// its size slider by it ([AppController.pdfSize]).
  final String kind;
  const Report({
    required this.title,
    required this.business,
    required this.subtitle,
    required this.columns,
    required this.rows,
    this.notes = const [],
    this.urdu = false,
    this.sections = const {},
    this.grids = 1,
    this.flex = const [],
    this.sheets = const [],
    this.compact = false,
    this.roznamchaSheets,
    this.sheetSwitch = 'Compact',
    this.kind = '',
  });

  Report withCompact(bool value) => Report(
    title: title,
    business: business,
    subtitle: subtitle,
    columns: columns,
    rows: rows,
    notes: notes,
    urdu: urdu,
    sections: sections,
    grids: grids,
    flex: flex,
    sheets: roznamchaSheets?.call(value) ?? sheets,
    compact: value,
    roznamchaSheets: roznamchaSheets,
    sheetSwitch: sheetSwitch,
    kind: kind,
  );
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
  'Purchase shares',
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
  final sections = <int>{};
  final sheets = <RozSheet>[];
  List<RozSheet> Function(bool)? roznamchaSheets;
  void add(List<dynamic> values) =>
      rows.add(values.map((v) => v is Cell ? v : Cell('$v')).toList());
  void section(String date, String label) {
    sections.add(rows.length);
    add([date, '', label, '', '']);
  }

  // The PDF, in the Roznamcha sheet's design (report_sheet.dart): the
  // heading starts with [dates] and [subject], then [heading]; the summary
  // row is [figures]; [tables] are the sheet's tables, or else one table of
  // [columns] and [rows] (with [bold] columns, and without the rows whose
  // figures are all 0 when [skipZero]) under the Total row, if any.
  final figures = <SheetFigure>[], heading = <String>[];
  var dates = sheetRange(from, to), subject = '';
  List<SheetTable>? tables;
  var bold = <int>{};
  var skipZero = false;
  String rs(int minor) => 'Rs. ${money(minor)}';
  String entries(int count) => '${t('Entries')} $count';
  List<String> translated(List<String> labels) => labels.map(t.call).toList();

  switch (kind) {
    case 'Overdue':
      columns = ['Name', 'Reference', 'Date', 'Due date', 'Outstanding'];
      var due = 0;
      for (final d in book.documents.where(
        (d) =>
            d.type == EntryType.sale &&
            '${d.data['dueDate'] ?? ''}'.isNotEmpty &&
            '${d.data['dueDate']}'.compareTo(to) < 0 &&
            (book.invoiceDue[d.id] ?? 0) > 0,
      )) {
        due += book.invoiceDue[d.id] ?? 0;
        add([
          app.name(d.party),
          d.reference,
          d.date,
          d.data['dueDate'],
          Cell.amount(book.invoiceDue[d.id] ?? 0),
        ]);
      }
      dates = rozDmy(to);
      bold = {0, 4};
      figures.add(
        SheetFigure(t('Outstanding'), rs(due), [entries(rows.length)]),
      );
      heading.add('${t('Outstanding')}: ${rs(due)}');
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
        final id = kind == 'Cash book' ? 'cash' : account ?? '';
        final s = _statement(
          app,
          book,
          t,
          {'money:$id'},
          from,
          showParty: true,
        );
        rows.addAll(s.rows);
        final bank = id == 'cash'
            ? ''
            : '${app.record(id)?.data['bank'] ?? ''}'.trim();
        subject = [
          id == 'cash' ? t('Cash') : app.name(id),
          bank,
        ].where((s) => s.isNotEmpty).join(' · ');
        figures.addAll([
          SheetFigure(t('Opening'), rs(s.start)),
          SheetFigure(t('Money in'), rs(s.debit)),
          SheetFigure(t('Money out'), rs(s.credit)),
          SheetFigure(t('Closing'), rs(s.end), [entries(s.entries.length)]),
        ]);
        heading.add('${t('Closing')}: ${rs(s.end)}');
        tables = [
          reportTable(
            t,
            title: subject,
            columns: translated(columns),
            rows: s.entries,
            after: [?s.opening],
            total: [
              Cell(t('Total')),
              const Cell(''),
              const Cell(''),
              Cell.amount(s.debit),
              Cell.amount(s.credit),
              Cell.amount(s.end),
            ],
            bold: {5},
          ),
        ];
      } else {
        // One khata, like the party screen: what the party owes you (`ar:`)
        // net of what you owe it (`ap:`), with one running balance.
        String owed(int b) => b > 0
            ? '${t('Owes you')} ${money(b)}'
            : b < 0
            ? '${t('You owe')} ${money(-b)}'
            : t('Settled');
        Cell owedCell(int b) => Cell(owed(b), b / 100);
        final s = _statement(
          app,
          book,
          t,
          {'ar:${party ?? ''}', 'ap:${party ?? ''}'},
          from,
          khata: party,
          balance: owedCell,
        );
        rows.addAll(s.rows);
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
        if (deposit.rows.isNotEmpty) {
          add(['', '', t('Refundable deposit'), '', '', '']);
          rows.addAll(deposit.rows);
        }
        String owedRs(int b) => b > 0
            ? '${t('Owes you')} ${rs(b)}'
            : b < 0
            ? '${t('You owe')} ${rs(-b)}'
            : t('Settled');
        final held = {
          for (final size in sizes) size: book.held['$party:$size'] ?? 0,
        };
        subject = party == null ? '' : app.name(party);
        figures.addAll([
          SheetFigure(t('Opening'), owedRs(s.start)),
          SheetFigure(t('Debit'), rs(s.debit)),
          SheetFigure(t('Credit'), rs(s.credit)),
          SheetFigure(t('Balance'), owedRs(s.end), [
            entries(s.entries.length),
          ]),
          if (deposit.rows.isNotEmpty || book.deposits(party ?? '') != 0)
            SheetFigure(
              t('Refundable deposit'),
              rs(book.deposits(party ?? '')),
            ),
          if (held.values.any((n) => n != 0))
            SheetFigure(
              t('Customer-held'),
              '${held.values.fold(0, (v, n) => v + n)}',
              [
                for (final MapEntry(key: size, value: n) in held.entries)
                  if (n != 0) '${sizeLabel(size)}: $n',
              ],
            ),
        ]);
        heading.add('${t('Balance')}: ${owedRs(s.end)}');
        tables = [
          reportTable(
            t,
            title: subject,
            columns: translated(columns),
            rows: s.entries,
            after: [?s.opening],
            total: [
              Cell(t('Total')),
              const Cell(''),
              const Cell(''),
              Cell.amount(s.debit),
              Cell.amount(s.credit),
              owedCell(s.end),
            ],
            bold: {5},
          ),
          if (deposit.rows.isNotEmpty)
            reportTable(
              t,
              title: t('Refundable deposit'),
              columns: translated(columns),
              rows: deposit.entries,
              after: [?deposit.opening],
              total: [
                Cell(t('Total')),
                const Cell(''),
                const Cell(''),
                Cell.amount(deposit.debit),
                Cell.amount(deposit.credit),
                Cell.amount(-deposit.end),
              ],
              bold: {5},
            ),
        ];
      }
    case 'Daily customer balances':
      columns = [
        'Date',
        'Name',
        'Phone',
        'Opening',
        'Cylinder billing',
        'Extra-KG billing',
        'Purchase share amount',
        'Cash',
        'Bank',
        'Direct to party',
        'Closing',
      ];
      final days = {from, to, ...docs.map((d) => d.date)}.toList()..sort();
      // The sheet: one table a day, of the parties with any figure that day,
      // and the activity of the whole range as the summary.
      final range = List.filled(6, 0);
      tables = [];
      for (final date in days) {
        final opening = app.bookAt(
          DateTime.parse(date)
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10),
        );
        final closing = app.bookAt(date);
        final day = <List<Cell>>[], sums = List.filled(8, 0);
        for (final p in app.ofKind('party', archived: true)) {
          final activity = docs.where((d) => d.date == date && d.party == p.id);
          final sales = activity.where((d) => d.type == EntryType.sale);
          final values = [
            opening.receivable(p.id),
            sales.fold(0, (v, d) => v + d.cylinderRevenue),
            sales.fold(0, (v, d) => v + d.bulkRevenue),
            activity.fold(0, (v, d) => v + d.shareCharge),
            activity.fold(0, (v, d) => v + d.value('cash')),
            activity.fold(0, (v, d) => v + d.bankIn),
            activity.fold(0, (v, d) => v + d.direct),
            closing.receivable(p.id),
          ];
          final cells = [
            Cell(p.name),
            Cell('${p.data['phone'] ?? ''}'),
            for (final v in values) Cell.amount(v),
          ];
          rows.add([Cell(date), ...cells]);
          if (values.every((v) => v == 0)) continue;
          day.add(cells);
          for (var i = 0; i < values.length; i++) {
            sums[i] += values[i];
          }
          for (var i = 0; i < range.length; i++) {
            range[i] += values[i + 1];
          }
        }
        // A day when no party had a figure is left out of the print.
        if (day.isEmpty) continue;
        tables.add(
          reportTable(
            t,
            title: rozDmy(date),
            columns: translated(columns.skip(1).toList()),
            rows: day,
            total: [
              Cell(t('Total')),
              const Cell(''),
              for (final v in sums) Cell.amount(v),
            ],
            bold: {0, 9},
          ),
        );
      }
      if (tables.isEmpty) {
        tables.add(
          reportTable(
            t,
            title: t(kind),
            columns: translated(columns.skip(1).toList()),
            rows: const [],
          ),
        );
      }
      figures.addAll([
        SheetFigure(t('Cylinder billing'), rs(range[0])),
        SheetFigure(t('Extra-KG billing'), rs(range[1])),
        if (range[2] != 0) SheetFigure(t('Purchase share amount'), rs(range[2])),
        SheetFigure(t('Cash'), rs(range[3])),
        SheetFigure(t('Bank'), rs(range[4])),
        if (range[5] != 0) SheetFigure(t('Direct to party'), rs(range[5])),
      ]);
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
      var receivable = 0, payable = 0, deposits = 0, listed = 0;
      for (final p in app.ofKind('party', archived: true)) {
        if (kind == 'Udhari' && p.data['udhari'] != true) continue;
        final (r, pay, dep) = (
          book.receivable(p.id),
          book.payable(p.id),
          book.deposits(p.id),
        );
        receivable += r;
        payable += pay;
        deposits += dep;
        if (r != 0 || pay != 0 || dep != 0) listed++;
        add([
          p.name,
          p.data['phone'] ?? '',
          if (kind == 'Daily customer balances')
            Cell.amount(before.receivable(p.id)),
          Cell.amount(r),
          Cell.amount(pay),
          Cell.amount(dep),
        ]);
      }
      dates = rozDmy(to);
      bold = {0};
      skipZero = true;
      figures.addAll([
        SheetFigure(t('Receivable'), rs(receivable), [
          '${t('Parties')} $listed',
        ]),
        SheetFigure(t('Payable'), rs(payable)),
        SheetFigure(t('Refundable deposit'), rs(deposits)),
      ]);
      heading.add('${t('Receivable')}: ${rs(receivable)}');
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
      final sums = List.filled(8, 0);
      for (final d in docs.where(
        (d) =>
            !d.purchaseShare &&
            [
              EntryType.sale,
              EntryType.historicalSale,
              EntryType.creditNote,
            ].contains(d.type),
      )) {
        final sign = d.type == EntryType.creditNote ? -1 : 1;
        final values = [
          d.type == EntryType.historicalSale
              ? d.value('grams')
              : d.type == EntryType.creditNote &&
                    d.data['stockReturned'] != true
              ? 0
              : sign * d.ownSaleGrams,
          sign *
              (d.type == EntryType.historicalSale
                  ? d.total
                  : d.cylinderRevenue),
          sign * d.bulkRevenue,
          sign * (d.total - d.shareCharge),
          d.value('cash'),
          d.bankIn,
          d.direct,
          book.invoiceDue[d.id] ?? 0,
        ];
        for (var i = 0; i < values.length; i++) {
          sums[i] += values[i];
        }
        add([
          d.date,
          d.reference,
          app.name(d.party),
          Cell.weight(values[0]),
          for (final v in values.skip(1)) Cell.amount(v),
        ]);
      }
      bold = {2, 6};
      figures.addAll([
        SheetFigure(t('KG sold'), '${kg(sums[0])} kg'),
        SheetFigure(t('Bill total'), rs(sums[3]), [
          '${t('Cylinder billing')} ${money(sums[1])}',
          '${t('Extra-KG billing')} ${money(sums[2])}',
        ]),
        SheetFigure(t('Cash'), rs(sums[4])),
        SheetFigure(t('Bank'), rs(sums[5])),
        if (sums[6] != 0) SheetFigure(t('Direct to party'), rs(sums[6])),
        SheetFigure(t('Outstanding'), rs(sums[7]), [entries(rows.length)]),
      ]);
      heading.add('${t('Bill total')}: ${rs(sums[3])}');
    case 'Purchase shares':
      columns = [
        'Date',
        'Reference',
        'Name',
        'Weight (KG)',
        'Purchase share amount',
        'FIFO cost',
        'Cost difference',
        'Share from',
      ];
      var grams = 0, charged = 0, costs = 0;
      for (final d in docs.where(
        (d) =>
            d.bulkAtCost &&
            [EntryType.sale, EntryType.creditNote].contains(d.type),
      )) {
        final sign = d.type == EntryType.creditNote ? -1 : 1;
        final cost = book.shareCosts[d.id] ?? 0;
        grams += sign * d.extraGrams;
        charged += sign * d.shareCharge;
        costs += cost;
        add([
          d.date,
          d.reference,
          app.name(d.party),
          Cell.weight(sign * d.extraGrams),
          Cell.amount(sign * d.shareCharge),
          Cell.amount(cost),
          Cell.amount(cost - sign * d.shareCharge),
          app.shareSource(d).isEmpty
              ? t('Oldest stock first (FIFO)')
              : app.shareSource(d),
        ]);
      }
      bold = {2, 4};
      figures.addAll([
        SheetFigure(t('Weight (KG)'), '${kg(grams)} kg'),
        SheetFigure(t('Purchase share amount'), rs(charged), [
          entries(rows.length),
        ]),
        SheetFigure(t('FIFO cost'), rs(costs)),
        SheetFigure(t('Cost difference'), rs(costs - charged)),
      ]);
      heading.add('${t('Purchase share amount')}: ${rs(charged)}');
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
      var grams = 0, billed = 0, paid = 0;
      for (final d in docs.where((d) => d.type == EntryType.purchase)) {
        grams += d.value('grams');
        billed += d.purchaseBill;
        paid += d.value('amount');
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
      bold = {2, 6};
      figures.addAll([
        SheetFigure(t('Weight (KG)'), '${kg(grams)} kg'),
        SheetFigure(t('Bill total'), rs(billed), [entries(rows.length)]),
        SheetFigure(t('Paid now'), rs(paid)),
      ]);
      heading.add('${t('Bill total')}: ${rs(billed)}');
    case 'Office expenses':
      columns = ['Date', 'Reference', 'Description', 'From account', 'Amount'];
      var spent = 0;
      for (final d in docs.where(
        (d) => d.type == EntryType.expense && d.data['category'] == 'Office',
      )) {
        spent += d.total;
        add([
          d.date,
          d.reference,
          d.note,
          app.name(d.account),
          Cell.amount(d.total),
        ]);
      }
      bold = {4};
      figures.add(SheetFigure(t('Amount'), rs(spent), [entries(rows.length)]));
      heading.add('${t('Amount')}: ${rs(spent)}');
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
      var gasIn = 0, gasOut = 0;
      for (final d in docs) {
        final change = switch (d.type) {
          EntryType.purchase || EntryType.stockAdjustment => d.value('grams'),
          EntryType.sale => -d.saleGrams,
          EntryType.creditNote =>
            d.data['stockReturned'] == true ? d.saleGrams : 0,
          EntryType.historicalSale => -d.value('grams'),
          _ => 0,
        };
        if (change != 0) {
          running += change;
          if (change > 0) {
            gasIn += change;
          } else {
            gasOut -= change;
          }
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
      final newest = rows.reversed.toList();
      rows
        ..clear()
        ..addAll(newest);
      if (opening != 0) add([from, '', t('Opening'), '', Cell.weight(opening)]);
      String kgs(int grams) => '${kg(grams)} kg';
      figures.addAll([
        SheetFigure(t('Opening'), kgs(opening)),
        SheetFigure(t('Gas in'), kgs(gasIn)),
        SheetFigure(t('Gas out'), kgs(gasOut)),
        SheetFigure(t('Closing'), kgs(running), [entries(newest.length)]),
      ]);
      heading.add('${t('Closing')}: ${kgs(running)}');
      tables = [
        reportTable(
          t,
          title: t(kind),
          columns: translated(columns),
          rows: newest,
          after: [if (opening != 0) rows.last],
          bold: {4},
        ),
      ];
    case 'FIFO allocations':
      columns = ['Sale reference', 'Purchase lot', 'Weight (KG)', 'Cost'];
      // A sale entered before its purchase gets its lot later, possibly
      // after this range, so read the allocations from everything known.
      final known = app.book;
      var grams = 0, cost = 0, unvalued = 0;
      for (final a in known.allocations.where(
        (a) => docs.any((d) => d.id == a.sale),
      )) {
        grams += a.grams;
        cost += a.cost;
        add([
          app.record(a.sale) == null
              ? a.sale
              : Document(app.record(a.sale)!).reference,
          Document(app.record(a.lot)!).reference,
          Cell.weight(a.grams),
          Cell.amount(a.cost),
        ]);
      }
      for (final e in known.uncostedSales.entries.where(
        (e) => docs.any((d) => d.id == e.key),
      )) {
        unvalued += e.value;
        add([
          Document(app.record(e.key)!).reference,
          t('Unvalued quantity'),
          Cell.weight(e.value),
          '—',
        ]);
      }
      bold = {3};
      figures.addAll([
        SheetFigure(t('Weight (KG)'), '${kg(grams)} kg'),
        SheetFigure(t('Cost'), rs(cost), [entries(rows.length)]),
        if (unvalued != 0)
          SheetFigure(t('Unvalued quantity'), '${kg(unvalued)} kg'),
      ]);
      heading.add('${t('Cost')}: ${rs(cost)}');
    case 'Profit report':
      columns = ['Description', 'Amount'];
      final ids = docs.map((d) => d.id).toSet();
      // These entries' own postings, as known now: a sale entered before its
      // purchase gets its cost when the stock arrives, possibly after this
      // range, and that cost belongs to the sale's day.
      final known = app.book;
      int sum(String prefix) => known.postings
          .where(
            (p) => ids.contains(p.document) && p.account.startsWith(prefix),
          )
          .fold(0, (v, p) => v + p.debit);
      final cylinderSales = -sum('revenue:gas'),
          bulkSales = -sum('revenue:bulk'),
          sales = cylinderSales + bulkSales,
          cogs = sum('cogs'),
          expense = sum('expense:');
      add([t('Cylinder billing'), Cell.amount(cylinderSales)]);
      add([t('Extra-KG billing'), Cell.amount(bulkSales)]);
      add([t('Cost of gas sold'), Cell.amount(cogs)]);
      add([t('Gross profit'), Cell.amount(sales - cogs)]);
      add([t('Operating expenses'), Cell.amount(expense)]);
      add([t('Net profit'), Cell.amount(sales - cogs - expense)]);
      if (known.profitIncomplete) {
        notes.add(
          t('Uncosted stock and historical summaries make profit incomplete.'),
        );
      }
      figures.addAll([
        SheetFigure(t('Cylinder billing'), rs(cylinderSales)),
        SheetFigure(t('Extra-KG billing'), rs(bulkSales)),
        SheetFigure(t('Cost of gas sold'), rs(cogs)),
        SheetFigure(t('Gross profit'), rs(sales - cogs)),
        SheetFigure(t('Operating expenses'), rs(expense)),
        SheetFigure(t('Net profit'), rs(sales - cogs - expense)),
      ]);
      heading.add('${t('Net profit')}: ${rs(sales - cogs - expense)}');
      tables = [
        reportTable(
          t,
          title: t(kind),
          columns: translated(columns),
          rows: rows,
          // Gross profit and Net profit.
          boldRows: {3, 5},
          numbered: false,
        ),
      ];
    case 'Cylinder custody':
      // Only who holds our cylinders: full/empty counts in the shop are not
      // kept (fills are never entered; gas is tracked by KG).
      columns = ['Name', 'Size', 'Customer-held'];
      final held = {for (final size in sizes) size: 0};
      for (final p in app.ofKind('party', archived: true)) {
        for (final size in sizes) {
          final count = book.held['${p.id}:$size'] ?? 0;
          if (count != 0) {
            held[size] = held[size]! + count;
            add([p.name, sizeLabel(size), Cell('$count', count)]);
          }
        }
      }
      dates = rozDmy(to);
      bold = {0, 2};
      final all = held.values.fold(0, (v, n) => v + n);
      figures.addAll([
        SheetFigure(t('Customer-held'), '$all', [entries(rows.length)]),
        for (final MapEntry(key: size, value: n) in held.entries)
          if (n != 0) SheetFigure(sizeLabel(size), '$n'),
      ]);
      heading.add('${t('Customer-held')}: $all');
    case 'Deposit liabilities':
      columns = ['Name', 'Phone', 'Refundable deposit'];
      var held = 0, listed = 0;
      for (final p in app.ofKind('party', archived: true)) {
        held += book.deposits(p.id);
        if (book.deposits(p.id) != 0) listed++;
        add([p.name, p.data['phone'] ?? '', Cell.amount(book.deposits(p.id))]);
      }
      dates = rozDmy(to);
      bold = {0, 2};
      skipZero = true;
      figures.add(
        SheetFigure(t('Refundable deposit'), rs(held), [
          '${t('Parties')} $listed',
        ]),
      );
      heading.add('${t('Refundable deposit')}: ${rs(held)}');
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
      // Printed like the original page: the day's overview (the page's
      // opening strip and summary cards), A (Aamad), B (Kharcha), Safi Baqaya.
      columns = ['Date', 'Reference', 'Description', 'Name', 'Amount'];
      final cash = book.ledger('money:cash');
      String name(Document d) => d.party.isEmpty ? '' : app.name(d.party);
      String join(List<String> parts) =>
          parts.where((p) => p.trim().isNotEmpty).join(' · ');
      final days = [
        for (final date in docs.map((d) => d.date).toSet().toList()..sort())
          RoznamchaDay(
            date,
            cash
                .where((p) => p.date.compareTo(date) < 0)
                .fold(0, (v, p) => v + p.debit),
            docs.where((d) => d.date == date),
          ),
      ];
      // Gas in stock at the end of each day, worked back from the last one
      // (a day's gas in and out are exactly its stock movements in the book),
      // so a long range does not replay the book once per day.
      final gasClose = List.filled(days.length, book.gasGrams);
      for (var i = days.length - 2; i >= 0; i--) {
        gasClose[i] = gasClose[i + 1] - days[i + 1].gasIn + days[i + 1].gasOut;
      }
      // As on the page: no gas line until gas stock has been entered.
      final hasGas = app.book.documents.any(
        (d) =>
            d.type == EntryType.purchase || d.type == EntryType.stockAdjustment,
      );
      String gas(int g) => g < 0 ? '${t('Udhar')} ${kg(-g)}' : kg(g);
      for (var i = 0; i < days.length; i++) {
        final day = days[i];
        final date = day.date;
        void overview(String label, List<String> details, [Cell? amount]) =>
            add([
              date,
              '',
              '$label — ${details.join(' · ')}',
              '',
              amount ?? const Cell(''),
            ]);
        section(date, t('Overview'));
        final shown = day.opening + day.cashAdj;
        final cashOnly = day.openings.where(
          (d) => d.data['target'] == 'money:cash',
        );
        add([
          date,
          '',
          [
            if (day.wd > 0)
              '${t('Opening (sabiqa)')} ${money(shown)} + ${t('Bank se Nikali')} ${money(day.wd)} = ${money(shown + day.wd)}'
            else
              t('Opening (sabiqa)'),
            if (day.cashAdj != 0 && day.opening != 0)
              '(${t('pichla closing')} ${money(day.opening)}, ${t(cashOnly.every(isOpeningBalance) ? 'Opening cash' : 'Adjustment')} ${day.cashAdj > 0 ? '+' : ''}${money(day.cashAdj)})',
          ].join(' '),
          '',
          Cell.amount(shown),
        ]);
        overview(t('A: Aamad (Opening + Wasooli + Nikali)'), [
          '${t('Cash')} ${money(day.cashIn)}',
          '${t('Bank')} ${money(day.bankCust)}',
          if (day.direct > 0) '${t('Direct')} ${money(day.direct)}',
          '${t('Nikali')} ${money(day.wd)}',
        ], Cell.amount(day.left));
        overview(t('B: Kharcha + Bank Jama'), [
          '${t('Kharcha (cash)')} ${money(day.kharchaCash)}',
          '${t('Bank jama')} ${money(day.bankCust + day.depMan)}',
          if (day.direct > 0) '${t('Direct')} ${money(day.direct)}',
          if (day.kharchaBank > 0)
            '${t('Bank se diye')} ${money(day.kharchaBank)}',
        ], Cell.amount(day.rightTotal));
        overview(t('Safi Baqaya = A − B (Cash in Hand)'), [
          '${t('Cash')}: ${money(day.safi)}',
          '${t('Bank (aaj)')}: ${day.bankNet > 0 ? '+' : ''}${money(day.bankNet)}',
        ], Cell.amount(day.safi));
        overview(t('Calculated Bill'), [
          '${t('Cylinder')} ${money(day.cylinderBill)}',
          '${t('Bulk')} ${money(day.bulkBill)}',
        ], Cell.amount(day.bill));
        if (day.sharedGrams > 0) {
          overview(t('Purchase shares'), [
            '${kg(day.sharedGrams)} kg',
            t('At FIFO cost; no sales profit'),
          ], Cell.amount(day.shareAmount));
        }
        // Weights stay in the description: the Amount column is rupees.
        overview(t('Total Gas Dispatch (KG)'), [
          '${kg(day.dispatchGrams)} kg',
          for (final s in sizes) '${sizeLabel(s)}: ${day.cylinders[s]}',
          if (day.bulkGrams > 0) '${t('Bulk')} ${kg(day.bulkGrams)} kg',
        ]);
        if (hasGas) {
          final close = gasClose[i];
          overview(t('Gas (KG)'), [
            '${t('Opening')} ${gas(close - day.gasIn + day.gasOut)} + ${kg(day.gasIn)} − ${kg(day.gasOut)} = ${gas(close)}',
          ]);
        }
        section(date, t('A: Aamad / Wasooli'));
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
                    : d.purchaseShare
                    ? 'Purchase share'
                    : 'Wasooli / Sale',
              ),
              if ('${d.data['vehicle'] ?? ''}'.isNotEmpty)
                '${t('Parchi')} ${d.data['vehicle']}',
              for (final s in sizes)
                if (integer((d.data['quantities'] as Map?)?['$s']) > 0)
                  '${sizeLabel(s)} × ${integer((d.data['quantities'] as Map?)?['$s'])}',
              if (d.extraGrams > 0)
                '${t(d.bulkAtCost ? 'Purchase share (at cost)' : 'Bulk')} ${kg(d.extraGrams)} KG'
                    '${app.shareSource(d).isEmpty ? '' : ' · ${app.shareSource(d)}'}',
              if (d.type == EntryType.sale && !d.purchaseShare)
                '${t('Rate')} ${money(d.rate)} · ${t('Bill')} ${money(d.total)}',
              if (d.type == EntryType.sale && d.purchaseShare)
                '${t('Purchase share amount')} ${money(d.total)}',
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
              t(adjustmentLabel(d)),
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
        section(date, t('B: Kharcha'));
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
      // The PDF: each day as the original page's history sheet. One day
      // asked for (the Roznamcha page's Print / PDF) is printed even empty.
      final stamp = rozStamp(app.selectedDate, t);
      final printDays = days.isEmpty && from == to
          ? [
              RoznamchaDay(
                from,
                cash
                    .where((p) => p.date.compareTo(from) < 0)
                    .fold(0, (v, p) => v + p.debit),
                const [],
              ),
            ]
          : days;
      roznamchaSheets = (compact) => [
        for (final day in printDays)
          rozSheet(
            app,
            day,
            t,
            stamp: stamp,
            saved: rozSavedCopy(app, day),
            compact: compact,
          ),
      ];
      sheets.addAll(roznamchaSheets(false));
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
    'Purchase shares' => [3, 4, 5, 6],
    'Customer balances' || 'Udhari' => [2, 3, 4],
    'Office expenses' => [4],
    'Deposit liabilities' => [2],
    'Overdue' => [4],
    'FIFO allocations' => [2, 3],
    _ => <int>[],
  };
  final body = List.of(rows);
  List<Cell>? total;
  if (totals.isNotEmpty && rows.isNotEmpty) {
    total = [
      for (var i = 0; i < columns.length; i++)
        if (i == 0)
          Cell(t('Total'))
        else if (totals.contains(i))
          Cell(
            NumberFormat(
              '#,##0.###',
              'en',
            ).format(rows.fold<num>(0, (v, r) => v + (r[i].numeric ?? 0))),
            rows.fold<num>(0, (v, r) => v + (r[i].numeric ?? 0)),
          )
        else
          const Cell(''),
    ];
    rows.add(total);
  }
  if (kind == 'Audit trail') {
    dates = '';
    figures.add(SheetFigure(t('Entries'), '${rows.length}'));
    heading.add('${t('Entries')}: ${rows.length}');
  }
  if (sheets.isEmpty) {
    sheets.add(
      reportSheet(
        date: to,
        title: '${app.businessName} — ${t(kind)}',
        stamp: rozStamp(app.selectedDate, t),
        heading: [
          dates,
          subject,
          ...heading,
        ].where((s) => s.trim().isNotEmpty).join(' · '),
        figures: figures,
        tables:
            tables ??
            [
              reportTable(
                t,
                title: t(kind),
                columns: translated(columns),
                rows: skipZero
                    ? [
                        for (final r in body)
                          if (r.any((c) => (c.numeric ?? 0) != 0)) r,
                      ]
                    : body,
                total: total,
                bold: bold,
              ),
            ],
        notes: notes,
      ),
    );
  }
  return Report(
    kind: kind,
    title: t(kind),
    business: app.businessName,
    subtitle:
        '$from — $to${party == null ? '' : ' · ${app.name(party)}'}${account == null ? '' : ' · ${app.name(account)}'}',
    columns: columns.map(t.call).toList(),
    rows: rows,
    notes: notes,
    urdu: urdu,
    sections: sections,
    sheets: sheets,
    roznamchaSheets: roznamchaSheets,
  );
}

/// A running-balance statement: its [entries] newest first, the [opening]
/// row (the balance brought forward, when not 0), and the balance at the
/// [start], the Debit and Credit sums and the balance at the [end], as
/// posted (not times the statement's sign).
class _Statement {
  final List<List<Cell>> entries;
  final List<Cell>? opening;
  final int start, debit, credit;
  const _Statement(
    this.entries,
    this.opening,
    this.start,
    this.debit,
    this.credit,
  );
  List<List<Cell>> get rows => [...entries, ?opening];
  int get end => start + debit - credit;
}

/// The rows of a running-balance statement over [accounts], newest first:
/// one row per document, its postings summed into Debit and Credit, then a
/// single Opening row with the balance brought forward from before [from],
/// left out when it is 0. Balances are shown times [sign], so −1 reads a
/// credit balance (deposits held) as positive. No rows when there is
/// nothing to show.
_Statement _statement(
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
  var running = opening, debits = 0, credits = 0;
  for (final MapEntry(key: id, value: (debit, credit)) in groups.entries) {
    final d = byId[id]!;
    running += debit - credit;
    debits += debit;
    credits += credit;
    rows.add([
      Cell(d.date),
      Cell(d.reference),
      Cell(_statementText(app, d, t, showParty: showParty, khata: khata)),
      amount(debit),
      amount(credit),
      balance(sign * running),
    ]);
  }
  return _Statement(
    rows.reversed.toList(),
    opening == 0
        ? null
        : [
            Cell(from),
            const Cell(''),
            Cell(t('Opening')),
            const Cell(''),
            const Cell(''),
            balance(sign * opening),
          ],
    opening,
    debits,
    credits,
  );
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
  final docs = (snapshot.data['documents'] as List)
      .map(
        (v) => Document(Record.fromJson(Map<String, dynamic>.from(v as Map))),
      )
      .toList();
  // The saved entries on the opening the day has now (the closing of the
  // days before it), as the Roznamcha page works it out.
  final date = '${snapshot.data['date']}';
  final book = app.bookAt(date);
  final day = RoznamchaDay(
    date,
    book.money('cash') - book.dayMovement(date, 'money:cash'),
    docs,
  );
  final stamp = rozStamp(app.selectedDate, t);
  final saved = rozSavedTime('${snapshot.data['savedAt'] ?? ''}');
  List<RozSheet> sheets(bool compact) => [
    rozSheet(app, day, t, stamp: stamp, saved: saved, compact: compact),
  ];
  return Report(
    kind: 'Daily roznamcha',
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
    sheets: sheets(false),
    roznamchaSheets: sheets,
  );
}

/// Pending balances (بقایا جات) of [parties]: the parties the Parties page is
/// showing (newest first), with its filter, Archived switch and search, in
/// the chosen [order]: by name A to Z (ignoring case), the biggest balance
/// first (what you will receive, largest first, then what you will pay,
/// largest first), or newest first as given. Ties keep the order given. The
/// subtitle names the order.
/// Laid out like the business's paper sheet: two grids a page, each with a
/// number, the name and one balance. The balance is the party's khata
/// balance ([Book.partyBalance], both sides netted) over the whole book, or
/// at the end of [asOf] when it is given: what you will receive is written
/// plainly, what you will pay with a "+". Settled parties are left out; the
/// totals are the note under the grids. [filter], [archived] and [search]
/// only describe the list in the subtitle, which starts with [asOf] (today
/// without it). With [asOf] the rows of the parties whose balance that
/// day's entries changed are also [Report.sections], shaded on screen and
/// in the PDF, with a note saying so.
///
/// With [day] it is that day's sheet instead: only the parties whose balance
/// that day's entries changed, each with its balance at the end of the day,
/// so a party that cleared its khata that day is listed with 0. The PDF
/// preview's Details switch ([Report.withCompact]) prints the same parties
/// as one Roznamcha-style sheet: the balance before the day, the day's Debit
/// and Credit (as the Party statement sums them) and the balance after it.
Report pendingReport(
  AppController app,
  Iterable<Record> parties, {
  String filter = 'All',
  bool archived = false,
  String search = '',
  bool urdu = false,
  String? day,
  String? asOf,
  PendingOrder order = PendingOrder.name,
}) {
  final t = Words(urdu), rows = <List<Cell>>[], details = <List<Cell>>[];
  // The day sheet's day wins over [asOf]; both end the book at that date.
  final changedOn = day ?? asOf;
  final book = changedOn == null ? app.book : app.bookAt(changedOn);
  // What the day's entries added to each khata and took off it.
  final moved = <String, (int, int)>{};
  if (changedOn != null) {
    for (final p in book.postings) {
      if (p.date != changedOn) continue;
      if (!p.account.startsWith('ar:') && !p.account.startsWith('ap:')) {
        continue;
      }
      final party = p.account.substring(3);
      final (debit, credit) = moved[party] ?? (0, 0);
      moved[party] = p.debit >= 0
          ? (debit + p.debit, credit)
          : (debit, credit - p.debit);
    }
  }
  // To receive is written plainly, to pay with a "+".
  Cell owed(int balance) => Cell(
    balance >= 0 ? money(balance) : '+${money(-balance)}',
    balance / 100,
  );
  Cell amount(int v) => v == 0 ? const Cell('') : Cell.amount(v);
  var receive = 0, pay = 0, debits = 0, credits = 0;
  final listed = <(Record, int, int)>[];
  for (final p in parties) {
    final balance = book.partyBalance(p.id);
    final (debit, credit) = moved[p.id] ?? (0, 0);
    if (day == null ? balance == 0 : debit == credit) continue;
    listed.add((p, balance, listed.length));
  }
  String key(Record p) => p.name.trim().toLowerCase();
  int compare((Record, int, int) a, (Record, int, int) b) {
    switch (order) {
      case PendingOrder.name:
        return key(a.$1).compareTo(key(b.$1));
      case PendingOrder.balance:
        // To receive before to pay, each largest first.
        final side = (a.$2 < 0 ? 1 : 0).compareTo(b.$2 < 0 ? 1 : 0);
        return side != 0 ? side : b.$2.abs().compareTo(a.$2.abs());
      case PendingOrder.newest:
        return 0;
    }
  }

  // The given order breaks ties (List.sort is not stable).
  listed.sort((a, b) {
    final c = compare(a, b);
    return c != 0 ? c : a.$3.compareTo(b.$3);
  });
  final shaded = <int>{};
  for (final (p, balance, _) in listed) {
    final (debit, credit) = moved[p.id] ?? (0, 0);
    if (day == null && debit != credit) shaded.add(rows.length);
    if (balance > 0) {
      receive += balance;
    } else {
      pay -= balance;
    }
    debits += debit;
    credits += credit;
    rows.add([
      Cell('${rows.length + 1}', rows.length + 1),
      Cell(p.name),
      owed(balance),
    ]);
    details.add([
      Cell(p.name),
      owed(balance - debit + credit),
      amount(debit),
      amount(credit),
      owed(balance),
    ]);
  }
  final term = search.trim();
  final subtitle = [
    changedOn ?? businessDate(),
    if (day != null) t('Changed on this day only'),
    t(filter),
    if (archived) t('Archived'),
    if (term.isNotEmpty) '${t('Search')}: $term',
    t(order.label),
    '+ = ${t('You will pay')}',
  ].join(' · ');
  final notes = [
    if (rows.isNotEmpty)
      '${t('Total')} (${rows.length}): ${t('You will receive')} ${money(receive)} · ${t('You will pay')} +${money(pay)}',
    if (shaded.isNotEmpty)
      '${t('Shaded: balance changed on')} ${sheetDates(asOf!)} (${shaded.length})',
  ];
  final net = receive - pay;
  List<RozSheet> detailed() => [
    reportSheet(
      date: day!,
      title: '${app.businessName} — ${t('Pending balances')}',
      stamp: rozStamp(businessDate(), t),
      heading: sheetDates(subtitle),
      figures: [
        SheetFigure(t('Previous balance'), owed(net - debits + credits).text, [
          '${t('Parties')} ${details.length}',
        ]),
        SheetFigure(t('Debit'), money(debits)),
        SheetFigure(t('Credit'), money(credits)),
        // In Urdu the "+" is kept before its figure, as in the table.
        SheetFigure(t('Baqaya jaat'), owed(net).text, [
          '${t('You will receive')} ${money(receive)}',
          urdu
              ? '${t('You will pay')} ${String.fromCharCode(0x2066)}+${money(pay)}${String.fromCharCode(0x2069)}'
              : '${t('You will pay')} +${money(pay)}',
        ]),
      ],
      tables: [
        reportTable(
          t,
          columns: [
            'Name',
            'Previous balance',
            'Debit',
            'Credit',
            'Baqaya jaat',
          ].map(t.call).toList(),
          rows: details,
          total: [
            Cell(t('Total')),
            owed(net - debits + credits),
            Cell.amount(debits),
            Cell.amount(credits),
            owed(net),
          ],
          bold: const {0, 4},
        ),
      ],
    ),
  ];
  return Report(
    kind: 'Pending balances',
    title: t('Pending balances'),
    business: app.businessName,
    subtitle: subtitle,
    columns: ['No.', 'Name', 'Baqaya jaat'].map(t.call).toList(),
    rows: rows,
    notes: notes,
    urdu: urdu,
    sections: shaded,
    grids: 2,
    flex: const [1, 4.6, 3],
    // Details off prints the grids; on, the day's sheet.
    roznamchaSheets: day == null
        ? null
        : (on) => on ? detailed() : const <RozSheet>[],
    sheetSwitch: 'Details',
  );
}

/// One money account's day, or several added together.
class _MoneyDay {
  final int opening, moneyIn, moneyOut, closing;
  const _MoneyDay(this.opening, this.moneyIn, this.moneyOut, this.closing);
  static const zero = _MoneyDay(0, 0, 0, 0);
  _MoneyDay operator +(_MoneyDay o) => _MoneyDay(
    opening + o.opening,
    moneyIn + o.moneyIn,
    moneyOut + o.moneyOut,
    closing + o.closing,
  );
}

/// The Money page's Statement: cash and every bank account at the end of
/// [date] (the top bar's day), then Cash, Total bank and Total (Cash + Bank).
/// The PDF is printed like the Roznamcha sheet (one [RozSheet], laid out by
/// [rozSheetPdf]): title and print stamp, the day with its total, a summary
/// row like the page's cards, then each account's opening, money in and out
/// on [date], and closing. An archived account is listed only when it held
/// or moved money that day, so the totals are always the page's cards.
Report moneyReport(AppController app, String date, {bool urdu = false}) {
  final t = Words(urdu), book = app.bookAt(date);
  final all = <(Record, _MoneyDay)>[];
  for (final a in app.ofKind('account', archived: true)) {
    var moneyIn = 0, moneyOut = 0;
    for (final p in book.ledger('money:${a.id}')) {
      if (p.date != date) continue;
      if (p.debit > 0) {
        moneyIn += p.debit;
      } else {
        moneyOut -= p.debit;
      }
    }
    final closing = book.money(a.id);
    if (a.archived && closing == 0 && moneyIn == 0 && moneyOut == 0) continue;
    all.add((
      a,
      _MoneyDay(closing - moneyIn + moneyOut, moneyIn, moneyOut, closing),
    ));
  }
  // Cash first, as on the page.
  final lines = [
    ...all.where((l) => l.$1.id == 'cash'),
    ...all.where((l) => l.$1.id != 'cash'),
  ];
  _MoneyDay sum(bool cash) => lines
      .where((l) => (l.$1.id == 'cash') == cash)
      .fold(_MoneyDay.zero, (v, l) => v + l.$2);
  final cash = sum(true), banks = sum(false), total = cash + banks;
  String name(Record a) => a.id == 'cash' ? t('Cash') : a.name;
  String bank(Record a) =>
      a.id == 'cash' ? '' : '${a.data['bank'] ?? ''}'.trim();

  // The sheet, with the Roznamcha's cells: capital column heads, amounts on
  // the end side, '—' for nothing moved, and the bank like its badges.
  SheetCell head(String label, [SheetAlign align = SheetAlign.start]) =>
      SheetCell.text(label.toUpperCase(), bold: true, align: align);
  SheetCell amount(int v, {bool bold = false, bool dash = false}) =>
      SheetCell.text(
        dash && v == 0 ? '—' : money(v),
        align: SheetAlign.end,
        bold: bold,
        numeric: true,
      );
  SheetCell figure(int v, List<String> notes) => SheetCell([
    [
      SheetRun('Rs. ${money(v)}', bold: true),
      const SheetRun(' '),
      SheetRun(notes.join(' | '), small: true),
    ],
  ]);
  List<SheetCell> totalRow(String label, _MoneyDay v) => [
    SheetCell.text(label, bold: true, span: 3),
    amount(v.opening, bold: true),
    amount(v.moneyIn, bold: true),
    amount(v.moneyOut, bold: true),
    amount(v.closing, bold: true),
  ];
  final end = SheetAlign.end;
  final sheet = RozSheet(
    date: date,
    title: t('Cash and bank statement'),
    stamp: rozStamp(date, t),
    heading:
        '${rozDmy(date)} ${t('Total (Cash + Bank)')}: Rs. ${money(total.closing)}',
    summary: SheetTable(
      title: '',
      wrap: const {0, 1, 2},
      head: [
        head(t('Cash')),
        head(t('Total bank')),
        head(t('Total (Cash + Bank)')),
      ],
      body: [
        [
          figure(cash.closing, ['${t('Opening')} ${money(cash.opening)}']),
          figure(banks.closing, ['${t('Opening')} ${money(banks.opening)}']),
          figure(total.closing, [
            '${t('Cash')} ${money(cash.closing)}',
            '${t('Bank')} ${money(banks.closing)}',
          ]),
        ],
      ],
      top: true,
    ),
    tables: [
      SheetTable(
        title: t('Cash and bank accounts'),
        // Account and Bank.
        wrap: const {1, 2},
        head: [
          SheetCell.text('#', bold: true),
          head(t('Account')),
          head(t('Bank')),
          head(t('Opening'), end),
          head(t('Money in'), end),
          head(t('Money out'), end),
          head(t('Closing'), end),
        ],
        body: [
          for (final (i, (a, v)) in lines.indexed)
            [
              SheetCell.text('${i + 1}'),
              SheetCell([
                [SheetRun(name(a), bold: true)],
                if (a.archived) [SheetRun(t('Archived'), small: true)],
              ]),
              bank(a).isEmpty
                  ? SheetCell.text('—')
                  : SheetCell([
                      [SheetRun(bank(a).toUpperCase(), bold: true, small: true)],
                    ]),
              amount(v.opening),
              amount(v.moneyIn, dash: true),
              amount(v.moneyOut, dash: true),
              amount(v.closing, bold: true),
            ],
        ],
        foot: [
          totalRow(t('Cash'), cash),
          totalRow(t('Total bank'), banks),
          totalRow(t('Total (Cash + Bank)'), total),
        ],
      ),
    ],
  );
  List<Cell> row(String label, String bankName, _MoneyDay v) => [
    Cell(label),
    Cell(bankName),
    Cell.amount(v.opening),
    Cell.amount(v.moneyIn),
    Cell.amount(v.moneyOut),
    Cell.amount(v.closing),
  ];
  return Report(
    kind: 'Cash and bank statement',
    title: t('Cash and bank statement'),
    business: app.businessName,
    subtitle: date,
    columns: [
      'Account',
      'Bank',
      'Opening',
      'Money in',
      'Money out',
      'Closing',
    ].map(t.call).toList(),
    rows: [
      for (final (a, v) in lines) row(name(a), bank(a), v),
      row(t('Cash'), '', cash),
      row(t('Total bank'), '', banks),
      row(t('Total (Cash + Bank)'), '', total),
    ],
    urdu: urdu,
    sheets: [sheet],
  );
}

Report invoiceReport(AppController app, Document d, {bool urdu = false}) {
  final t = Words(urdu), rows = <List<Cell>>[];
  // For the sheet: the items sold, and the totals and payments (its foot).
  final items = <List<Cell>>[], sums = <(String, String, int)>[];
  void item(List<Cell> cells) {
    items.add(cells);
    rows.add(cells);
  }

  void total(String label, int amount, {String detail = ''}) {
    sums.add((label, detail, amount));
    rows.add([
      Cell(t(label)),
      Cell(detail),
      const Cell(''),
      const Cell(''),
      Cell.amount(amount),
    ]);
  }

  if (d.type == EntryType.sale) {
    for (final line in d.saleLines) {
      item([
        Cell(sizeLabel(line.size)),
        Cell('${line.count}', line.count),
        Cell.weight(line.grams),
        Cell.amount(d.rate),
        Cell.amount(line.amount),
      ]);
    }
    if (d.lineRounding != 0) total('Rounding', d.lineRounding);
    if (d.extraGrams > 0) {
      item([
        Cell(t(d.bulkAtCost ? 'Purchase share (at cost)' : 'Bulk KG')),
        const Cell(''),
        Cell.weight(d.extraGrams),
        d.bulkAtCost
            ? Cell(
                app.shareSource(d).isEmpty
                    ? t('FIFO cost')
                    : app.shareSource(d),
              )
            : Cell.amount(d.rate),
        Cell.amount(d.bulkBill),
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
  final kind = t(
    d.type == EntryType.creditNote
        ? 'Credit note'
        : d.purchaseShare
        ? 'Purchase share'
        : 'Invoice / receipt',
  );
  final columns = [
    'Description',
    'Quantity',
    'Weight (KG)',
    'Rate per 11.8 KG',
    'Amount',
  ].map(t.call).toList();
  final notes = [
    if (d.note.isNotEmpty) d.note,
    if ('${d.data['vehicle'] ?? ''}'.isNotEmpty)
      '${t('Vehicle / parchi')}: ${d.data['vehicle']}',
    if ('${d.data['dueDate'] ?? ''}'.isNotEmpty)
      '${t('Due date')}: ${d.data['dueDate']}',
    if ('${app.settings['address'] ?? ''}'.isNotEmpty)
      '${app.settings['address']}',
    if ('${app.settings['phone'] ?? ''}'.isNotEmpty) '${app.settings['phone']}',
    if (d.voided) t('Voided'),
  ];
  final phone = '${app.record(d.party)?.data['phone'] ?? ''}';

  // The PDF in the Roznamcha sheet's design: the items, then the bill's
  // totals and payments under them, each label across the item columns.
  String rs(int minor) => 'Rs. ${money(minor)}';
  final collected = d.value('cash') + d.bankIn + d.direct;
  final grams = d.type == EntryType.sale
      ? d.saleLines.fold(0, (v, l) => v + l.grams) + d.extraGrams
      : 0;
  final strong = {'Bill total', 'Outstanding'};
  final foot = [
    for (final (label, detail, amount) in sums)
      [
        SheetCell.text(
          [t(label), detail].where((s) => s.isNotEmpty).join(' · '),
          bold: strong.contains(label),
          // '#' and every item column but Amount.
          span: 5,
        ),
        SheetCell.text(
          money(amount),
          align: SheetAlign.end,
          bold: strong.contains(label),
          numeric: true,
        ),
      ],
  ];
  final itemTable = reportTable(t, columns: columns, rows: items);
  final sheet = reportSheet(
    date: d.date,
    title: '${app.businessName} — $kind',
    stamp: rozStamp(app.selectedDate, t),
    heading: [
      rozDmy(d.date),
      d.reference,
      if (d.party.isNotEmpty) app.name(d.party),
      phone,
    ].where((s) => s.trim().isNotEmpty).join(' · '),
    figures: d.type == EntryType.sale
        ? [
            if (grams > 0)
              SheetFigure(t('Weight (KG)'), '${kg(grams)} kg', [
                for (final l in d.saleLines)
                  '${sizeLabel(l.size)} × ${l.count}',
                if (d.extraGrams > 0)
                  '${t(d.bulkAtCost ? 'Purchase share (at cost)' : 'Bulk KG')} ${kg(d.extraGrams)}',
              ]),
            SheetFigure(t('Bill total'), rs(d.total)),
            SheetFigure(t('Kul Wasooli'), rs(collected), [
              '${t('Cash')} ${money(d.value('cash'))}',
              '${t('Bank')} ${money(d.bankIn)}',
              if (d.direct > 0) '${t('Direct')} ${money(d.direct)}',
            ]),
            SheetFigure(
              t('Outstanding'),
              rs(app.book.invoiceDue[d.id] ?? 0),
            ),
          ]
        : [
            SheetFigure(
              t(entryLabel(d.type.name)),
              rs(d.total == 0 ? d.collected : d.total),
            ),
          ],
    tables: [
      SheetTable(
        title: kind,
        wrap: itemTable.wrap,
        head: itemTable.head,
        // A receipt or payment has no items: its lines are the table.
        body: items.isEmpty ? foot : itemTable.body,
        foot: items.isEmpty ? const [] : foot,
      ),
    ],
    notes: notes,
  );
  return Report(
    kind: 'Invoice',
    title: '$kind ${d.reference}',
    business: app.businessName,
    subtitle: '${d.date} · ${app.name(d.party)} · $phone',
    columns: columns,
    rows: rows,
    notes: notes,
    urdu: urdu,
    sheets: [sheet],
  );
}

/// Flutter shapes the original Unicode paragraph; only complex text is rasterized.
class UrduPdfRenderer {
  final pw.Font? latinFont;
  final bool rtl;
  UrduPdfRenderer({this.latinFont, this.rtl = false});
  final Map<String, (pw.MemoryImage, double, double)> _lines = {};

  /// One line at its natural size, with no space around it, for the
  /// fixed-height rows of a grid report. The caller places it and scales it
  /// down when it is wider than its cell.
  Future<pw.Widget> line(
    String text, {
    double fontSize = 9,
    bool bold = false,
    PdfColor color = PdfColors.black,
  }) async {
    if (!RegExp(r'[\u0600-\u08ff\ufb50-\ufdff\ufe70-\ufeff]').hasMatch(text)) {
      return pw.Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: pw.TextStyle(
          fontSize: fontSize,
          font: latinFont,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: color,
        ),
      );
    }
    // The picture is kept, not the widget: a widget holds its own place on
    // the page, and the same text is drawn on every page (the grid heads).
    final key = '$text|$fontSize|$bold|${color.toInt()}';
    final kept = _lines[key];
    if (kept != null) {
      return pw.Image(kept.$1, width: kept.$2, height: kept.$3);
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'NotoUrdu',
          fontSize: fontSize,
          height: 1.9,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontVariations: [FontVariation.weight(bold ? 700 : 400)],
          color: Color(color.toInt()),
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.rtl,
      locale: const Locale('ur'),
    )..layout();
    final recorder = ui.PictureRecorder(), canvas = Canvas(recorder);
    const scale = 300 / 72;
    final width = painter.width + 2, height = painter.height + 2;
    canvas.scale(scale);
    painter.paint(canvas, const Offset(1, 1));
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (width * scale).ceil(),
      (height * scale).ceil(),
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final memory = pw.MemoryImage(png!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    painter.dispose();
    _lines[key] = (memory, width, height);
    return pw.Image(memory, width: width, height: height);
  }

  final Map<String, (pw.MemoryImage, double)> _paragraphs = {};
  static final _script = RegExp(r'[\u0600-\u08ff\ufb50-\ufdff\ufe70-\ufeff]');
  static final _scriptRun = RegExp(
    r'[\u0600-\u08ff\ufb50-\ufdff\ufe70-\ufeff]+'
    r'(?:[\s\u200c\u200d]+[\u0600-\u08ff\ufb50-\ufdff\ufe70-\ufeff]+)*',
  );
  static final _number = RegExp(r'[-+]?\d(?:[\d,./:-]*\d)?');
  PdfFont? _helvetica, _helveticaBold;

  /// Flutter's paragraph of styled runs for [runs]: Urdu script in Nastaliq,
  /// a little larger so it reads as large as the Latin beside it, and the
  /// rest in Arial, which matches the page's Helvetica (Manrope where there
  /// is no Arial).
  TextSpan _paragraph(List<(String, bool, double)> runs, Color color) {
    TextSpan piece(String text, bool urdu, bool bold, double size) => TextSpan(
      // After Urdu letters, bidi reads digits as Arabic numbers, which do not
      // join over "-": 26-10-2026 would print as 2026-10-26. Such a number is
      // isolated left to right, which keeps its place in an Urdu sentence;
      // other numbers already read right.
      text: urdu
          ? text
          : text.replaceAllMapped(
              _number,
              (m) => m[0]!.contains(RegExp('[-+]'))
                  ? '\u2066${m[0]}\u2069'
                  : m[0]!,
            ),
      style: TextStyle(
        fontFamily: urdu ? 'NotoUrdu' : 'Arial',
        fontFamilyFallback: const ['Manrope'],
        fontSize: urdu ? size * 1.2 : size,
        height: urdu ? 1.6 : null,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        fontVariations: [FontVariation.weight(bold ? 700 : 400)],
        color: color,
      ),
    );
    final pieces = <TextSpan>[];
    for (final (part, bold, size) in runs) {
      var at = 0;
      for (final m in _scriptRun.allMatches(part)) {
        if (m.start > at) {
          pieces.add(piece(part.substring(at, m.start), false, bold, size));
        }
        pieces.add(piece(m.group(0)!, true, bold, size));
        at = m.end;
      }
      if (at < part.length) {
        pieces.add(piece(part.substring(at), false, bold, size));
      }
    }
    return TextSpan(children: pieces);
  }

  /// How wide [runs] are on one line, drawn as [runs] draws them.
  double measure(
    List<(String, bool, double)> runs, {
    double letterSpacing = 0,
  }) {
    if (!_script.hasMatch(runs.map((r) => r.$1).join())) {
      final document = PdfDocument();
      final regular = _helvetica ??= PdfFont.helvetica(document);
      final bold = _helveticaBold ??= PdfFont.helveticaBold(document);
      var width = 0.0;
      for (final (part, isBold, size) in runs) {
        final font = isBold ? bold : regular;
        for (final rune in part.runes) {
          // Beyond Latin-1 the fallback font draws it: an em is a safe guess.
          final em = rune < 256 ? font.glyphMetrics(rune).advanceWidth : 1.0;
          width += em * size + letterSpacing;
        }
      }
      return width;
    }
    final painter = TextPainter(
      text: _paragraph(runs, Colors.black),
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      locale: const Locale('ur'),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// A paragraph of styled runs (text, bold, font size) exactly [width]
  /// wide, for the Roznamcha sheet. Latin text is set in the page's own font,
  /// bold through its bold face, and wraps like any PDF text. A paragraph
  /// with Urdu script is shaped by Flutter and drawn at 300 DPI, as tall as
  /// its wrapped lines: left to right unless [rtl], so a name typed as
  /// "لقمان احمد Luqman Ahmad" reads as typed in an English sheet.
  Future<pw.Widget> runs(
    List<(String, bool, double)> runs,
    double width, {
    pw.TextAlign align = pw.TextAlign.left,
    PdfColor color = PdfColors.black,
    double letterSpacing = 0,
  }) async {
    final text = runs.map((r) => r.$1).join();
    if (!_script.hasMatch(text)) {
      return pw.SizedBox(
        width: width,
        child: pw.RichText(
          textAlign: align,
          text: pw.TextSpan(
            children: [
              for (final (part, bold, size) in runs)
                pw.TextSpan(
                  text: part,
                  style: pw.TextStyle(
                    fontSize: size,
                    fontWeight: bold
                        ? pw.FontWeight.bold
                        : pw.FontWeight.normal,
                    color: color,
                    letterSpacing: letterSpacing,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    // The picture is kept, not the widget (see [line]).
    final key = [
      for (final (part, bold, size) in runs) '$part\u0001$bold\u0001$size',
      '$width|$align|${color.toInt()}|$rtl',
    ].join('\u0002');
    var kept = _paragraphs[key];
    if (kept == null) {
      final painter = TextPainter(
        text: _paragraph(runs, Color(color.toInt())),
        textAlign: switch (align) {
          pw.TextAlign.right || pw.TextAlign.end => TextAlign.right,
          pw.TextAlign.center => TextAlign.center,
          _ => TextAlign.left,
        },
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        locale: const Locale('ur'),
      )..layout(minWidth: width, maxWidth: width);
      final recorder = ui.PictureRecorder(), canvas = Canvas(recorder);
      const scale = 300 / 72;
      final height = painter.height;
      canvas.scale(scale);
      painter.paint(canvas, Offset.zero);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        (width * scale).ceil(),
        (height * scale).ceil(),
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      painter.dispose();
      kept = (pw.MemoryImage(png!.buffer.asUint8List()), height);
      _paragraphs[key] = kept;
    }
    return pw.Image(kept.$1, width: width, height: kept.$2);
  }
}

class ReportCancelled implements Exception {}

// The grids' rules, as the Roznamcha sheet draws them.
const _gridRule = pw.BorderSide(color: PdfColor.fromInt(0xff555555), width: .6);
const _gridGrey = PdfColor.fromInt(0xff555555);
// A light shade that a black-and-white printer still shows.
const _gridShade = PdfColor.fromInt(0xffe2e2e2);

class ReportExporter {
  bool cancelled = false;
  final void Function(double)? progress;

  /// How big the PDF prints its content, as a fraction of the normal design
  /// (the preview's size slider: [minSize] to [maxSize], 1 by default). Type,
  /// padding, row heights and spacing scale with it; the paper and its margin
  /// do not. Excel and CSV ignore it.
  final double size;
  ReportExporter({this.progress, double size = 1})
    : size = size.clamp(minSize, maxSize).toDouble();

  static const minSize = .5, maxSize = 1.5;

  /// Every report's PDF is in the Roznamcha sheet's design: its own sheets
  /// (the Roznamcha, the statements, the registers, the invoice), or one
  /// sheet made from its columns and rows; pending balances keep the paper
  /// sheet's grids, drawn the same way.
  Future<Uint8List> pdf(Report report) async {
    // The preview's old debug switch is gone; exports use the print layout.
    pw.Document.debug = false;
    if (report.sheets.isNotEmpty) return rozSheetPdf(report, this);
    if (report.grids > 1) return _gridPdf(report);
    return rozSheetPdf(report, this, [autoSheet(report)]);
  }

  /// How many rows one grid of a [Report.grids] page holds (A4 portrait) at
  /// the normal size.
  static const gridRows = 45;

  /// How many rows one grid holds at [size]: what fits under the heading,
  /// the grid head, two notes and the page number once they are all scaled
  /// (45 at 1, fewer bigger, more smaller). See [_gridPdf].
  static int gridRowsAt(double size) {
    if (size == 1) return gridRows;
    // 806 pt inside the margins, the two 6 pt gaps fixed; heading 56, grid
    // head 17, two notes of 18 and the page number 10 scale, as do the rows.
    const inside = 842 - 18.0 * 2 - 6 * 2, fixed = 56 + 17 + 18 * 2 + 10.0;
    return math.max(1, ((inside - fixed * size) / (15 * size)).floor());
  }

  /// [Report.grids] grids side by side, like the business's paper sheets:
  /// rows of one fixed height fill the first grid, then the next, page after
  /// page. The last page shares its rows evenly between the grids. In Urdu
  /// the first grid and the number column are on the right. Drawn like the
  /// Roznamcha sheet, at its sizes: black on white, grey rules, capital
  /// heads, the title and print stamp above. [Report.sections] rows are
  /// shaded light grey, which still shows on a black-and-white print.
  Future<Uint8List> _gridPdf(Report report) async {
    final fallback = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Manrope.ttf'),
    );
    final renderer = UrduPdfRenderer(rtl: report.urdu);
    const format = PdfPageFormat.a4;
    // The Roznamcha sheet's margin and type: 8.3 pt title and heading,
    // 6.4 pt stamp, 7.3 pt table text (roznamcha_sheet.dart).
    // Everything but the paper, its margin and the gaps scales with [size].
    const margin = 18.0, gap = 12.0;
    final rowHeight = 15.0 * size, headHeight = 17.0 * size;
    final titleSize = 8.3 * size, stampSize = 6.4 * size;
    final textSize = 7.3 * size, padding = 4.0 * size;
    // 806 pt inside the margins: heading 56, space 6, grid head 17, 45 rows
    // of 15, space 6, two notes of 18 and the page number 10 leave 0 to
    // spare (at the normal size; [gridRowsAt] for others). Urdu lines are
    // 1.9 times the font size: the heading's three need 55 (Latin ones
    // about 34), a note 16.
    final headingHeight =
        (report.urdu ||
                hasUrduScript(report.business + report.title + report.subtitle)
            ? 56.0
            : 40.0) *
        size;
    final rowsPerGrid = gridRowsAt(size);
    final available = format.width - margin * 2;
    final gridWidth = (available - gap * (report.grids - 1)) / report.grids;
    final flex = report.flex.length == report.columns.length
        ? report.flex
        : List.filled(report.columns.length, 1.0);
    final flexTotal = flex.fold(0.0, (v, f) => v + f);
    final widths = [for (final f in flex) gridWidth * f / flexTotal];
    final start = report.urdu
        ? pw.Alignment.centerRight
        : pw.Alignment.centerLeft;
    final end = report.urdu
        ? pw.Alignment.centerLeft
        : pw.Alignment.centerRight;
    // One line, scaled down when it is longer than its place.
    Future<pw.Widget> fit(
      String text,
      double size,
      pw.Alignment at, {
      bool bold = false,
      PdfColor color = PdfColors.black,
    }) async => pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      alignment: at,
      child: await renderer.line(
        text,
        fontSize: size,
        bold: bold,
        color: color,
      ),
    );
    Future<pw.TableRow> row(
      List<String> cells, {
      bool head = false,
      bool shade = false,
    }) async {
      final widgets = <pw.Widget>[];
      for (var i = 0; i < cells.length; i++) {
        // Names align right like the amounts, as on the paper sheet.
        final at = head || i == 0
            ? pw.Alignment.center
            : pw.Alignment.centerRight;
        widgets.add(
          pw.Container(
            height: head ? headHeight : rowHeight,
            padding: pw.EdgeInsets.symmetric(horizontal: padding),
            alignment: at,
            child: cells[i].isEmpty
                ? null
                : await fit(
                    head ? cells[i].toUpperCase() : cells[i],
                    textSize,
                    at,
                    bold: head,
                  ),
          ),
        );
      }
      return pw.TableRow(
        decoration: shade ? const pw.BoxDecoration(color: _gridShade) : null,
        children: report.urdu ? widgets.reversed.toList() : widgets,
      );
    }

    final body = <pw.TableRow>[];
    for (var index = 0; index < report.rows.length; index++) {
      if (cancelled) throw ReportCancelled();
      body.add(
        await row(
          report.rows[index].map((c) => c.text).toList(),
          shade: report.sections.contains(index),
        ),
      );
      progress?.call((index + 1) / report.rows.length);
      if (index % 15 == 0) await Future<void>.delayed(Duration.zero);
    }
    final doc = pw.Document(
      title: report.title,
      author: report.business,
      // The Roznamcha sheet's fonts (see rozSheetPdf).
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        fontFallback: [fallback],
      ),
    );
    final stamp = rozStamp(businessDate(), Words(report.urdu));
    final perPage = rowsPerGrid * report.grids;
    final pages = math.max(1, (body.length / perPage).ceil());
    final blank = List.filled(report.columns.length, '');
    for (var page = 0; page < pages; page++) {
      final slice = body.skip(page * perPage).take(perPage).toList();
      final last = page == pages - 1;
      final each = last
          ? math.max(1, (slice.length / report.grids).ceil())
          : rowsPerGrid;
      final tables = <pw.Widget>[];
      for (var g = 0; g < report.grids; g++) {
        final rows = slice.skip(g * each).take(each).toList();
        tables.add(
          pw.SizedBox(
            width: gridWidth,
            child: pw.Table(
              border: const pw.TableBorder(
                left: _gridRule,
                right: _gridRule,
                top: _gridRule,
                bottom: _gridRule,
                horizontalInside: _gridRule,
                verticalInside: _gridRule,
              ),
              columnWidths: {
                for (var i = 0; i < widths.length; i++)
                  i: pw.FixedColumnWidth(
                    widths[report.urdu ? widths.length - 1 - i : i],
                  ),
              },
              children: [
                await row(report.columns, head: true),
                ...rows,
                // Empty rows keep the grids of a page the same height.
                for (var i = rows.length; i < each; i++) await row(blank),
              ],
            ),
          ),
        );
      }
      // The sheet's title, print stamp and bold heading.
      final top = [
        await fit(
          [
            report.business,
            report.title,
          ].where((s) => s.trim().isNotEmpty).join(' — '),
          titleSize,
          start,
          bold: true,
        ),
        await fit(stamp, stampSize, start, color: _gridGrey),
        await fit(sheetDates(report.subtitle), titleSize, start, bold: true),
      ];
      final notes = <pw.Widget>[
        if (last)
          for (final note in report.notes)
            pw.Container(
              width: available,
              alignment: start,
              child: await fit(note, titleSize, start, bold: true),
            ),
      ];
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(margin),
          build: (_) => pw.Column(
            children: [
              pw.SizedBox(
                height: headingHeight,
                child: pw.Column(
                  children: [
                    for (final (i, line) in top.indexed) ...[
                      if (i == 2) pw.SizedBox(height: 5 * size),
                      pw.Container(
                        width: available,
                        alignment: start,
                        child: line,
                      ),
                    ],
                  ],
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: report.urdu ? tables.reversed.toList() : tables,
              ),
              pw.SizedBox(height: 6),
              ...notes,
              pw.Spacer(),
              pw.Container(
                width: available,
                alignment: end,
                child: pw.Text(
                  '${page + 1} / $pages',
                  style: pw.TextStyle(fontSize: stampSize, color: _gridGrey),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return doc.save();
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
