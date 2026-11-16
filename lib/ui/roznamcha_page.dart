import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../core/controller.dart';
import '../core/models.dart';
import '../features/ledger/roznamcha.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'details.dart';
import 'entry_composer.dart';
import 'export_ui.dart';
import 'masters.dart';
import 'opening_balance.dart';
import 'pages.dart';
import 'roznamcha_form.dart';
import 'roznamcha_widgets.dart';

/// The daily cash book, laid out like the original HTML Roznamcha:
/// summary cards, "Naya Entry" tabs, A: Aamad / Wasooli, B: Kharcha and
/// Hisab Mel. Every figure comes from the immutable ledger.
class RoznamchaPage extends StatefulWidget {
  final AppController app;
  const RoznamchaPage(this.app, {super.key});
  @override
  State<RoznamchaPage> createState() => _RoznamchaPageState();
}

class _Col {
  final String label;
  final int flex;
  final bool end, center;
  const _Col(this.label, this.flex, {this.end = false, this.center = false});
}

const _aCols = [
  _Col('#', 3),
  _Col('Parchi', 5),
  _Col('Customer / Party', 16),
  _Col('11.8k', 4, center: true),
  _Col('15k', 4, center: true),
  _Col('45k', 4, center: true),
  _Col('Rate', 6, end: true),
  _Col('Bill', 8, end: true),
  _Col('Cash Wasooli', 8, end: true),
  _Col('Bank Wasooli', 11, end: true),
  _Col('Kul Wasooli', 8, end: true),
  _Col('Action', 10, center: true),
];

/// "Direct to Party": what a customer paid straight to a company. Its column
/// sits between Bank Wasooli and Kul Wasooli, and only on a day that has any.
const _aDirect = _Col('Direct to Party', 10, end: true);

const _bCols = [
  _Col('#', 3),
  _Col('Type', 12),
  _Col('Bank / Mode', 11),
  _Col('Raqam', 9, end: true),
  _Col('Party', 13),
  _Col('Tafseel', 20),
  _Col('Action', 9, center: true),
];

const _cellStyle = TextStyle(fontSize: 12.5, color: ink);
const _boldStyle = TextStyle(
  fontSize: 12.5,
  color: ink,
  fontWeight: FontWeight.w700,
);
const _inStyle = TextStyle(
  fontSize: 12.5,
  color: teal,
  fontWeight: FontWeight.w700,
);
const _outStyle = TextStyle(
  fontSize: 12.5,
  color: amber,
  fontWeight: FontWeight.w700,
);
const _mutedStyle = TextStyle(fontSize: 11.5, color: muted);

class _RoznamchaPageState extends State<RoznamchaPage> {
  final formKey = GlobalKey<RoznamchaFormState>();
  final entryKey = GlobalKey();
  final rateField = TextEditingController();
  bool showAll = false, hisabOpen = true;

  AppController get app => widget.app;

  @override
  void dispose() {
    rateField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: app, builder: (context, _) => _page());

