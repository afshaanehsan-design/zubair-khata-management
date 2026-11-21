import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../features/ledger/book.dart' show Book;
import '../features/ledger/entry_facts.dart' show entryTitle;
import '../features/ledger/position.dart';
import '../features/ledger/profit.dart';
import '../features/reports/reports.dart' show buildReport, kg;
import 'components.dart';
import 'export_ui.dart' show previewReport;
import 'roznamcha_widgets.dart';

/// What an expense category is called on the profit lines.
String expenseLabel(String category) => switch (category) {
  'General' => 'Cash kharcha',
  'Write-off' => 'Less / discount',
  'Stock loss' => 'Gas stock loss',
  _ => category,
};

/// "per KG", "per 11.8 KG" or "per tonne": the unit of a [GasPrice].
String priceUnit(int unit) => switch (unit) {
  1000 => 'per KG',
  1000000 => 'per tonne',
  _ => 'per 11.8 KG',
};

/// Tons with up to three decimals (whole KG), for hospitality.
String tons(int grams) => kg(grams ~/ 1000);

class _Line {
  final String label;
  final String? detail;

  /// Null shows "—": a figure that cannot be known yet.
  final int? amount;
  final bool total;
  final Color? color;
  final Widget? action;
  const _Line(
    this.label,
    this.amount, {
    this.detail,
    this.total = false,
    this.color,
    this.action,
  });
}

const _lineStyle = TextStyle(fontSize: 12.5, color: ink);
const _lineBold = TextStyle(
  fontSize: 12.5,
  color: ink,
  fontWeight: FontWeight.w700,
);

/// One line of the profit sections: its label, what it is made of and any
/// button under it, and its amount on the end side.
class _LineRow extends StatelessWidget {
  final _Line line;
  const _LineRow(this.line);

  @override
  Widget build(BuildContext context) {
    final l = line, amount = l.amount;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 11),
      decoration: BoxDecoration(
        color: l.total ? rozSoft : null,
        border: const Border(bottom: BorderSide(color: Color(0xffe9eee8))),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.label,
                  style: (l.total ? _lineBold : _lineStyle).copyWith(
                    color: l.color,
                  ),
                ),
                if (l.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l.detail!,
                      style: const TextStyle(fontSize: 11.5, color: muted),
                    ),
                  ),
                if (l.action != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: l.action,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  amount == null ? '—' : rs(amount),
                  textDirection: TextDirection.ltr,
                  style: (l.total ? _lineBold : _lineStyle).copyWith(
                    color: l.color,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A note under the profit lines, with an optional button beside it.
class _Note extends StatelessWidget {
  final String text;
  final Widget? action;
  const _Note(this.text, [this.action]);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(11, 8, 11, 0),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.info_outline_rounded, size: 15, color: amber),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: const TextStyle(fontSize: 11.5, color: muted),
              ),
            ),
          ],
        ),
        ?action,
      ],
    ),
  );
}

/// A small text button under a profit line ("Purchase price", "Change").
Widget _lineButton(
  BuildContext context,
  String label,
  IconData icon,
  Key key,
  VoidCallback onTap,
) => TextButton.icon(
  key: key,
  style: TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    minimumSize: const Size(0, 30),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  ),
  onPressed: onTap,
  icon: Icon(icon, size: 16),
  label: Text(context.t(label)),
);

