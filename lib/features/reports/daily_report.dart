import '../../core/controller.dart';
import '../../core/l10n.dart';
import '../../core/models.dart';
import '../ledger/profit.dart';
import '../ledger/roznamcha.dart';
import 'report_sheet.dart';
import 'reports.dart';
import 'roznamcha_sheet.dart';

/// The Reports page's selected view. All output formats use the same rows;
/// changing the preview switch rebuilds both the rows and the printed sheet.
/// The separate Roznamcha/history entry points keep their original sheets.
Report buildReportView(
  AppController app,
  String kind,
  String from,
  String to, {
  String? party,
  String? account,
  bool urdu = false,
  bool compact = false,
}) {
  party = kind == 'Party statement' ? party : null;
  account = kind == 'Bank book' ? account : null;
  final detailed = buildReport(
    app,
    kind,
    from,
    to,
    party: party,
    account: account,
    urdu: urdu,
  );
  Report? daily;
  Report view(bool value) {
    final source = value
        ? daily ??= _dailyReport(app, detailed, kind, from, to, party, account)
        : detailed;
    return Report(
      title: source.title,
      business: source.business,
      subtitle: source.subtitle,
      columns: source.columns,
      rows: source.rows,
      notes: source.notes,
      urdu: source.urdu,
      sections: source.sections,
      sheets: source.sheets,
      compact: value,
      compactView: view,
      kind: source.kind,
    );
  }

  return view(compact);
}

/// Aggregate in integer paisa/grams/counts, not floating point display units.
Cell _sum(Iterable<List<Cell>> rows, int column, [int scale = 100]) {
  final value = rows.fold<int>(
    0,
    (n, row) => n + ((row[column].numeric ?? 0) * scale).round(),
  );
  return scale == 1000
      ? Cell.weight(value)
      : scale == 100
      ? Cell.amount(value)
      : Cell('$value', value);
}

Iterable<String> _dates(String from, String to) sync* {
  final end = DateTime.parse(to);
  for (
    var date = DateTime.parse(from);
    !date.isAfter(end);
    date = date.add(const Duration(days: 1))
  ) {
    yield date.toIso8601String().substring(0, 10);
  }
}