  Widget _page() {
    final date = app.selectedDate;
    final book = app.bookAt(date);
    final dayDocs = book.documents.where((d) => d.date == date).toList();
    final closing = book.money('cash');
    final opening = closing - book.dayMovement(date, 'money:cash');
    final full = RoznamchaDay(date, opening, dayDocs);
    final batch = app.batchStarts[date];
    bool early(Document d) =>
        batch != null && integer(d.data['occurredAt']) < batch;
    final batched = batch != null && !showAll && dayDocs.any(early);
    final day = batched
        ? RoznamchaDay(
            date,
            RoznamchaDay(date, opening, dayDocs.where(early)).safi,
            dayDocs.where((d) => !early(d)),
          )
        : full;
    final q = app.search.trim().toLowerCase();
    final hasGas = app.book.documents.any(
      (d) =>
          d.type == EntryType.purchase || d.type == EntryType.stockAdjustment,
    );
    final gasOpen = book.gasGrams - full.gasIn + full.gasOut;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(day, dayDocs),
        ..._notices(book.warnings, batch, batched, day, closing),
        if (app.book.documents.isEmpty) _onboarding(),
        _strip(day, hasGas, gasOpen, full, book.gasGrams),
        const SizedBox(height: 14),
        _stats(day, full, dayDocs),
        const SizedBox(height: 16),
        KeyedSubtree(
          key: entryKey,
          child: RozPanel(
            title: 'New entry',
            subtitle: 'Pehle chuno kya karna hai, phir sirf wahi form khulega.',
            child: RoznamchaForm(key: formKey, app: app),
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, box) {
            final a = _aPanel(day, q), b = _bPanel(day, q);
            return box.maxWidth >= 1300
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 115, child: a),
                      const SizedBox(width: 14),
                      Expanded(flex: 100, child: b),
                    ],
                  )
                : Column(children: [a, const SizedBox(height: 16), b]);
          },
        ),
        const SizedBox(height: 16),
        _hisabMel(day),
        if (full.other.isNotEmpty) ...[
          const SizedBox(height: 16),
          RozPanel(
            title: 'Baqi entries (gas, stock, transfer)',
            subtitle: 'Yeh entries Roznamcha ke cash hisab se bahar hain.',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  for (final d in full.other.where((d) => _match(d, q)))
                    TransactionTile(app, d),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---------- header and notices ----------

  Widget _heading(RoznamchaDay day, List<Document> dayDocs) {
    final date = app.selectedDate;
    final closed = app.isClosed(date);
    return PageHeading(
      'Roznamcha',
      DateFormat('EEEE, d MMMM y', app.language).format(DateTime.parse(date)),
      actions: [
        // One group, so the buttons wrap together instead of one by one.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: context.t('Pichla din'),
                  onPressed: () => app.setDate(nextDate(date, -1)),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                  onPressed: () async {
                    final v = await pickDate(context, date);
                    if (v != null) app.setDate(v);
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(dmy(date), textDirection: TextDirection.ltr),
                ),
              ],
            ),
            FilledButton.icon(
              onPressed: () => _nextDay(day, dayDocs),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(context.t('Agla Din')),
            ),
            OutlinedButton.icon(
              onPressed: () => _saveRoz(dayDocs),
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: Text(context.t('Roznamcha Save')),
            ),
            PopupMenuButton<String>(
              tooltip: context.t('More'),
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) => _menu(v, closed),
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'print',
                  child: Text(ctx.t('Print / PDF')),
                ),
                PopupMenuItem(
                  value: 'history',
                  child: Text(ctx.t('Day history')),
                ),
                PopupMenuItem(
                  value: 'batch',
                  child: Text(ctx.t('Khata Saaf (naya batch)')),
                ),
                PopupMenuItem(
                  value: 'count',
                  child: Text(ctx.t('Cash reconciliation')),
                ),
                PopupMenuItem(
                  value: 'close',
                  child: Text(ctx.t(closed ? 'Reopen day' : 'Close day')),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _notices(
    List<String> warnings,
    int? batch,
    bool batched,
    RoznamchaDay day,
    int closing,
  ) => [
    if (app.isClosed(app.selectedDate)) const Notice('Day is closed'),
    if (app.conflictCount > 0)
      Notice(
        '${context.t('Review changes')}: ${app.conflictCount}',
        action: TextButton(
          onPressed: () => app.go('settings'),
          child: Text(context.t('View all')),
        ),
      ),
    // Stock warnings in one short line, so the day's entries stay on top.
    if (warnings.isNotEmpty)
      Notice(
        warnings.map(context.t).join(' · '),
        action: TextButton(
          onPressed: () => app.go('stock'),
          child: Text(context.t('Stock')),
        ),
      ),
    if (batch != null)
      Notice(
        batched
            ? '${context.t('Khata saaf kiya gaya, naya batch')} ${DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(batch))}. ${context.t('Pehle ki entries Opening mein shamil hain.')}'
            : context.t('Poora din dikh raha hai.'),
        action: TextButton(
          onPressed: () => setState(() => showAll = !showAll),
          child: Text(
            context.t(batched ? 'Poora din dikhao' : 'Sirf naya batch'),
          ),
        ),
      ),
    if (day.safi != closing)
      Notice('${context.t('Hisab farq')}: ${rs(day.safi)} ≠ ${rs(closing)}'),
  ];

  Widget _onboarding() => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Panel(
      child: EmptyState(
        'Start with your opening balances',
        'Add parties, accounts and stock to begin.',
        action: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => editMaster(context, app, 'party'),
              child: Text(context.t('Add party')),
            ),
            OutlinedButton(
              onPressed: () => editMaster(context, app, 'account'),
              child: Text(context.t('Add account')),
            ),
            OutlinedButton(
              onPressed: () =>
                  composeEntry(context, app, type: EntryType.stockAdjustment),
              child: Text(context.t('Gas stock')),
            ),
            TextButton(
              onPressed: () => editOpeningBalance(context, app),
              child: Text(context.t('Opening cash')),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _box(List<Widget> children) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: rozBorder),
    ),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: children,
    ),
  );

  Widget _strip(
    RoznamchaDay day,
    bool hasGas,
    int gasOpen,
    RoznamchaDay full,
    int gasClose,
  ) {
    // The opening is always the previous day's closing. Cash entered as an
    // adjustment on this day (the starting cash, a cash count) is added here.
    final shown = day.opening + day.cashAdj;
    final cashOnly = day.openings.where(
      (d) => d.data['target'] == 'money:cash',
    );
    // Starting cash is entered once; later mistakes are fixed with ✏️.
    final needsCash =
        app.book.documents.isNotEmpty &&
        !app.isClosed(app.selectedDate) &&
        !app.book.documents.any(
          (d) =>
              d.type == EntryType.adjustment &&
              d.data['target'] == 'money:cash',
        );
    String gas(int g) => g < 0 ? '${context.t('Udhar')} ${kg(-g)}' : kg(g);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _box([
          Text(
            '${context.t('Opening (sabiqa)')}:',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted,
            ),
          ),
          Text(
            rs(shown),
            key: const ValueKey('roz-opening'),
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: teal,
            ),
          ),
          if (day.wd > 0)
            Text(
              '+ ${context.t('Bank se Nikali')} ${money(day.wd)} = ${money(shown + day.wd)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          if (day.cashAdj != 0 && day.opening != 0)
            Text(
              '(${context.t('pichla closing')} ${money(day.opening)}, ${context.t(cashOnly.every(isOpeningBalance) ? 'Opening cash' : 'Adjustment')} ${day.cashAdj > 0 ? '+' : ''}${money(day.cashAdj)})',
              style: _mutedStyle,
            ),
          if (needsCash)
            TextButton(
              key: const ValueKey('roz-opening-cash'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => editOpeningBalance(context, app),
              child: Text(context.t('Opening cash daalein')),
            ),
        ]),
        _box([
          Text(
            '${context.t('Gas (KG)')}:',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted,
            ),
          ),
          if (hasGas)
            Text(
              '${context.t('Opening')} ${gas(gasOpen)} + ${kg(full.gasIn)} − ${kg(full.gasOut)} = ${gas(gasClose)}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            )
          else
            Text(context.t('Gas opening daalein'), style: _outStyle),
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () =>
                composeEntry(context, app, type: EntryType.stockAdjustment),
            child: Text(context.t('Gas stock')),
          ),
        ]),
      ],
    );
  }

  // ---------- summary cards ----------

  Widget _stats(RoznamchaDay day, RoznamchaDay full, List<Document> docs) {
    final t = context.t;
    final cards = [
      RozStat(
        'A: Aamad (Opening + Wasooli + Nikali)',
        rs(day.left),
        sub:
            '${t('Cash')} ${money(day.cashIn)} · ${t('Bank')} ${money(day.bankCust)}${day.direct > 0 ? ' · ${t('Direct')} ${money(day.direct)}' : ''} · ${t('Nikali')} ${money(day.wd)}',
      ),
      RozStat(
        'B: Kharcha + Bank Jama',
        rs(day.rightTotal),
        color: amber,
        sub:
            '${t('Kharcha (cash)')} ${money(day.kharchaCash)} · ${t('Bank jama')} ${money(day.bankCust + day.depMan)}${day.direct > 0 ? ' · ${t('Direct')} ${money(day.direct)}' : ''}${day.kharchaBank > 0 ? ' · ${t('Bank se diye')} ${money(day.kharchaBank)}' : ''}',
      ),
      RozStat(
        'Safi Baqaya = A − B (Cash in Hand)',
        rs(day.safi),
        color: amber,
        key: const ValueKey('roz-safi'),
        sub:
            '${t('Cash')}: ${money(day.safi)} · ${t('Bank (aaj)')}: ${day.bankNet > 0 ? '+' : ''}${money(day.bankNet)}',
      ),
      RozStat(
        'Total Gas Dispatch (KG)',
        '${kg(day.dispatchGrams)} kg',
        sub: [
          for (final s in sizes) '${sizeLabel(s)}: ${day.cylinders[s]}',
          if (day.bulkGrams > 0) '${t('Bulk')} ${kg(day.bulkGrams)} kg',
        ].join(' · '),
      ),
      RozStat(
        'Calculated Bill',
        rs(day.bill),
        sub:
            '${t('Cylinder')} ${money(day.cylinderBill)} · ${t('Bulk')} ${money(day.bulkBill)}',
        extra: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('roz-bulk-rate'),
                  controller: rateField,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                  decoration: rozDecoration(t('Rate (e.g. 4640)')),
                  onSubmitted: (_) => _applyRate(full),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 13,
                  ),
                ),
                onPressed: () => _applyRate(full),
                child: Text(t('Lagayein')),
              ),
            ],
          ),
        ),
      ),
      if (day.sharedGrams > 0)
        RozStat(
          'Purchase shares',
          rs(day.shareAmount),
          sub:
              '${kg(day.sharedGrams)} kg · ${t('At FIFO cost; no sales profit')}',
        ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 1100
            ? 5
            : box.maxWidth >= 700
            ? 3
            : box.maxWidth >= 380
            ? 2
            : 1;
        final width = (box.maxWidth - 12 * (columns - 1)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ],
        );
      },
    );
  }

  // ---------- table helpers ----------

  Widget _cell(_Col col, Widget child) => Expanded(
    flex: col.flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Align(
        alignment: col.end
            ? AlignmentDirectional.centerEnd
            : col.center
            ? Alignment.center
            : AlignmentDirectional.centerStart,
        child: child,
      ),
    ),
  );

  Widget _span(int flex, Widget child, {bool end = false}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Align(
        alignment: end
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: child,
      ),
    ),
  );

  Widget _line(
    List<Widget> cells, {
    Color? color,
    VoidCallback? onTap,
    bool footer = false,
    bool firstFooter = false,
  }) {
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
      decoration: BoxDecoration(
        color: color ?? (footer ? rozSoft2 : null),
        border: Border(
          top: firstFooter
              ? const BorderSide(color: teal, width: 2)
              : BorderSide.none,
          bottom: const BorderSide(color: Color(0xffe9eee8)),
        ),
      ),
      child: Row(children: cells),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }

  Widget _header(List<_Col> cols) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
    decoration: const BoxDecoration(
      color: rozSoft,
      border: Border(bottom: BorderSide(color: rozBorder)),
    ),
    child: Row(
      children: [
        for (final c in cols)
          _cell(
            c,
            Text(
              context.t(c.label),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: c.end
                  ? TextAlign.end
                  : c.center
                  ? TextAlign.center
                  : TextAlign.start,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xff4b5b55),
                letterSpacing: .3,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _group(String text, {bool light = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    color: light ? rozSoft : rozSoft2,
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(child: Text(context.t(text), style: _mutedStyle)),
  );

  Widget _num(String text, {TextStyle style = _cellStyle}) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, textDirection: TextDirection.ltr, style: style),
  );

  String _dash(int v) => v == 0 ? '—' : money(v);

  Widget _actions(Document d, {bool khata = false}) {
    final closed = app.isClosed(d.date);
    final party = app.record(d.party);
    Widget button(IconData icon, String tip, VoidCallback? onPressed) =>
        IconButton(
          tooltip: context.t(tip),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          iconSize: 17,
          color: teal,
          onPressed: onPressed,
          icon: Icon(icon),
        );
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(Icons.edit_outlined, 'Edit', closed ? null : () => _edit(d)),
          button(
            Icons.delete_outline_rounded,
            'Delete',
            closed ? null : () => _delete(d),
          ),
          if (khata && party != null)
            button(
              Icons.menu_book_outlined,
              'Khata',
              () => showParty(context, app, party),
            ),
        ],
      ),
    );
  }

  bool _match(Document d, String q) {
    if (q.isEmpty) return true;
    return [
      app.name(d.party),
      '${d.data['vehicle'] ?? ''}',
      d.note,
      d.reference,
      for (final l in d.bankLines) ...[
        if (l.account.isNotEmpty) app.name(l.account),
        if (l.party.isNotEmpty) app.name(l.party),
        l.bankName,
      ],
      app.name(d.account),
      if (d.data['toAccount'] != null) app.name('${d.data['toAccount']}'),
    ].join(' ').toLowerCase().contains(q);
  }

  (int, int, String) _inflow(Document d) => d.type == EntryType.deposit
      ? d.account == 'cash'
            ? (d.value('amount'), 0, '')
            : (0, d.value('amount'), d.account)
      : (d.value('cash'), d.bankIn, d.bankAccount);

  List<String> _directBadges(Document d) => [
    for (final party in d.directParties)
      [
        app.name(party),
        ...{
          for (final l in d.bankLines)
            if (l.direct && l.party == party && l.bankName.trim().isNotEmpty)
              l.bankName.trim(),
        },
      ].join(' · '),
  ];

  int _qty(Document d, int size) =>
      integer((d.data['quantities'] as Map?)?['$size']);

  String _accountName(String id) {
    final r = app.record(id);
    if (r == null) return id;
    return id == 'cash' ? context.t('Cash') : accountLabel(r);
  }

  String _entries(int n) => '$n ${context.t(n == 1 ? 'entry' : 'entries')}';

  /// A name or note with Urdu, isolated inside a longer text: otherwise two
  /// Urdu names around the arrow run together and swap sides.
  String _iso(String s) => hasUrduScript(s)
      ? '${String.fromCharCode(app.urdu ? 0x2067 : 0x2066)}$s${String.fromCharCode(0x2069)}'
      : s;

  /// From whom to whom, pointing the way the page reads.
  String get _arrow => app.urdu ? '←' : '→';

  /// HTML "Entry wise (alag alag) / Customer wise (ikatha)" switch.
  Widget _viewToggle() {
    Widget segment(String label, bool on, bool value) => Material(
      color: on ? teal : Colors.white,
      child: InkWell(
        key: ValueKey('roz-view-$value'),
        onTap: () => setState(() => app.rozCustomerWise = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          child: Align(
            widthFactor: 1,
            child: Text(
              context.t(label),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : ink,
              ),
            ),
          ),
        ),
      ),
    );
    final customer = app.rozCustomerWise;
    // Flexible segments: on a narrow phone the two labels wrap onto two
    // lines instead of pushing the switch past the panel edge.
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: rozBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: segment('Entry wise (alag alag)', !customer, false),
            ),
            Flexible(child: segment('Customer wise (ikatha)', customer, true)),
          ],
        ),
      ),
    );
  }

  // ---------- A: Aamad / Wasooli ----------

  Widget _aPanel(RoznamchaDay day, String q) => RozPanel(
    title: 'A: Aamad / Wasooli',
    subtitle: 'Cash wasooli → Cash khata. Bank wasooli → Bank khata + us account mein jama.',
    actions: [_viewToggle()],
    child: LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 760;
        // The Direct to Party column appears only on a day that needs it.
        final direct = day.direct > 0;
        final rows = <Widget>[];
        final aamad = day.aamad.where((d) => _match(d, q)).toList();
        final groups = <String, List<Document>>{};
        for (final d in aamad) {
          (groups[app.rozCustomerWise ? d.party : d.id] ??= []).add(d);
        }
        var n = 0;
        for (final g in groups.values) {
          if (g.length > 1) rows.add(_aGroup(g, wide, direct));
          for (final d in g) {
            n++;
            rows.add(wide ? _aRow(d, n, direct) : _aCard(d, n));
          }
        }
        for (final d in [
          ...day.nikali,
          ...day.less,
          ...day.openings,
        ].where((d) => _match(d, q))) {
          rows.add(_aSpecial(d, wide, direct));
        }
        if (rows.isEmpty) rows.add(_empty('— Aamad khali hai —'));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              _header([
                ..._aCols.take(10),
                if (direct) _aDirect,
                ..._aCols.skip(10),
              ]),
            ...rows,
            ..._aFooter(day, wide, direct),
          ],
        );
      },
    ),
  );

  Widget _aGroup(List<Document> g, bool wide, bool direct) {
    int sum(int Function(Document) f) => g.fold(0, (v, d) => v + f(d));
    final cash = sum((d) => _inflow(d).$1), bank = sum((d) => _inflow(d).$2);
    final paid = sum((d) => d.direct);
    final bill = sum((d) => d.type == EntryType.sale ? d.bill : 0);
    final name = app.name(g.first.party);
    if (!wide) {
      return _group(
        '$name · ${_entries(g.length)} · ${context.t('Bill')} ${money(bill)} · ${context.t('Kul Wasooli')} ${money(cash + bank + paid)}',
      );
    }
    return _line(color: rozSoft2, [
      _cell(_aCols[0], const Icon(Icons.person_outline, size: 16)),
      _cell(_aCols[1], const SizedBox()),
      _cell(
        _aCols[2],
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(name, style: _boldStyle),
            RozBadge(_entries(g.length), outlined: true),
          ],
        ),
      ),
      for (final s in sizes)
        _cell(
          _aCols[3 + sizes.indexOf(s)],
          _num(_dash(sum((d) => _qty(d, s)) * 100), style: _boldStyle),
        ),
      _cell(_aCols[6], const SizedBox()),
      _cell(_aCols[7], _num(_dash(bill), style: _boldStyle)),
      _cell(_aCols[8], _num(_dash(cash), style: _boldStyle)),
      _cell(_aCols[9], _num(_dash(bank), style: _boldStyle)),
      if (direct) _cell(_aDirect, _num(_dash(paid), style: _boldStyle)),
      _cell(_aCols[10], _num(_dash(cash + bank + paid), style: _boldStyle)),
      _cell(_aCols[11], const SizedBox()),
    ]);
  }

  Widget _nameCell(Document d) {
    final company = rozFormOf(d) == RozForm.companyIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(app.name(d.party), style: _boldStyle),
            if (company) const RozBadge('Company wasooli', outlined: true),
            if (d.type == EntryType.deposit)
              const RozBadge('Deposit', outlined: true),
            if (d.record.pending && app.signedIn)
              const RozBadge('Pending', accent: true),
          ],
        ),
        if (d.extraGrams > 0)
          Text(
            '${context.t(d.bulkAtCost ? 'Purchase share (at cost)' : 'Bulk')} ${kg(d.extraGrams)} KG'
            '${app.shareSource(d).isEmpty ? '' : ' · ${app.shareSource(d)}'}',
            style: _mutedStyle,
          ),
        if (d.note.isNotEmpty)
          Text(
            d.note,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _mutedStyle,
          ),
      ],
    );
  }

  Widget _aRow(Document d, int n, bool direct) {
    final (cash, bank, account) = _inflow(d);
    final kul = cash + bank + d.direct;
    final sale = d.type == EntryType.sale;
    return _line(onTap: () => showTransaction(context, app, d), [
      _cell(_aCols[0], Text('$n', style: _boldStyle)),
      _cell(
        _aCols[1],
        Text(
          '${d.data['vehicle'] ?? ''}'.isEmpty ? '—' : '${d.data['vehicle']}',
          style: _cellStyle,
        ),
      ),
      _cell(_aCols[2], _nameCell(d)),
      for (final s in sizes)
        _cell(
          _aCols[3 + sizes.indexOf(s)],
          Text(_qty(d, s) == 0 ? '—' : '${_qty(d, s)}', style: _cellStyle),
        ),
      _cell(_aCols[6], _num(sale && !d.purchaseShare ? money(d.rate) : '—')),
      _cell(_aCols[7], _num(sale ? money(d.total) : '—', style: _boldStyle)),
      _cell(
        _aCols[8],
        _num(_dash(cash), style: cash > 0 ? _inStyle : _cellStyle),
      ),
      _cell(
        _aCols[9],
        bank > 0
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _num(money(bank), style: _inStyle),
                  if (d.type == EntryType.deposit)
                    RozBadge(_accountName(account)),
                  for (final id in {
                    for (final l in d.bankLines)
                      if (!l.direct) l.account,
                  })
                    RozBadge(_accountName(id)),
                ],
              )
            : const Text('—', style: _cellStyle),
      ),
      if (direct)
        _cell(
          _aDirect,
          d.direct > 0
              ? Column(
                  key: ValueKey('roz-direct-${d.id}'),
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _num(money(d.direct), style: _inStyle),
                    for (final label in _directBadges(d))
                      RozBadge(label, accent: true),
                  ],
                )
              : const Text('—', style: _cellStyle),
        ),
      _cell(
        _aCols[10],
        _num(_dash(kul), style: kul > 0 ? _inStyle : _cellStyle),
      ),
      _cell(_aCols[11], _actions(d, khata: true)),
    ]);
  }

  Widget _aCard(Document d, int n) {
    final (cash, bank, account) = _inflow(d);
    final sale = d.type == EntryType.sale;
    final parts = [
      if ('${d.data['vehicle'] ?? ''}'.isNotEmpty)
        '${context.t('Parchi')} ${d.data['vehicle']}',
      for (final s in sizes)
        if (_qty(d, s) > 0) '${sizeLabel(s)} × ${_qty(d, s)}',
      if (sale && !d.purchaseShare) '${context.t('Rate')} ${money(d.rate)}',
      if (sale) '${context.t('Bill')} ${money(d.total)}',
      if (cash > 0) '${context.t('Cash')} ${money(cash)}',
      if (bank > 0 && d.type == EntryType.deposit)
        '${context.t('Bank')} ${money(bank)} (${_accountName(account)})',
      for (final l in d.bankLines)
        l.direct
            ? '${context.t('Direct')} ${money(l.amount)} (${[app.name(l.party), if (l.bankName.isNotEmpty) l.bankName].join(' · ')})'
            : '${context.t('Bank')} ${money(l.amount)} (${_accountName(l.account)})',
    ];
    final kul = cash + bank + d.direct;
    return InkWell(
      onTap: () => showTransaction(context, app, d),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xffe9eee8))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 24, child: Text('$n', style: _boldStyle)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _nameCell(d),
                  const SizedBox(height: 3),
                  Text(parts.join(' · '), style: _mutedStyle),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  kul > 0 ? money(kul) : '—',
                  textDirection: TextDirection.ltr,
                  style: _inStyle.copyWith(fontSize: 14),
                ),
                _actions(d, khata: true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Bank se Nikali, Less and opening balance rows in the Aamad table.
  Widget _aSpecial(Document d, bool wide, bool direct) {
    final form = rozFormOf(d);
    final IconData icon;
    final String title;
    var detail = '';
    var billCol = '—', bankCol = '—', kulCol = '—';
    TextStyle kulStyle = _cellStyle;
    Color color;
    String? bankAccount;
    switch (form) {
      case RozForm.nikali:
        icon = Icons.account_balance_outlined;
        color = const Color(0xffeef6ef);
        title = context.t('Bank se Nikali (cash mein aaya)');
        bankAccount = d.account;
        kulCol = '+${money(d.value('amount'))}';
        kulStyle = _inStyle.copyWith(fontStyle: FontStyle.italic);
      case RozForm.less:
        icon = Icons.content_cut_outlined;
        color = const Color(0xfffdf5ea);
        final bank = d.type == EntryType.receipt;
        title = '${context.t('Less / Kami')} — ${app.name(d.party)}';
        detail = context.t(
          bank
              ? 'Bank deposit (account mein jama)'
              : 'Khata se minus (discount)',
        );
        if (bank) {
          bankAccount = d.bankAccount;
          bankCol = '−${money(d.value('bank') + d.value('cash'))}';
        } else {
          billCol = '−${money(d.value('amount'))}';
        }
      default:
        icon = Icons.tune_rounded;
        color = rozSoft;
        final target = '${d.data['target'] ?? ''}';
        final kind = target.startsWith('money:')
            ? 'Account'
            : target.startsWith('ap:')
            ? 'Company'
            : 'Customer';
        final id = target.contains(':')
            ? target.substring(target.indexOf(':') + 1)
            : d.party;
        final label = context.t(adjustmentLabel(d));
        title = target == 'money:cash'
            // "Cash kam" and "Cash zyada" already name the cash.
            ? (isOpeningBalance(d) ? '$label — ${context.t('Cash')}' : label)
            : '$label — ${target.startsWith('money:') ? _accountName(id) : app.name(id)} (${context.t(kind)})';
        final shown = target.startsWith('ap:')
            ? -d.value('amount')
            : d.value('amount');
        kulCol = '${shown > 0 ? '+' : ''}${money(shown)}';
        kulStyle = _cellStyle.copyWith(fontStyle: FontStyle.italic);
    }
    final description = Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(title, style: _boldStyle),
        if (bankAccount != null) RozBadge(_accountName(bankAccount)),
        if (detail.isNotEmpty) Text('· $detail', style: _cellStyle),
        if (rozNote(d).isNotEmpty) Text('· ${rozNote(d)}', style: _mutedStyle),
      ],
    );
    if (!wide) {
      return Container(
        color: color,
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(
          children: [
            SizedBox(width: 24, child: Icon(icon, size: 16, color: muted)),
            Expanded(child: description),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  [
                    kulCol,
                    billCol,
                    bankCol,
                  ].firstWhere((v) => v != '—', orElse: () => '—'),
                  textDirection: TextDirection.ltr,
                  style: billCol != '—' || bankCol != '—'
                      ? _outStyle
                      : kulStyle,
                ),
                _actions(d),
              ],
            ),
          ],
        ),
      );
    }
    return _line(color: color, onTap: () => showTransaction(context, app, d), [
      _cell(_aCols[0], Icon(icon, size: 16, color: muted)),
      _cell(_aCols[1], const Text('—', style: _cellStyle)),
      _span(16 + 4 + 4 + 4 + 6, description),
      _cell(
        _aCols[7],
        _num(billCol, style: billCol == '—' ? _cellStyle : _outStyle),
      ),
      _cell(_aCols[8], const Text('—', style: _cellStyle)),
      _cell(
        _aCols[9],
        _num(bankCol, style: bankCol == '—' ? _cellStyle : _outStyle),
      ),
      if (direct) _cell(_aDirect, const Text('—', style: _cellStyle)),
      _cell(_aCols[10], _num(kulCol, style: kulStyle)),
      _cell(_aCols[11], _actions(d)),
    ]);
  }

  List<Widget> _aFooter(RoznamchaDay day, bool wide, bool direct) {
    final t = context.t;
    final opening = day.opening + day.cashAdj;
    final lines = [
      (
        direct
            ? t('Aaj ki Wasooli (cash + bank + direct)')
            : t('Aaj ki Wasooli (cash + bank)'),
        money(day.wasooli),
      ),
      (
        '${t('Opening (sabiqa) + Bank se Nikali')} — ${t('Opening')} ${money(opening)} + ${t('Nikali')} ${money(day.wd)}',
        money(opening + day.wd),
      ),
      (t('Kul Aamad (Wasooli + Opening + Nikali)'), money(day.left)),
    ];
    if (!wide) {
      return [
        for (var i = 0; i < lines.length; i++)
          _line(footer: true, firstFooter: i == 0, [
            _span(3, Text(lines[i].$1, style: _boldStyle)),
            _span(
              1,
              _num(lines[i].$2, style: _boldStyle.copyWith(color: teal)),
              end: true,
            ),
          ]),
      ];
    }
    final style = _boldStyle.copyWith(color: teal);
    return [
      _line(footer: true, firstFooter: true, [
        _span(3 + 5 + 16, Text(lines[0].$1, style: style)),
        for (final s in sizes)
          _cell(
            _aCols[3 + sizes.indexOf(s)],
            _num('${day.cylinders[s]}', style: style),
          ),
        _cell(_aCols[6], const SizedBox()),
        _cell(_aCols[7], _num(money(day.totalBilled), style: style)),
        _cell(_aCols[8], _num(money(day.cashIn), style: style)),
        _cell(_aCols[9], _num(money(day.bankCust), style: style)),
        if (direct) _cell(_aDirect, _num(money(day.direct), style: style)),
        _cell(_aCols[10], _num(lines[0].$2, style: style)),
        _cell(_aCols[11], const SizedBox()),
      ]),
      for (final line in lines.skip(1))
        _line(footer: true, [
          _span(
            3 + 5 + 16 + 4 + 4 + 4 + 6 + 8 + 8 + 11 + (direct ? 10 : 0),
            Text(line.$1, style: style),
          ),
          _cell(_aCols[10], _num(line.$2, style: style)),
          _cell(_aCols[11], const SizedBox()),
        ]),
    ];
  }

  // ---------- B: Kharcha ----------

  static const _kharchaOrder = {
    RozForm.kharcha: 0,
    RozForm.office: 1,
    RozForm.companyPay: 2,
    RozForm.customerPay: 3,
    RozForm.udharWapsi: 4,
  };

  Widget _bPanel(RoznamchaDay day, String q) => RozPanel(
    title: 'B: Kharcha',
    accent: amber,
    subtitle: 'Customer ki bank wasooli yahan khud aati hai. Cash bank mein daalna ho to "Bank account mein jama" chunein.',
    child: LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 560;
        final t = context.t;
        final kharcha = day.kharcha.where((d) => _match(d, q)).toList()
          ..sort((a, b) {
            final order =
                (_kharchaOrder[rozFormOf(a)] ?? 2) -
                (_kharchaOrder[rozFormOf(b)] ?? 2);
            return order != 0
                ? order
                : b.value('amount').compareTo(a.value('amount'));
          });
        final jama = day.bankJama.where((l) => _match(l.document, q)).toList();
        final rows = <Widget>[];
        var n = 0;
        if (kharcha.isNotEmpty) {
          final total = kharcha.fold(0, (v, d) => v + d.value('amount'));
          final bank = kharcha
              .where((d) => d.account != 'cash')
              .fold(0, (v, d) => v + d.value('amount'));
          rows.add(
            _group(
              '${t('KHARCHA (Cash / Office / Company / Customer)')} — ${_entries(kharcha.length)} — Rs ${money(total)}${bank > 0 ? ' (${t('Cash')}: ${money(total - bank)} | ${t('Bank se')}: ${money(bank)})' : ''}',
            ),
          );
          for (final d in kharcha) {
            n++;
            rows.add(_bRow(d, n, wide));
          }
        }
        if (jama.isNotEmpty) {
          rows.add(
            _group(
              '${t('BANK JAMA (account wise)')} — ${_entries(jama.length)} — Rs ${money(jama.fold(0, (v, l) => v + l.amount))}',
            ),
          );
          final byAccount = <String, List<BankJamaLine>>{};
          for (final l in jama) {
            (byAccount[l.account] ??= []).add(l);
          }
          final accounts = byAccount.keys.toList()
            ..sort((a, b) {
              int sum(String k) =>
                  byAccount[k]!.fold(0, (v, l) => v + l.amount);
              final c = sum(b).compareTo(sum(a));
              return c != 0 ? c : _accountName(a).compareTo(_accountName(b));
            });
          for (final account in accounts) {
            final list = byAccount[account]!
              ..sort((a, b) => b.amount.compareTo(a.amount));
            rows.add(
              _group(
                '${_accountName(account)} — ${_entries(list.length)} — Rs ${money(list.fold(0, (v, l) => v + l.amount))}',
                light: true,
              ),
            );
            for (final l in list) {
              n++;
              rows.add(_jamaRow(l, n, wide));
            }
          }
        }
        // Paid by customers straight to a party: no cash moved, so it is in
        // B for the same reason the automatic bank jama is.
        final paid =
            day.directLines.where((l) => _match(l.document, q)).toList()
              ..sort((a, b) => b.amount.compareTo(a.amount));
        if (paid.isNotEmpty) {
          rows.add(
            _group(
              '${t('DIRECT TO PARTY (customer ne seedha party ko diye)')} — ${_entries(paid.length)} — Rs ${money(paid.fold(0, (v, l) => v + l.amount))}',
            ),
          );
          for (final d in paid) {
            n++;
            rows.add(_directRow(d, n, wide));
          }
        }
        if (rows.isEmpty) rows.add(_empty('— Kharcha khali hai —'));
        final safiText =
            '${t('Safi Baqaya')}: ${rs(day.safi)}${day.kharchaBank > 0 ? '  |  ${t('Bank se diye')}: ${rs(day.kharchaBank)} (${t('cash par asar nahi')})' : ''}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _header(_bCols),
            ...rows,
            if (wide)
              _line(footer: true, firstFooter: true, [
                _span(
                  3 + 12 + 11,
                  Text(
                    '${t(day.direct > 0 ? 'Kul Kharcha + Bank Jama + Direct' : 'Kul Kharcha + Bank Jama')}:',
                    style: _boldStyle.copyWith(color: amber),
                  ),
                ),
                _cell(
                  _bCols[3],
                  _num(
                    money(day.rightTotal),
                    style: _boldStyle.copyWith(color: amber),
                  ),
                ),
                _span(13 + 20 + 9, Text(safiText, style: _boldStyle)),
              ])
            else ...[
              _line(footer: true, firstFooter: true, [
                _span(
                  3,
                  Text(
                    t(
                      day.direct > 0
                          ? 'Kul Kharcha + Bank Jama + Direct'
                          : 'Kul Kharcha + Bank Jama',
                    ),
                    style: _boldStyle.copyWith(color: amber),
                  ),
                ),
                _span(
                  1,
                  _num(
                    money(day.rightTotal),
                    style: _boldStyle.copyWith(color: amber),
                  ),
                  end: true,
                ),
              ]),
              _line(footer: true, [
                _span(1, Text(safiText, style: _boldStyle)),
              ]),
            ],
          ],
        );
      },
    ),
  );

  Widget _bRow(Document d, int n, bool wide) {
    final payment = d.type == EntryType.payment;
    final company = rozFormOf(d) == RozForm.companyPay;
    final bank = d.account != 'cash';
    final party = d.party.isEmpty ? '—' : app.name(d.party);
    final details = [
      if (d.note.isNotEmpty) d.note,
      if (company &&
          '${d.data['customerNote'] ?? ''}${d.data['branch'] ?? ''}'.isNotEmpty)
        '${context.t('Customer')}: ${'${d.data['customerNote'] ?? ''}'.isEmpty ? '—' : d.data['customerNote']} · ${context.t('Branch')}: ${'${d.data['branch'] ?? ''}'.isEmpty ? '—' : d.data['branch']}',
      if (bank) '[${context.t('Bank se')}: ${_accountName(d.account)}]',
    ];
    if (!wide) {
      return InkWell(
        onTap: () => showTransaction(context, app, d),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xffe9eee8))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('$n', style: _boldStyle)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 3,
                      children: [
                        RozBadge(rozTypeLabel(d), accent: true),
                        RozBadge(bank ? _accountName(d.account) : 'Cash'),
                        if (payment || d.party.isNotEmpty)
                          Text(party, style: _boldStyle),
                      ],
                    ),
                    if (details.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(details.join(' · '), style: _mutedStyle),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    money(d.value('amount')),
                    textDirection: TextDirection.ltr,
                    style: _outStyle.copyWith(fontSize: 14),
                  ),
                  _actions(d),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return _line(onTap: () => showTransaction(context, app, d), [
      _cell(_bCols[0], Text('$n', style: _boldStyle)),
      _cell(_bCols[1], RozBadge(rozTypeLabel(d), accent: true)),
      _cell(_bCols[2], RozBadge(bank ? _accountName(d.account) : 'Cash')),
      _cell(_bCols[3], _num(money(d.value('amount')), style: _boldStyle)),
      _cell(
        _bCols[4],
        Text(
          party,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _cellStyle,
        ),
      ),
      _cell(
        _bCols[5],
        Text(
          details.isEmpty ? '—' : details.join(' · '),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: _cellStyle,
        ),
      ),
      _cell(_bCols[6], _actions(d)),
    ]);
  }

  Widget _jamaRow(BankJamaLine l, int n, bool wide) {
    final d = l.document;
    final detail = l.automatic
        ? '${context.t('Wasooli')} — ${_iso(app.name(d.party))} $_arrow ${_iso(_accountName(l.account))}'
        : (d.note.isEmpty
              ? '${context.t('Cash jama')} $_arrow ${_iso(_accountName(l.account))}'
              : d.note);
    final action = l.automatic
        ? Text(
            context.t('auto (Aamad se)'),
            textAlign: TextAlign.center,
            style: _mutedStyle,
          )
        : _actions(d);
    if (!wide) {
      return InkWell(
        onTap: () => showTransaction(context, app, d),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xffe9eee8))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('$n', style: _boldStyle)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      children: [
                        const RozBadge('Bank jama', outlined: true),
                        RozBadge(_accountName(l.account)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(detail, style: _mutedStyle),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    money(l.amount),
                    textDirection: TextDirection.ltr,
                    style: _inStyle.copyWith(fontSize: 14),
                  ),
                  action,
                ],
              ),
            ],
          ),
        ),
      );
    }
    return _line(onTap: () => showTransaction(context, app, d), [
      _cell(_bCols[0], Text('$n', style: _boldStyle)),
      _cell(_bCols[1], const RozBadge('Bank jama', outlined: true)),
      _cell(_bCols[2], RozBadge(_accountName(l.account))),
      _cell(_bCols[3], _num(money(l.amount), style: _boldStyle)),
      _cell(
        _bCols[4],
        Text(
          _accountName(l.account),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _cellStyle,
        ),
      ),
      _cell(
        _bCols[5],
        Text(
          detail,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: _cellStyle,
        ),
      ),
      _cell(_bCols[6], action),
    ]);
  }

  /// What a customer paid straight to a party, as a row of B. It comes from
  /// the Aamad entry, so it is corrected there (like an automatic bank jama).
  Widget _directRow(DirectLine l, int n, bool wide) {
    final d = l.document;
    final party = [
      app.name(l.party),
      if (l.bankName.isNotEmpty) l.bankName,
    ].join(' · ');
    final detail =
        '${context.t('Wasooli')} — ${_iso(app.name(d.party))} $_arrow ${_iso(party)}${d.note.isEmpty ? '' : ' · ${_iso(d.note)}'}';
    final action = Text(
      context.t('auto (Aamad se)'),
      textAlign: TextAlign.center,
      style: _mutedStyle,
    );
    if (!wide) {
      return InkWell(
        onTap: () => showTransaction(context, app, d),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xffe9eee8))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('$n', style: _boldStyle)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 3,
                      children: [
                        const RozBadge('Direct to Party', accent: true),
                        RozBadge(
                          l.bankName.isEmpty ? 'Customer se' : l.bankName,
                        ),
                        Text(party, style: _boldStyle),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(detail, style: _mutedStyle),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    money(l.amount),
                    textDirection: TextDirection.ltr,
                    style: _outStyle.copyWith(fontSize: 14),
                  ),
                  action,
                ],
              ),
            ],
          ),
        ),
      );
    }
    return _line(onTap: () => showTransaction(context, app, d), [
      _cell(_bCols[0], Text('$n', style: _boldStyle)),
      _cell(_bCols[1], const RozBadge('Direct to Party', accent: true)),
      _cell(
        _bCols[2],
        RozBadge(l.bankName.isEmpty ? 'Customer se' : l.bankName),
      ),
      _cell(_bCols[3], _num(money(l.amount), style: _boldStyle)),
      _cell(
        _bCols[4],
        Text(
          party,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _cellStyle,
        ),
      ),
      _cell(
        _bCols[5],
        Text(
          detail,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: _cellStyle,
        ),
      ),
      _cell(_bCols[6], action),
    ]);
  }

  // ---------- Hisab Mel ----------

  Widget _hisabMel(RoznamchaDay day) {
    final t = context.t;
    final opening = day.opening + day.cashAdj;
    final lines = <(String, int, bool, Color?)>[
      (t('Opening (sabiqa)'), opening, false, null),
      ('+ ${t('Cash Wasooli')}', day.cashIn, false, null),
      ('+ ${t('Bank Wasooli')}', day.bankCust, false, null),
      if (day.direct > 0)
        (
          '+ ${t('Direct to Party (customer ne seedha party ko diye)')}',
          day.direct,
          false,
          null,
        ),
      (
        '= ${t(day.direct > 0 ? 'Opening + Wasooli (cash + bank + direct)' : 'Opening + Wasooli (cash + bank)')}',
        opening + day.wasooli,
        true,
        null,
      ),
      ('+ ${t('Bank se Nikali (haath mein cash aaya)')}', day.wd, false, null),
      ('= ${t('A: Kul Aamad')}', day.left, true, teal),
      (
        '− ${t('Cash Kharcha (Cash / Office / Company / Customer)')}',
        day.kharchaCash,
        false,
        null,
      ),
      (
        '− ${t('Bank Jama (customer ki bank wasooli, auto)')}',
        day.bankCust,
        false,
        null,
      ),
      if (day.direct > 0)
        (
          '− ${t('Direct to Party (party ko pohanch gaye, auto)')}',
          day.direct,
          false,
          null,
        ),
      ('− ${t('Cash se Bank mein Jama (manual)')}', day.depMan, false, null),
      (
        '= ${t(day.direct > 0 ? 'B: Kul Kharcha + Bank Jama + Direct' : 'B: Kul Kharcha + Bank Jama')}',
        day.rightTotal,
        true,
        amber,
      ),
      (t('Safi Baqaya = A − B (Cash in Hand)'), day.safi, true, amber),
      if (day.kharchaBank > 0)
        (
          t('Bank se diye kharcha (sirf bank ghata, cash par asar nahi)'),
          day.kharchaBank,
          false,
          muted,
        ),
      if (day.lessTotal > 0)
        (
          t('Less / Kami (khata se minus, cash par asar nahi)'),
          day.lessTotal,
          false,
          muted,
        ),
    ];
    return RozPanel(
      title: 'Hisab Mel (Safi Baqaya kaise bana)',
      subtitle: 'Har line ek raqam. Band / khol sakte ho.',
      actions: [
        Text(
          rs(day.safi),
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: amber,
            fontSize: 15,
          ),
        ),
        IconButton(
          tooltip: context.t(hisabOpen ? 'Band karo' : 'Kholo'),
          onPressed: () => setState(() => hisabOpen = !hisabOpen),
          icon: Icon(hisabOpen ? Icons.expand_less : Icons.expand_more),
        ),
      ],
      child: hisabOpen
          ? Column(
              children: [
                for (final l in lines)
                  _line(color: l.$3 ? rozSoft : null, [
                    _span(
                      4,
                      Text(
                        l.$1,
                        style: (l.$3 ? _boldStyle : _cellStyle).copyWith(
                          color: l.$4,
                        ),
                      ),
                    ),
                    _span(
                      1,
                      _num(
                        rs(l.$2),
                        style: (l.$3 ? _boldStyle : _cellStyle).copyWith(
                          color: l.$4,
                        ),
                      ),
                      end: true,
                    ),
                  ]),
              ],
            )
          : const SizedBox.shrink(),
    );
  }

  // ---------- actions ----------

  void _edit(Document d) {
    if (d.type == EntryType.adjustment) {
      editOpeningBalance(context, app, existing: d);
      return;
    }
    if (!rozEditable(d)) {
      showTransaction(context, app, d);
      return;
    }
    formKey.currentState?.edit(d);
    final target = entryKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
        alignment: .02,
      );
    }
  }

  Future<void> _delete(Document d) async {
    final message = switch (rozFormOf(d)) {
      RozForm.aamad => 'Yeh Aamad entry delete karein?',
      RozForm.companyIn => 'Yeh Company se Wasooli delete karein?',
      RozForm.nikali => 'Yeh Bank se Nikali entry delete karein?',
      RozForm.less => 'Yeh Less entry delete karein?',
      RozForm.opening when isOpeningBalance(d) =>
        'Yeh Opening balance delete karein?',
      RozForm.opening || null => 'Yeh entry delete karein?',
      _ => 'Yeh Kharcha entry delete karein?',
    };
    final reason = await confirmDelete(context, message);
    if (reason == null || !mounted) return;
    if (formKey.currentState?.editing?.id == d.id) {
      formKey.currentState?.cancelEdit();
    }
    await perform(
      context,
      () => app.voidDocument(d, reason),
      success: 'Entry delete ho gayi',
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveRoz(List<Document> dayDocs) async {
    if (dayDocs.isEmpty) {
      _snack(context.t('Roznamcha khali hai, save nahi hua'));
      return;
    }
    final ok = await perform(context, app.saveSnapshot);
    if (ok && mounted) {
      _snack(
        '${context.t('Roznamcha save')}: ${dmy(app.selectedDate)} — ${context.t('Day history')}',
      );
    }
  }

  Future<void> _nextDay(RoznamchaDay day, List<Document> dayDocs) async {
    final ok = await confirmPlain(
      context,
      '${context.t('Aaj ka Safi Baqaya')} (${rs(day.safi)}) ${context.t('agle din ka Opening ban jayega. Theek hai?')}',
    );
    if (!ok || !mounted) return;
    final done = await perform(context, () async {
      if (dayDocs.isNotEmpty) await app.saveSnapshot();
      app.setDate(nextDate(app.selectedDate, 1));
    });
    if (done && mounted) {
      _snack('${context.t('Agla Din')}: ${dmy(app.selectedDate)}');
    }
  }

  Future<void> _menu(String value, bool closed) async {
    switch (value) {
      case 'print':
        await previewReport(
          context,
          buildReport(
            app,
            'Daily roznamcha',
            app.selectedDate,
            app.selectedDate,
            urdu: app.urdu,
          ),
        );
      case 'history':
        await showHistory(context, app);
      case 'batch':
        final ok = await confirmPlain(
          context,
          'Roznamcha saaf karein? Customer, Party aur Company khata ka data DELETE nahi hoga. Ab tak ki entries Opening mein shamil ho jayengi.',
        );
        if (ok && mounted) {
          setState(() => showAll = false);
          await perform(context, app.startBatch, success: 'Saved');
        }
      case 'count':
        await reconcile(context, app, 'cash');
      case 'close':
        final reason = await askText(
          context,
          closed ? 'Reopen day' : 'Close day',
        );
        if (reason != null && mounted) {
          await perform(
            context,
            () => app.closeDay(reopen: closed, reason: reason),
            success: 'Saved',
          );
        }
    }
  }

  Future<void> _applyRate(RoznamchaDay full) async {
    final int rate;
    try {
      rate = decimal(rateField.text, 2);
    } catch (e) {
      _snack(errorText(context, e));
      return;
    }
    if (rate <= 0) {
      _snack(context.t('Pehle 11.8 KG ka rate likhein'));
      return;
    }
    final all = full.aamad.where(
      (d) => d.type == EntryType.sale && !d.purchaseShare,
    );
    final sales = all.where((d) => d.rate != rate).length;
    if (all.isEmpty) {
      _snack(context.t('Aaj koi sale entry nahi'));
      return;
    }
    if (sales == 0) {
      _snack(context.t('Sab sale entries par yehi rate pehle se hai'));
      return;
    }
    final reason = await confirmReason(
      context,
      '${rs(rate)} ${context.t('rate (11.8 KG) aaj ki sab sale entries par lagayein?')} ($sales)',
      confirm: 'Haan, lagayein',
      initial: '${context.t('Aaj ka rate')} ${money(rate)}',
    );
    if (reason == null || !mounted) return;
    final ok = await perform(context, () => app.applyDailyRate(rate, reason));
    if (ok && mounted) {
      rateField.clear();
      _snack('$sales ${context.t('entries par rate lag gaya')}: ${rs(rate)}');
    }
  }
}