/// "How profit is calculated": every step from sales to net profit, one
/// line each, with what each figure is made of. The Roznamcha shows a day's,
/// the Stock page a period's. Given the period ([from] to [to]) it also
/// offers Simple or Detailed, and Detailed adds what the business has at the
/// end of [to] and why ([PositionLines]).
class ProfitLines extends StatelessWidget {
  final AppController app;
  final Profit profit;
  final String? from, to;
  const ProfitLines(this.app, this.profit, {this.from, this.to, super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t, p = profit, settings = app.profitSettings;
    String price(GasPrice g) => [
      '${rs(g.rate)} ${t(priceUnit(g.unit))}',
      if (g.setOn.isNotEmpty) '(${t('your price')}, ${dmy(g.setOn)})',
    ].join(' ');
    Widget button(String label, IconData icon, Key key, VoidCallback onTap) =>
        _lineButton(context, label, icon, key, onTap);
    Widget priceButton(String tag) => button(
      'Purchase price',
      Icons.price_change_outlined,
      ValueKey('profit-price-$tag'),
      () => editGasPrices(context, app),
    );
    _Line unknown(String label, int grams, int cost, GasPrice? g, String tag) =>
        _Line(
          '− ${t(label)}',
          g == null ? null : cost,
          detail: g == null
              ? t('{kg} KG: purchase price not entered')
                    .replaceAll('{kg}', kg(grams))
              : '${kg(grams)} KG × ${price(g)}',
          action: priceButton(tag),
        );
    final rates = p.hospitalityRates.toList()..sort();
    final perTon = t('per ton');
    final lines = <_Line>[
      _Line(t('Cylinder billing'), p.cylinderSales),
      _Line('+ ${t('Extra-KG billing')}', p.bulkSales),
      _Line(
        '= ${t('Sales')}',
        p.sales,
        total: true,
        detail: p.soldGrams == 0
            ? null
            : t('{kg} KG of gas sold').replaceAll('{kg}', kg(p.soldGrams)),
      ),
      _Line(
        '− ${t('Cost of gas sold')}',
        p.cost,
        detail: t('Purchase price, oldest stock first (FIFO)'),
      ),
      if (p.waitingGrams != 0)
        unknown(
          'Negative stock (gas sold before its purchase)',
          p.waitingGrams,
          p.waitingCost,
          settings.waiting,
          'waiting',
        ),
      if (p.noCostGrams != 0)
        unknown(
          'Stock entered without cost',
          p.noCostGrams,
          p.noCostCost,
          settings.noCost,
          'no-cost',
        ),
      _Line('= ${t('Gross profit')}', p.gross, total: true),
      _Line(
        '− ${t('Hospitality')}',
        p.hospitality,
        detail: rates.isEmpty
            ? '${rs(settings.hospitalityOn(app.selectedDate))} $perTon (1000 KG)'
            : '${tons(p.soldGrams)} ${t('ton')} × '
                  '${rates.map(rs).join(' / ')} $perTon',
        action: button(
          'Change',
          Icons.edit_outlined,
          const ValueKey('profit-hospitality'),
          () => editHospitality(context, app),
        ),
      ),
      _Line('− ${t('Office kharcha')}', p.office),
      for (final MapEntry(key: category, value: amount) in p.expenses.entries)
        if (amount != 0) _Line('− ${t(expenseLabel(category))}', amount),
      _Line(
        '= ${t('Net profit')}',
        p.net,
        total: true,
        color: p.net < 0 ? rozRed : teal,
      ),
    ];
    final notes = <(String, Widget?)>[
      if (p.unpricedGrams > 0)
        (
          t('Profit is incomplete: {kg} KG have no purchase price.')
              .replaceAll('{kg}', kg(p.unpricedGrams)),
          priceButton('note'),
        ),
      if (p.sharedGrams != 0)
        (
          t(
            'Purchase shares ({kg} KG) are at cost: not in sales, cost or hospitality.',
          ).replaceAll('{kg}', kg(p.sharedGrams)),
          null,
        ),
      if (p.estimated != 0)
        (
          t(
            'Gas without a purchase price is counted at your price until its purchase is entered. The khata does not change.',
          ),
          null,
        ),
      if (p.historical)
        (t('Historical summaries make profit provisional.'), null),
    ];
    final from = this.from, to = this.to;
    final period = from != null && to != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (period) ProfitViewChoice(app),
        for (final l in lines) _LineRow(l),
        for (final (text, action) in notes) _Note(text, action),
        if (notes.isNotEmpty) const SizedBox(height: 10),
        if (period && app.profitDetailed) PositionLines(app, from, to),
      ],
    );
  }
}

/// Simple or Detailed: the profit alone, or also what the business has and
/// why (asked for by the user on 21 November 2026). One choice for both
/// profit sections and the Profit report they open.
class ProfitViewChoice extends StatelessWidget {
  final AppController app;
  const ProfitViewChoice(this.app, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xffe9eee8))),
    ),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (detailed, name, label) in [
          (false, 'Simple', context.t('Simple')),
          (true, 'Detailed', context.t('Detailed')),
        ])
          ChoiceChip(
            key: ValueKey('profit-view-$name'),
            label: Text(label),
            selected: app.profitDetailed == detailed,
            onSelected: (_) => app.setProfitDetailed(detailed),
          ),
        if (!app.profitDetailed)
          Text(
            context.t(
              'Detailed adds cash, banks, pendings and stock: how much we have, and why.',
            ),
            style: const TextStyle(fontSize: 11.5, color: muted),
          ),
      ],
    ),
  );
}