Report _dailyReport(
  AppController app,
  Report detailed,
  String kind,
  String from,
  String to,
  String? party,
  String? account,
) {
  final t = Words(detailed.urdu);
  final rows = <List<Cell>>[];
  var columns = <String>[];
  // Columns that are movements may be totalled over the range. Balances,
  // opening amounts and counts held at a date must never be added across days.
  final additive = <int, int>{};
  final closingColumns = <int>{};
  final openingColumns = <int>{};
  void add(String date, List<Cell> values) => rows.add([Cell(date), ...values]);
  final docs = app
      .bookAt(to)
      .documents
      .where((d) => d.date.compareTo(from) >= 0 && d.date.compareTo(to) <= 0)
      .toList();
  final days = docs.map((d) => d.date).toSet().toList()..sort();

  switch (kind) {
    case 'Cash book' || 'Bank book' || 'Party statement':
      final isParty = kind == 'Party statement';
      final main = <String, List<List<Cell>>>{};
      final deposits = <String, List<List<Cell>>>{};
      var deposit = false;
      for (final row in detailed.rows) {
        if (row[2].text == t('Refundable deposit')) {
          deposit = true;
          continue;
        }
        if (row[2].text == t('Opening')) continue;
        final date = row[0].text;
        if (DateTime.tryParse(date) == null) continue;
        ((deposit ? deposits : main)[date] ??= []).add(row);
      }
      final hasDeposits =
          deposits.isNotEmpty ||
          (isParty && app.bookAt(to).deposits(party ?? '') != 0);
      columns = [
        'Date',
        'Debit',
        'Credit',
        'Balance',
        if (hasDeposits) ...[
          'Deposit debit',
          'Deposit credit',
          'Refundable deposit',
        ],
      ];
      additive.addAll({
        1: 100,
        2: 100,
        if (hasDeposits) ...{4: 100, 5: 100},
      });
      // Include the first date even with only a brought-forward balance.
      closingColumns.addAll({3, if (hasDeposits) 6});
      final dates = {
        if (detailed.rows.isNotEmpty) from,
        ...main.keys,
        ...deposits.keys,
      }.toList()..sort();
      for (final date in dates) {
        final book = app.bookAt(date);
        final balance = isParty
            ? book.partyBalance(party ?? '')
            : book.money(kind == 'Cash book' ? 'cash' : account ?? '');
        add(date, [
          _sum(main[date] ?? [], 3),
          _sum(main[date] ?? [], 4),
          isParty ? _owed(t, balance) : Cell.amount(balance),
          if (hasDeposits) ...[
            _sum(deposits[date] ?? [], 3),
            _sum(deposits[date] ?? [], 4),
            Cell.amount(book.deposits(party ?? '')),
          ],
        ]);
      }
    case 'Customer balances' ||
        'Udhari' ||
        'Deposit liabilities' ||
        'Cylinder custody':
      final parties = app
          .ofKind('party', archived: true)
          .where((p) => kind != 'Udhari' || p.data['udhari'] == true)
          .toList();
      columns = [
        'Date',
        if (kind == 'Customer balances' || kind == 'Udhari') ...[
          'Receivable',
          'Payable',
          'Refundable deposit',
        ] else if (kind == 'Deposit liabilities')
          'Refundable deposit'
        else ...[
          for (final size in sizes) sizeLabel(size),
        ],
      ];
      for (final date in _dates(from, to)) {
        final book = app.bookAt(date);
        int sum(int Function(String) value) =>
            parties.fold(0, (v, p) => v + value(p.id));
        add(date, [
          if (kind == 'Customer balances' || kind == 'Udhari') ...[
            Cell.amount(sum(book.receivable)),
            Cell.amount(sum(book.payable)),
            Cell.amount(sum(book.deposits)),
          ] else if (kind == 'Deposit liabilities')
            Cell.amount(sum(book.deposits))
          else
            for (final size in sizes)
              Cell(
                '${sum((id) => book.held['$id:$size'] ?? 0)}',
                sum((id) => book.held['$id:$size'] ?? 0),
              ),
        ]);
      }
    case 'Daily roznamcha':
      columns = [
        'Date',
        'Opening',
        'A: Kul Aamad',
        'B: Kharcha + Bank Jama',
        'Closing',
        'Total Gas Dispatch (KG)',
        'Total Sale',
        'Purchase share amount',
      ];
      additive.addAll({5: 1000, 6: 100, 7: 100});
      openingColumns.add(1);
      closingColumns.add(4);
      final cash = app.bookAt(to).ledger('money:cash');
      for (final date in days.isEmpty && from == to ? [from] : days) {
        final day = RoznamchaDay(
          date,
          cash
              .where((p) => p.date.compareTo(date) < 0)
              .fold(0, (n, p) => n + p.debit),
          docs.where((d) => d.date == date),
        );
        add(date, [
          Cell.amount(day.opening + day.cashAdj),
          Cell.amount(day.left),
          Cell.amount(day.rightTotal),
          Cell.amount(day.safi),
          Cell.weight(day.dispatchGrams),
          Cell.amount(day.bill),
          Cell.amount(day.shareAmount),
        ]);
      }
    case 'Profit report':
      columns = [
        'Date',
        'Cylinder billing',
        'Extra-KG billing',
        'Cost of gas sold',
        'Gas at your price',
        'Gross profit',
        'Hospitality',
        'Office kharcha',
        'Other kharcha',
        'Net profit',
      ];
      additive.addAll({for (var i = 1; i < columns.length; i++) i: 100});
      // Each day as "How profit is calculated" gives it; the detailed
      // report's range is the sum of these days.
      final byDay = profitByDay(app.book, app.profitSettings, from, to);
      for (final date in days) {
        final p = byDay[date] ?? Profit();
        add(date, [
          for (final amount in [
            p.cylinderSales,
            p.bulkSales,
            p.cost,
            p.estimated,
            p.gross,
            p.hospitality,
            p.office,
            p.otherExpenses,
            p.net,
          ])
            Cell.amount(amount),
        ]);
      }
    case 'FIFO allocations':
      columns = ['Date', 'Weight (KG)', 'Cost', 'Unvalued quantity'];
      additive.addAll({1: 1000, 2: 100, 3: 1000});
      final dates = {for (final d in docs) d.reference: d.date};
      final grouped = <String, List<List<Cell>>>{};
      for (final row in detailed.rows) {
        final date = dates[row[0].text];
        if (date != null) (grouped[date] ??= []).add(row);
      }
      for (final entry in grouped.entries) {
        add(entry.key, [
          _sum(entry.value.where((r) => r[3].numeric != null), 2, 1000),
          _sum(entry.value, 3),
          _sum(entry.value.where((r) => r[3].numeric == null), 2, 1000),
        ]);
      }
    case 'Audit trail':
      columns = ['Date', 'Entries'];
      additive[1] = 1;
      final counts = <String, int>{};
      for (final row in detailed.rows) {
        final instant = DateTime.tryParse(row[0].text);
        if (instant == null) continue;
        final date = businessDate(instant);
        if (date.compareTo(from) < 0 || date.compareTo(to) > 0) continue;
        counts[date] = (counts[date] ?? 0) + 1;
      }
      for (final entry in counts.entries) {
        add(entry.key, [Cell('${entry.value}', entry.value)]);
      }
    default:
      // These reports already carry dated numeric movements. Drop reference,
      // name, phone and rate columns, and sum only the additive quantities.
      final (dateColumn, metrics) = switch (kind) {
        'Sales register' => (
          0,
          {3: 1000, for (var i = 4; i <= 10; i++) i: 100},
        ),
        'Purchase register' => (0, {4: 1000, 6: 100, 7: 100}),
        'Purchase shares' => (0, {3: 1000, 4: 100, 5: 100, 6: 100}),
        'Office expenses' => (0, {4: 100}),
        'Gas stock' => (0, {3: 1000, 4: 1000}),
        'Overdue' => (2, {4: 100}),
        'Daily customer balances' => (
          0,
          {for (var i = 3; i <= 10; i++) i: 100},
        ),
        _ => throw ArgumentError.value(kind, 'kind', 'Unknown report'),
      };
      columns = ['Date', for (final i in metrics.keys) detailed.columns[i]];
      final grouped = <String, List<List<Cell>>>{};
      for (final row in detailed.rows) {
        final date = row[dateColumn].text;
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) continue;
        if (kind == 'Gas stock' && row[2].text == t('Opening')) continue;
        (grouped[date] ??= []).add(row);
      }
      for (final entry in grouped.entries) {
        add(entry.key, [
          for (final metric in metrics.entries)
            if (kind == 'Gas stock' && metric.key == 4)
              entry.value.first[4] // Source rows are newest first.
            else
              _sum(entry.value, metric.key, metric.value),
        ]);
      }
      if (kind == 'Gas stock' && rows.isEmpty && detailed.rows.isNotEmpty) {
        // A range with no movement can still have stock brought forward.
        add(from, [Cell.weight(0), detailed.rows.last[4]]);
      }
      for (final (index, metric) in metrics.entries.indexed) {
        if (kind == 'Gas stock' && metric.key == 4) {
          closingColumns.add(index + 1);
          continue;
        }
        if (kind == 'Daily customer balances' && [3, 10].contains(metric.key)) {
          (metric.key == 3 ? openingColumns : closingColumns).add(index + 1);
          continue;
        }
        additive[index + 1] = metric.value;
      }
  }

  rows.sort((a, b) => b[0].text.compareTo(a[0].text));
  final total = rows.isEmpty || additive.isEmpty
      ? null
      : [
          Cell(t('Total')),
          for (var i = 1; i < columns.length; i++)
            if (additive.containsKey(i))
              _sum(rows, i, additive[i]!)
            else if (closingColumns.contains(i))
              rows.first[i]
            else if (openingColumns.contains(i))
              rows.last[i]
            else
              const Cell(''),
        ];
  final labels = columns.map(t.call).toList();
  final notes = [
    t('One summary row per day.'),
    if (kind == 'Sales register' || kind == 'Overdue')
      t('Invoice outstanding is as of the report end date.')
    else if (kind != 'Profit report' && kind != 'Audit trail')
      t('Balances are at the end of each day.'),
    ...detailed.notes,
  ];
  final sheet = reportSheet(
    date: to,
    title: '${detailed.business} — ${detailed.title}',
    stamp: rozStamp(app.selectedDate, t),
    heading: '${sheetDates(detailed.subtitle)} · ${t('Compact')}',
    tables: [reportTable(t, columns: labels, rows: rows, total: total)],
    notes: notes,
  );
  return Report(
    kind: kind,
    title: detailed.title,
    business: detailed.business,
    subtitle: detailed.subtitle,
    columns: labels,
    rows: [...rows, ?total],
    notes: notes,
    sheets: [sheet],
    urdu: detailed.urdu,
    compact: true,
  );
}

Cell _owed(Words t, int balance) => Cell(
  balance > 0
      ? '${t('Owes you')} ${money(balance)}'
      : balance < 0
      ? '${t('You owe')} ${money(-balance)}'
      : t('Settled'),
  balance / 100,
);