/// The heading of a part of the detailed profit, with what it shows.
class _PartHeading extends StatelessWidget {
  final String title;
  final String? intro;
  const _PartHeading(this.title, [this.intro, Key? key]) : super(key: key);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(11, 12, 11, 8),
    decoration: const BoxDecoration(
      color: rozSoft2,
      border: Border(bottom: BorderSide(color: Color(0xffe9eee8))),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        if (intro != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              intro!,
              style: const TextStyle(fontSize: 11.5, color: muted),
            ),
          ),
      ],
    ),
  );
}

/// The Detailed part of a profit section ([from] to [to]): what the business
/// has at the end of [to], line by line with what each figure is and why it
/// is added or taken off, then how the profit of the period took what it had
/// at the end of the day before [from] to that.
class PositionLines extends StatelessWidget {
  final AppController app;
  final String from, to;
  const PositionLines(this.app, this.from, this.to, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t, words = context.words;
    final change = app.positionChange(from, to);
    final (have, notes) = whatWeHaveLines(
      change.end,
      app.profitSettings,
      words,
      rs: rs,
      name: app.name,
      date: dmy,
    );
    final bridge = whyLines(change, words, date: dmy);
    var prices = 0;
    _Line line(PositionLine l) => _Line(
      l.label,
      l.amount,
      detail: l.detail,
      total: l.total,
      color: l.total ? ((l.amount ?? 0) < 0 ? rozRed : teal) : null,
      action: l.price
          ? _lineButton(
              context,
              'Purchase price',
              Icons.price_change_outlined,
              ValueKey('position-price-${prices++}'),
              () => editGasPrices(context, app),
            )
          : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PartHeading(
          t('What we have at the end of {date}').replaceAll('{date}', dmy(to)),
          t(
            'Everything the business has, less everything it still has to pay.',
          ),
          const ValueKey('position-have'),
        ),
        for (final l in have) _LineRow(line(l)),
        for (final note in notes) _Note(note),
        if (notes.isNotEmpty) const SizedBox(height: 10),
        _PartHeading(
          t('Why: how profit became what we have'),
          t(
            'Profit is what you earned. What we have is where the money is now. This joins the two.',
          ),
          const ValueKey('position-why'),
        ),
        for (final l in bridge) _LineRow(line(l)),
      ],
    );
  }
}

/// The Stock page's profit: the same lines for the top bar's day, its month
/// or every entry up to it.
/// A small "Report" button that opens one report's PDF preview for a range,
/// as the Reports page would build it: on the Roznamcha's Hisab Mel (the
/// day's Cash book) and on the profit sections (the Profit report).
class ReportButton extends StatelessWidget {
  final AppController app;
  final String kind, from, to;
  const ReportButton(this.app, this.kind, this.from, this.to, {super.key});

  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    onPressed: () {
      // The Profit report follows the profit sections' Simple / Detailed
      // choice, and its preview's Detailed switch changes that choice.
      final profit = kind == 'Profit report';
      previewReport(
        context,
        buildReport(
          app,
          kind,
          from,
          to,
          urdu: app.urdu,
          detailed: profit && app.profitDetailed,
        ),
        onCompact: profit ? app.setProfitDetailed : null,
      );
    },
    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
    label: Text(
      context.t('Report'),
      semanticsLabel: context.t(kind),
    ),
  );
}

class StockProfit extends StatelessWidget {
  final AppController app;
  const StockProfit(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final (from, to) = app.profitPeriod.range(app.selectedDate);
    final profit = app.profit(from, to);
    return Panel(
      padding: const EdgeInsets.fromLTRB(11, 18, 11, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: SectionHeader(
              'How profit is calculated',
              action: Text(
                rs(profit.net),
                key: const ValueKey('stock-profit-net'),
                textDirection: TextDirection.ltr,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: profit.net < 0 ? rozRed : teal,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 0, 11, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final period in ProfitPeriod.values)
                  ChoiceChip(
                    key: ValueKey('profit-period-${period.name}'),
                    label: Text(context.t(period.label)),
                    selected: app.profitPeriod == period,
                    onSelected: (_) => app.setProfitPeriod(period),
                  ),
                if (app.profitPeriod == ProfitPeriod.all)
                  Text(
                    context.t('Up to {date}').replaceAll('{date}', dmy(to)),
                    style: const TextStyle(fontSize: 12, color: muted),
                  )
                else
                  Text(
                    from == to ? dmy(to) : '${dmy(from)} – ${dmy(to)}',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                ReportButton(
                  app,
                  'Profit report',
                  from,
                  to,
                  key: const ValueKey('stock-profit-report'),
                ),
              ],
            ),
          ),
          ProfitLines(app, profit, from: from, to: to),
        ],
      ),
    );
  }
}

/// The purchase price for gas the khata has no cost for: gas sold before its
/// purchase was entered (negative stock), and gas sold from stock entered
/// without a cost. Profit counts it at this price until the purchase (or the
/// stock's cost) is entered; no entry, balance or stock figure changes.
Future<void> editGasPrices(BuildContext context, AppController app) async {
  final settings = app.profitSettings;
  final (waiting, lots) = gasWithoutCost(app.book);
  final lastPurchase = app.book.documents
      .where((d) => d.type == EntryType.purchase)
      .lastOrNull;
  final defaultUnit = GasPrice.units.contains(lastPurchase?.value('rateUnit'))
      ? lastPurchase!.value('rateUnit')
      : 11800;
  final fields = {
    for (final (key, price) in [
      ('waiting', settings.waiting),
      ('noCost', settings.noCost),
    ])
      key: TextEditingController(
        text: price == null ? '' : decimalText(price.rate, 2),
      ),
  };
  final units = {
    'waiting': settings.waiting?.unit ?? defaultUnit,
    'noCost': settings.noCost?.unit ?? defaultUnit,
  };
  // Only what has no cost now is asked for: negative stock while gas still
  // waits for its purchase, stock entered without a cost while gas sold from
  // it has none. A saved price that is not asked for is kept as it is.
  final showWaiting = waiting > 0, showNoCost = lots.isNotEmpty;
  final lotNames = [
    for (final MapEntry(key: id, value: grams) in lots.entries.take(3))
      if (app.record(id) case final r?)
        '${entryTitle(app, Document(r), context.words)}'
            '${Document(r).note.trim().isEmpty ? '' : ' "${Document(r).note.trim()}"'}'
            ' · ${dmy(Document(r).date)}'
            '${lots.length > 1 ? ' (${kg(grams)} KG)' : ''}',
  ];
  final lotGrams = lots.values.fold(0, (v, g) => v + g);
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final t = ctx.t;
        Widget section(String key, String title, String text, int grams) {
          var preview = '';
          try {
            final rate = decimal(fields[key]!.text, 2);
            if (rate > 0 && grams > 0) {
              preview =
                  '= ${t('{amount} for {kg} KG').replaceAll('{amount}', rs(GasPrice(rate, units[key]!).cost(grams))).replaceAll('{kg}', kg(grams))}';
            }
          } catch (_) {}
          return Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(title),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(fontSize: 12.5, color: muted),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('gas-price-$key'),
                        controller: fields[key],
                        textDirection: TextDirection.ltr,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(labelText: t('Rate')),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButton<int>(
                      key: ValueKey('gas-unit-$key'),
                      value: units[key],
                      onChanged: (v) => setState(() => units[key] = v!),
                      items: [
                        for (final unit in GasPrice.units)
                          DropdownMenuItem(
                            value: unit,
                            child: Text(t(priceUnit(unit))),
                          ),
                      ],
                    ),
                  ],
                ),
                if (preview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      preview,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: teal,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }

        return AlertDialog(
          title: Text(t('Purchase price for profit')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t(
                      'Profit counts gas that has no purchase price in the khata at the price you enter here, until its purchase is entered. Balances, stock and entries do not change.',
                    ),
                    style: const TextStyle(fontSize: 12.5, color: ink),
                  ),
                  if (showWaiting)
                    section(
                      'waiting',
                      'Negative stock (gas sold before its purchase)',
                      t('{kg} KG were sold before their purchase was entered.')
                          .replaceAll('{kg}', kg(waiting)),
                      waiting,
                    ),
                  if (showNoCost)
                    section(
                      'noCost',
                      'Stock entered without cost',
                      '${t('{kg} KG were sold from stock entered without a cost:').replaceAll('{kg}', kg(lotGrams))} ${lotNames.join(', ')}',
                      lotGrams,
                    ),
                  if (showWaiting || showNoCost)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        t('Leave a rate empty to remove its price.'),
                        style: const TextStyle(fontSize: 11.5, color: muted),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        t(
                          'All gas sold has its purchase price now. There is nothing to enter.',
                        ),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: teal,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(showWaiting || showNoCost ? t('Cancel') : t('Close')),
            ),
            if (showWaiting || showNoCost)
              FilledButton(
                key: const ValueKey('gas-price-save'),
                onPressed: () async {
                  final ok = await perform(ctx, () async {
                    GasPrice? read(String key, GasPrice? old) {
                      final rate = decimal(fields[key]!.text, 2);
                      if (rate < 0) {
                        throw const FormatException(
                          'Amounts and quantities cannot be negative',
                        );
                      }
                      if (rate == 0) return null;
                      final unit = units[key]!;
                      return old != null && old.rate == rate && old.unit == unit
                          ? old
                          : GasPrice(rate, unit, setOn: businessDate());
                    }

                    await app.saveProfitSettings(
                      settings.withPrices(
                        waiting: showWaiting
                            ? read('waiting', settings.waiting)
                            : settings.waiting,
                        noCost: showNoCost
                            ? read('noCost', settings.noCost)
                            : settings.noCost,
                      ),
                    );
                  }, success: 'Saved');
                  if (ok && ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(t('Save')),
              ),
          ],
        );
      },
    ),
  );
  // Dialog route animations can still reference its controllers for a frame.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final f in fields.values) {
    f.dispose();
  }
}

/// Hospitality per ton (1000 KG) of gas sold. A new rate applies from the
/// top bar's day on, so earlier days keep theirs, unless "Earlier days too"
/// is on (the first time it is set, it is).
Future<void> editHospitality(BuildContext context, AppController app) async {
  final settings = app.profitSettings;
  final date = app.selectedDate;
  final field = TextEditingController(
    text: decimalText(settings.hospitalityOn(date), 2),
  );
  var allDays = !settings.hospitalitySaved;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final t = ctx.t;
        final schedule = [
          for (final (from, rate) in settings.hospitality)
            '${from.isEmpty ? t('From the start') : t('From {date}').replaceAll('{date}', dmy(from))}: ${rs(rate)}',
        ];
        return AlertDialog(
          title: Text(t('Hospitality')),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t(
                      'Paid on every ton (1000 KG) of gas sold. Purchase shares are not counted.',
                    ),
                    style: const TextStyle(fontSize: 12.5, color: ink),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('hospitality-rate'),
                    controller: field,
                    autofocus: true,
                    textDirection: TextDirection.ltr,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: t('Rs per ton (1000 KG)'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey('hospitality-all-days'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('Earlier days too')),
                    subtitle: Text(
                      allDays
                          ? t('For every day')
                          : t('From {date} on; earlier days keep their rate')
                                .replaceAll('{date}', dmy(date)),
                    ),
                    value: allDays,
                    onChanged: (v) => setState(() => allDays = v),
                  ),
                  if (schedule.length > 1)
                    Text(
                      schedule.join(' · '),
                      style: const TextStyle(fontSize: 11.5, color: muted),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t('Cancel')),
            ),
            FilledButton(
              key: const ValueKey('hospitality-save'),
              onPressed: () async {
                final ok = await perform(ctx, () async {
                  final rate = decimal(field.text, 2);
                  if (rate < 0) {
                    throw const FormatException(
                      'Amounts and quantities cannot be negative',
                    );
                  }
                  await app.saveProfitSettings(
                    settings.withHospitality(rate, allDays ? '' : date),
                  );
                }, success: 'Saved');
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(t('Save')),
            ),
          ],
        );
      },
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  field.dispose();
}

/// The warnings of [book] for the Roznamcha and Stock pages: "Profit is
/// incomplete" becomes "Profit uses your purchase price" once the user's
/// prices cover the gas it has without a cost ([profitPriced]).
List<String> stockWarnings(AppController app, Book book) {
  final warnings = book.warnings;
  if (!warnings.contains('Profit is incomplete') ||
      !profitPriced(book, app.profitSettings)) {
    return warnings;
  }
  return [
    for (final w in warnings)
      w == 'Profit is incomplete' ? 'Profit uses your purchase price' : w,
  ];
}

/// Whether some gas sold has no purchase price in the khata now (still
/// waiting for its purchase, or from stock entered without a cost): only then
/// do the warnings line and the Stock page offer the Purchase price button.
bool needsGasPrice(AppController app) {
  final (waiting, lots) = gasWithoutCost(app.book);
  return waiting > 0 || lots.isNotEmpty;
}
