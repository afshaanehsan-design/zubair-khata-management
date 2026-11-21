import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/controller.dart';
import '../../core/l10n.dart';
import '../../core/models.dart';
import '../ledger/entry_facts.dart'
    show
        adjustmentMeaning,
        entryAmount,
        entryAmountText,
        entryHeadline,
        entryTitle,
        entryTypeLabel;
import '../ledger/roznamcha.dart';
import 'reports.dart'
    show
        Report,
        ReportCancelled,
        ReportExporter,
        UrduPdfRenderer,
        hasUrduScript,
        kg,
        money;

// The Roznamcha PDF, printed like the original page's "Roznamcha History
// (Date wise)" export (index.html: renderHistory and exportData): a title and
// print stamp (the day, and when it was saved for a saved copy), the summary
// figures, then A (Aamad / Wasooli), Bank Nikali / Less and B (Kharcha + Bank
// Jama). What the original page could not hold (direct payments, opening
// balances, gas and stock entries) is added only on the days that have it.
// The page's bold line with the day, the saved time and the closing is not
// printed: the stamp and the summary already hold them (asked for by the user
// on 21 November 2026).

/// A piece of text in a cell of the sheet.
class SheetRun {
  final String text;
  final bool bold;

  /// The original page's smaller text: bank badges and the summary notes.
  final bool small;
  const SheetRun(this.text, {this.bold = false, this.small = false});
}

enum SheetAlign { start, center, end }

/// One cell: lines of [SheetRun]s, [span] columns wide (the footers' "Total"
/// spans like the original page's `colspan`).
class SheetCell {
  final List<List<SheetRun>> lines;
  final int span;
  final SheetAlign align;
  final bool muted;

  /// Shorten each text line to its available width; amounts never use this.
  final bool ellipsis;

  /// The first line is a number and must remain fully visible.
  final bool numeric;
  const SheetCell(
    this.lines, {
    this.span = 1,
    this.align = SheetAlign.start,
    this.muted = false,
    this.ellipsis = false,
    this.numeric = false,
  });
  SheetCell.text(
    String text, {
    bool bold = false,
    this.span = 1,
    this.align = SheetAlign.start,
    this.muted = false,
    this.ellipsis = false,
    this.numeric = false,
  }) : lines = [
         [SheetRun(text, bold: bold)],
       ];

  /// What the cell reads, its lines joined by a line break.
  String get text => lines.map((l) => l.map((r) => r.text).join()).join('\n');
}

/// A table of the sheet. Its columns are as wide as their content, like the
/// original page's browser tables; see [rozSheetPdf].
class SheetTable {
  /// The heading above the table; empty for the summary.
  final String title;
  final List<SheetCell> head;
  final List<List<SheetCell>> body, foot;

  /// Columns of text (names, accounts, descriptions) that may take more
  /// lines when the page is too narrow. The others keep one line.
  final Set<int> wrap;

  /// Cells start at the top (the summary) instead of the middle.
  final bool top;
  const SheetTable({
    required this.title,
    required this.head,
    required this.body,
    this.foot = const [],
    required this.wrap,
    this.top = false,
  });
}

/// One day of the Roznamcha, as printed, or another report in its design
/// (`report_sheet.dart`).
class RozSheet {
  final String date, title, stamp, heading;

  /// The row of figures under the heading; not printed when it has no head.
  final SheetTable summary;

  /// A, then Bank Nikali / Less when the day has any, B, then the day's
  /// entries outside the cash book when it has any.
  final List<SheetTable> tables;

  /// Lines printed under the tables (a report's notes).
  final List<String> notes;
  const RozSheet({
    required this.date,
    required this.title,
    required this.stamp,
    required this.heading,
    required this.summary,
    required this.tables,
    this.notes = const [],
  });

  /// The table with [title], or null.
  SheetTable? table(String title) =>
      tables.where((t) => t.title == title).firstOrNull;

  int get rows => [
    summary,
    ...tables,
  ].fold(0, (v, t) => v + 1 + t.body.length + t.foot.length);
}

String _two(int v) => '$v'.padLeft(2, '0');

/// A day as the original page wrote it: 25-10-2026.
String rozDmy(String date) {
  final p = date.split('-');
  return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : date;
}

/// A moment as the original page printed it (en-GB): 26/10/2026, 10:20:21.
String rozTime(DateTime time) =>
    '${_two(time.day)}/${_two(time.month)}/${time.year}, '
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

/// When a snapshot was saved ([savedAt] as stored), as the sheet prints it.
String rozSavedTime(String savedAt) {
  final time = DateTime.tryParse(savedAt);
  return time == null ? savedAt : rozTime(time.toLocal());
}

/// The line under the title: the app's date and the moment of printing, with
/// when the printed copy was saved between them when it is one ([saved]).
String rozStamp(String date, Words t, {String saved = '', DateTime? now}) => [
  '${t('Date')}: ${rozDmy(date)}',
  if (saved.isNotEmpty) '${t('Saved')}: $saved',
  '${t('Print')}: ${rozTime(now ?? DateTime.now())}',
].join(' | ');

/// When [day] was saved (Roznamcha Save, Agla Din), if its latest saved copy
/// still holds exactly its entries ([AppController.saveSnapshot]'s test);
/// otherwise ''.
String rozSavedCopy(AppController app, RoznamchaDay day) {
  final latest =
      (app.ofKind('snapshot').where((s) => s.data['date'] == day.date).toList()
            ..sort(
              (a, b) =>
                  '${a.data['savedAt']}'.compareTo('${b.data['savedAt']}'),
            ))
          .lastOrNull;
  if (latest == null) return '';
  final same =
      canonicalJson(latest.data['documents']) ==
      canonicalJson([for (final d in day.documents) d.record.toJson()]);
  return same ? rozSavedTime('${latest.data['savedAt']}') : '';
}

/// Notes are cut here, so no single row can outgrow a page.
const _noteLimit = 240;
String _cap(String text) {
  final s = text.trim();
  return s.length <= _noteLimit ? s : '${s.substring(0, _noteLimit)}…';
}

String _join(Iterable<String> parts, [String separator = ' · ']) =>
    parts.where((p) => p.trim().isNotEmpty).join(separator);

/// An amount row before formatting, so compact mode sums integer paisa and
/// groups by source IDs, never by translated names or formatted numbers.
class _MoneyRow {
  final Object key;
  final String type, bank, party, about;
  final int amount;
  const _MoneyRow(
    this.key,
    this.type,
    this.bank,
    this.party,
    this.about,
    this.amount,
  );
}

// Unicode isolates (left-to-right, right-to-left, end). Without them two
// Urdu names around "→" run together and swap sides.
final _lri = String.fromCharCode(0x2066);
final _rli = String.fromCharCode(0x2067);
final _pdi = String.fromCharCode(0x2069);

/// [day] laid out as the original page's history print. [saved] is when the
/// printed copy was saved ('' when it is not a saved copy); the stamp names
/// both, with the moment of printing ([printed], now when null).
RozSheet rozSheet(
  AppController app,
  RoznamchaDay day,
  Words t, {
  String saved = '',
  bool compact = false,
  DateTime? printed,
}) {
  final short = compact;
  String oneLine(String s) =>
      short ? s.replaceAll(RegExp(r'\s+'), ' ').trim() : s;
  // Column heads and B types are capitals, as the page's CSS and its type
  // labels printed them; Urdu has no capitals.
  String up(String text) => text.toUpperCase();
  SheetCell head(String label, [SheetAlign align = SheetAlign.start]) =>
      SheetCell.text(up(label), bold: true, align: align);
  SheetCell text(
    String s, {
    SheetAlign align = SheetAlign.start,
    bool bold = false,
    int span = 1,
  }) => SheetCell.text(
    oneLine(s),
    align: align,
    bold: bold,
    span: span,
    ellipsis: short,
  );
  SheetCell amount(int v, {bool bold = false}) => SheetCell.text(
    money(v),
    align: SheetAlign.end,
    bold: bold,
    numeric: true,
  );
  SheetCell empty(String s, int span) =>
      SheetCell.text(s, span: span, align: SheetAlign.center, muted: true);
  String dash(int v) => v == 0 ? '—' : money(v);
  String partyName(Document d) => d.party.isEmpty ? '—' : app.name(d.party);
  // A name or note with Urdu, kept in its place inside a longer text.
  String iso(String s) =>
      hasUrduScript(s) ? '${t.urdu ? _rli : _lri}$s$_pdi' : s;
  // From whom to whom: the arrow points the way the sheet reads.
  final arrow = t.urdu ? '←' : '→';
  // An account's bank, like the original's bank badges: CASH, HBL BANK.
  String bankOf(String account) {
    if (account == 'cash') return up(t('Cash'));
    final bank = '${app.record(account)?.data['bank'] ?? ''}'.trim();
    return bank.isEmpty ? 'BANK' : up(bank);
  }

  String holder(String account) =>
      account.isEmpty || account == 'cash' ? '—' : app.name(account);
  SheetCell bankCell(String bank) => bank == '—'
      ? text('—')
      : SheetCell([
          [SheetRun(bank, bold: true, small: true)],
        ]);
  // "73,000 HBL BANK LUQMAN HBL": amount, bank badge, account holder.
  List<SheetRun> moneyLine(int v, String badge, String name) => [
    SheetRun(money(v)),
    if (badge.isNotEmpty) ...[
      const SheetRun(' '),
      SheetRun(badge, bold: true, small: true),
    ],
    const SheetRun(' '),
    SheetRun(name),
  ];

  // ---------- summary (the history print's four cards, then the Roznamcha
  // page's Total Gas Dispatch and Total Sale, with the screen's figures,
  // printed on every day, at 0 when nothing was sold) ----------

  SheetCell figure(String value, List<String> notes) => SheetCell([
    [
      SheetRun(value, bold: true),
      const SheetRun(' '),
      SheetRun(notes.join(' | '), small: true),
    ],
  ]);
  SheetCell stat(int v, List<String> notes) => figure('Rs. ${money(v)}', notes);
  final gasNotes = [
    for (final s in sizes) '${sizeLabel(s)}: ${day.cylinders[s]}',
    if (day.bulkGrams > 0) '${t('Bulk')} ${kg(day.bulkGrams)} kg',
  ];
  // An Urdu word among the Latin sizes makes the box a right-to-left
  // paragraph, where "151.7 kg" would land beside "45 KG:". Each part is
  // isolated so it stays whole and in its place.
  final mixedGas = t.urdu && hasUrduScript(gasNotes.join());
  String gasPart(String s) =>
      mixedGas ? '${hasUrduScript(s) ? _rli : _lri}$s$_pdi' : s;
  final summary = SheetTable(
    title: '',
    wrap: const {0, 1, 2, 3, 4, 5},
    head: [
      head(t('Opening')),
      head(t('A: Kul Aamad')),
      head(t('B: Kharcha + Bank Jama')),
      head(t('Closing')),
      head(t('Total Gas Dispatch (KG)')),
      head(t('Total Sale')),
    ],
    body: [
      [
        stat(day.opening + day.cashAdj, [
          '${t('Bank Nikali')} ${money(day.wd)}',
        ]),
        stat(day.left, [
          '${t('Cash')} ${money(day.cashIn)}',
          '${t('Bank')} ${money(day.bankCust)}',
          if (day.direct > 0) '${t('Direct')} ${money(day.direct)}',
        ]),
        stat(day.rightTotal, [
          '${t('Kharcha')} ${money(day.kharchaCash)}',
          '${t('Bank Jama')} ${money(day.bankCust + day.depMan)}',
          if (day.direct > 0) '${t('Direct')} ${money(day.direct)}',
        ]),
        stat(day.safi, ['${t('Bank Baqi')} ${money(day.bankNet)}']),
        figure(gasPart('${kg(day.dispatchGrams)} kg'), [
          for (final n in gasNotes) gasPart(n),
        ]),
        stat(day.bill, [
          '${t('Cylinder')} ${money(day.cylinderBill)}',
          '${t('Bulk')} ${money(day.bulkBill)}',
        ]),
      ],
    ],
    top: true,
  );

  // ---------- A: Aamad / Wasooli ----------

  // "Direct to Party" (not on the original page) gets a column only on a day
  // that has it, as on the screen.
  final direct = day.direct > 0;
  String nameExtra(Document d) {
    final source = app.shareSource(d);
    return _join([
      if (rozFormOf(d) == RozForm.companyIn) t('Company wasooli'),
      if (d.type == EntryType.deposit) t('Deposit'),
      if (d.extraGrams > 0)
        '${d.bulkAtCost ? t('Purchase share (at cost)') : t('Bulk')} ${kg(d.extraGrams)} KG'
            '${source.isEmpty ? '' : ' · ${iso(source)}'}',
      iso(_cap(d.note)),
    ]);
  }

  SheetCell nameCell(List<Document> docs) {
    final extra = _join(docs.map(nameExtra).where((s) => s.isNotEmpty).toSet());
    return SheetCell([
      [SheetRun(oneLine(partyName(docs.first)), bold: true)],
      if (extra.isNotEmpty) [SheetRun(oneLine(extra), small: true)],
    ], ellipsis: short);
  }

  SheetCell compactMoney(List<BankLine> lines) =>
      amount(lines.fold(0, (v, l) => v + l.amount), bold: true);

  final aHead = [
    SheetCell.text('#', bold: true),
    head(t('Parchi')),
    head(t('Customer / Party')),
    head('11.8k', SheetAlign.center),
    head('15k', SheetAlign.center),
    head('45k', SheetAlign.center),
    head(t('Rate'), SheetAlign.end),
    head(t('Bill'), SheetAlign.end),
    head(t('Cash'), SheetAlign.end),
    head(t('Bank / Account')),
    if (direct) head(t('Direct to Party')),
    head(t('Kul Wasooli'), SheetAlign.end),
  ];
  final aBody = <List<SheetCell>>[];
  final aGroups = <Object, List<Document>>{};
  for (final d in day.aamad) {
    // Company receipts and deposits remain separate from customer wasooli.
    final key = short && d.party.isNotEmpty
        ? (
            d.party,
            rozFormOf(d) == RozForm.companyIn,
            d.type == EntryType.deposit,
          )
        : d.id as Object;
    (aGroups[key] ??= []).add(d);
  }
  for (final (i, docs) in aGroups.values.indexed) {
    final d = docs.first;
    final deposit = d.type == EntryType.deposit;
    final cash = deposit
        ? docs.fold(
            0,
            (v, d) => v + (d.account == 'cash' ? d.value('amount') : 0),
          )
        : docs.fold(0, (v, d) => v + d.value('cash'));
    final banks = deposit
        ? [
            for (final d in docs)
              if (d.account != 'cash')
                BankLine(amount: d.value('amount'), account: d.account),
          ]
        : [for (final d in docs) ...d.bankLines.where((l) => !l.direct)];
    final paid = deposit
        ? const <BankLine>[]
        : [for (final d in docs) ...d.bankLines.where((l) => l.direct)];
    int sum(List<BankLine> lines) => lines.fold(0, (v, l) => v + l.amount);
    int qty(int size) => docs.fold(
      0,
      (v, d) => v + integer((d.data['quantities'] as Map?)?['$size']),
    );
    final sales = docs.where((d) => d.type == EntryType.sale);
    final bill = sales.fold(0, (v, d) => v + d.total);
    final rates = {
      for (final d in sales)
        if (!d.purchaseShare && d.rate != 0) d.rate,
    };
    final vehicle = _join({
      for (final d in docs) '${d.data['vehicle'] ?? ''}'.trim(),
    });
    aBody.add([
      text('${i + 1}'),
      text(vehicle.isEmpty ? '-' : vehicle),
      nameCell(docs),
      for (final s in sizes)
        SheetCell.text(
          qty(s) == 0 ? '—' : '${qty(s)}',
          align: SheetAlign.center,
          numeric: true,
        ),
      SheetCell.text(
        rates.length == 1 ? money(rates.single) : '—',
        align: SheetAlign.end,
        numeric: true,
      ),
      SheetCell.text(dash(bill), align: SheetAlign.end, numeric: true),
      SheetCell.text(dash(cash), align: SheetAlign.end, numeric: true),
      if (banks.isEmpty)
        text('—')
      else if (short)
        compactMoney(banks)
      else
        SheetCell([
          for (final l in banks)
            moneyLine(l.amount, bankOf(l.account), holder(l.account)),
        ]),
      if (direct)
        if (paid.isEmpty)
          text('—')
        else if (short)
          compactMoney(paid)
        else
          SheetCell([
            for (final l in paid)
              moneyLine(l.amount, up(l.bankName.trim()), app.name(l.party)),
          ]),
      amount(cash + sum(banks) + sum(paid), bold: true),
    ]);
  }
  if (aBody.isEmpty) aBody.add([empty(t('— Koi Aamad nahi —'), aHead.length)]);
  final a = SheetTable(
    title: t('A: Aamad / Wasooli'),
    // Customer / Party, Bank / Account and Direct to Party.
    wrap: {2, 9, if (direct) 10},
    head: aHead,
    body: aBody,
    foot: [
      [
        text(t('Total'), bold: true, span: 3),
        for (final s in sizes)
          SheetCell.text(
            '${day.cylinders[s]}',
            align: SheetAlign.center,
            bold: true,
            numeric: true,
          ),
        text(''),
        amount(day.totalBilled, bold: true),
        amount(day.cashIn, bold: true),
        amount(day.bankCust, bold: true),
        if (direct) amount(day.direct, bold: true),
        amount(day.wasooli, bold: true),
      ],
    ],
  );

  // ---------- Bank Nikali / Less (and opening balances) ----------

  // Type, Party and Tafseel.
  const sixWrap = {1, 3, 4};
  final sixHead = [
    SheetCell.text('#', bold: true),
    head(t('Type')),
    head(t('Bank')),
    head(t('Party')),
    head(t('Tafseel')),
    head(t('Raqam'), SheetAlign.end),
  ];
  List<List<SheetCell>> moneyRows(List<_MoneyRow> source) {
    final groups = <Object, List<_MoneyRow>>{};
    for (final (i, r) in source.indexed) {
      (groups[short ? r.key : i] ??= []).add(r);
    }
    return [
      for (final (i, group) in groups.values.indexed)
        [
          text('${i + 1}'),
          text(group.first.type),
          short
              ? text(_join(group.map((r) => r.bank).toSet()))
              : bankCell(group.first.bank),
          text(group.first.party),
          text(_join(group.map((r) => r.about).toSet())),
          amount(group.fold(0, (v, r) => v + r.amount), bold: true),
        ],
    ];
  }

  final middleRows = <_MoneyRow>[];
  void middleRow(
    Object key,
    String type,
    String bank,
    String party,
    String about,
    int v,
  ) => middleRows.add(_MoneyRow(key, type, bank, party, about, v));
  for (final d in day.nikali) {
    middleRow(
      ('withdrawal', d.account),
      t('Bank se Nikali'),
      bankOf(d.account),
      holder(d.account),
      _cap(d.note),
      d.value('amount'),
    );
  }
  for (final d in day.less) {
    final bank = d.type == EntryType.receipt;
    middleRow(
      ('less', bank, d.party, bank ? d.bankAccount : 'cash'),
      bank ? t('Less (Bank)') : t('Less (Cash)'),
      bank ? bankOf(d.bankAccount) : up(t('Cash')),
      bank ? holder(d.bankAccount) : '—',
      _join([iso(partyName(d)), iso(_cap(d.note))], ' — '),
      bank ? d.value('cash') + d.bankIn : d.value('amount'),
    );
  }
  for (final d in day.openings) {
    final target = '${d.data['target'] ?? ''}';
    final id = target.substring(target.indexOf(':') + 1);
    final account = target.startsWith('money:');
    middleRow(
      ('opening', d.id),
      t(adjustmentLabel(d)),
      account ? bankOf(id) : '—',
      account ? holder(id) : app.name(id),
      _join([adjustmentMeaning(d, t, app), iso(_cap(rozNote(d)))]),
      target.startsWith('ap:') ? -d.value('amount') : d.value('amount'),
    );
  }

  // ---------- B: Kharcha + Bank Jama ----------

  // As on the original page: the day's own B entries in the order they were
  // made, then one automatic Bank Jama per bank wasooli in A's order.
  String kharchaType(Document d) => switch (rozFormOf(d)) {
    RozForm.kharcha => d.account == 'cash' ? t('Cash kharcha') : t('Kharcha'),
    RozForm.office => t('Office'),
    RozForm.companyPay => t('Company'),
    RozForm.customerPay => t('Customer payment'),
    RozForm.udharWapsi => t('Udhar wapsi'),
    _ =>
      d.type == EntryType.purchase
          ? t('Purchase payment')
          : d.type == EntryType.depositRefund
          ? t('Deposit refund')
          : t(entryLabel(d.type.name)),
  };
  String kharchaDetail(Document d) {
    final customer = '${d.data['customerNote'] ?? ''}'.trim();
    final branch = '${d.data['branch'] ?? ''}'.trim();
    return _join([
      iso(_cap(d.note)),
      if (rozFormOf(d) == RozForm.companyPay && '$customer$branch'.isNotEmpty)
        '${t('Customer')}: ${customer.isEmpty ? '—' : iso(customer)} · '
            '${t('Branch')}: ${branch.isEmpty ? '—' : iso(branch)}',
      if (d.type == EntryType.purchase) entryHeadline(app, d, t),
    ]);
  }

  final bRows = <_MoneyRow>[];
  void bRow(
    Object key,
    String type,
    String bank,
    String party,
    String about,
    int v,
  ) => bRows.add(_MoneyRow(key, up(type), bank, party, about, v));
  for (final d in day.documents) {
    if (day.kharcha.contains(d)) {
      bRow(
        (
          'expense',
          d.type,
          rozFormOf(d),
          d.party.isEmpty ? d.id : d.party,
          d.account,
        ),
        kharchaType(d),
        bankOf(d.account),
        partyName(d),
        kharchaDetail(d),
        d.value('amount'),
      );
    } else if (rozFormOf(d) == RozForm.bankJama) {
      final to = '${d.data['toAccount'] ?? ''}';
      bRow(
        ('manual-bank', to),
        t('Bank jama'),
        bankOf(to),
        holder(to),
        d.note.trim().isEmpty
            ? '${t('Cash jama')} $arrow ${iso(holder(to))}'
            : _cap(d.note),
        d.value('amount'),
      );
    }
  }
  for (final l in day.bankJama.where((l) => l.automatic)) {
    bRow(
      ('auto-bank', l.account),
      t('Bank jama'),
      bankOf(l.account),
      holder(l.account),
      '${t('Wasooli')} — ${iso(partyName(l.document))} $arrow '
      '${iso(holder(l.account))}',
      l.amount,
    );
  }
  for (final l in day.directLines) {
    bRow(
      ('direct', l.party),
      t('Direct to Party'),
      l.bankName.trim().isEmpty ? '—' : up(l.bankName.trim()),
      app.name(l.party),
      '${t('Wasooli')} — ${iso(partyName(l.document))} $arrow '
      '${iso(app.name(l.party))}',
      l.amount,
    );
  }
  final b = moneyRows(bRows);
  if (b.isEmpty) b.add([empty(t('— Koi Kharcha nahi —'), sixHead.length)]);
  final bTable = SheetTable(
    title: t('B: Kharcha + Bank Jama'),
    wrap: sixWrap,
    head: sixHead,
    body: b,
    foot: [
      [
        text(
          direct
              ? t('Kul Kharcha + Bank Jama + Direct')
              : t('Kul Kharcha + Bank Jama'),
          bold: true,
          span: 5,
        ),
        amount(day.rightTotal, bold: true),
      ],
      // Paid from a bank: listed above, but not in cash's B total.
      if (day.kharchaBank > 0)
        [
          text(
            t('Bank se diye kharcha (sirf bank ghata, cash par asar nahi)'),
            bold: true,
            span: 5,
          ),
          amount(day.kharchaBank, bold: true),
        ],
    ],
  );

  // ---------- the day's entries outside the cash book ----------

  final other = [
    for (final (i, d) in day.other.indexed)
      [
        text('${i + 1}'),
        text(entryTypeLabel(d, t)),
        text(
          d.party.isNotEmpty
              ? app.name(d.party)
              : d.type == EntryType.transfer
              ? entryTitle(app, d, t)
              : '—',
        ),
        text(
          _cap(
            _join([
              entryHeadline(app, d, t),
              // These two already end their headline with the note.
              if (d.type != EntryType.adjustment &&
                  d.type != EntryType.stockAdjustment)
                iso(rozNote(d)),
            ]),
          ),
        ),
        switch (d.type) {
          EntryType.stockAdjustment || EntryType.cylinder => SheetCell.text(
            entryAmountText(d),
            align: SheetAlign.end,
            bold: true,
            numeric: true,
          ),
          _ => SheetCell.text(
            dash(entryAmount(d)),
            align: SheetAlign.end,
            bold: true,
            numeric: true,
          ),
        },
      ],
  ];

  return RozSheet(
    date: day.date,
    title: '${t('Roznamcha History')} — ${t('Roznamcha History (Date wise)')}',
    // The day's own date, also when a range prints several days or the top
    // bar is on another day; the summary prints the closing.
    stamp: rozStamp(day.date, t, saved: saved, now: printed),
    heading: '',
    summary: summary,
    tables: [
      a,
      if (middleRows.isNotEmpty)
        SheetTable(
          title: day.openings.isEmpty
              ? t('Bank Nikali / Less')
              : t('Bank Nikali / Less / Opening'),
          wrap: sixWrap,
          head: sixHead,
          body: moneyRows(middleRows),
        ),
      bTable,
      if (other.isNotEmpty)
        SheetTable(
          title: t('Baqi entries (gas, stock, transfer)'),
          wrap: const {1, 2, 3},
          head: [
            SheetCell.text('#', bold: true),
            head(t('Type')),
            head(t('Party')),
            head(t('Tafseel')),
            head(t('Raqam'), SheetAlign.end),
          ],
          body: other,
        ),
    ],
  );
}

// Sizes in points, scaled from the original export: 11.5 px table text on a
// table about 880 px wide, printed across A4 (the page zoomed it to fit).
const _margin = 18.0;
const _headingSize = 8.3, _stampSize = 6.4, _textSize = 7.3, _smallSize = 6.4;
const _padX = 3.8, _padY = 2.2;

/// Column heads are spaced out a little, as the page's `letter-spacing`.
const _headSpacing = .2;

/// The smallest a wide day's tables print at, so they stay easy to read:
/// [_minScale] of the chosen size, or of [_minScaleTop] (150%, the size
/// slider's old top) when the size is bigger. See [sheetScale].
const _minScale = .85, _minScaleTop = 1.5;

/// The zoom of a sheet's tables at the preview's [size], when [fit] (at
/// most 1) of that size is what lets its widest table keep its lines: as
/// big as the page allows, up to [size]. A table too wide even so prints at
/// [_minScale] of [size], or of 150% for a bigger size, and wraps. At 85% of
/// 200% a wide day had no room left and its figures broke in the middle, so
/// above 150% it shrinks as far as it would at 150%; narrow tables still
/// grow to the full size.
double sheetScale(double size, double fit) =>
    math.max(size * fit, _minScale * math.min(size, _minScaleTop));

const _ink = PdfColors.black;
const _grey = PdfColor.fromInt(0xff555555);
const _muted = PdfColor.fromInt(0xff6b7686);
const _rule = pw.BorderSide(color: _grey, width: .6);

/// [report]'s sheets (or [sheets] in their place) as a PDF: each day on its
/// own pages, black on white like the original print (its grey fills never
/// reached the paper).
Future<Uint8List> rozSheetPdf(
  Report report,
  ReportExporter exporter, [
  List<RozSheet>? sheets,
]) async {
  final printed = sheets ?? report.sheets;
  final fallback = pw.Font.ttf(
    await rootBundle.load('assets/fonts/Manrope.ttf'),
  );
  final rtl = report.urdu;
  final renderer = UrduPdfRenderer(rtl: rtl);
  const format = PdfPageFormat.a4;
  final width = format.width - _margin * 2;
  final total = printed.fold(0, (v, s) => v + s.rows);
  var done = 0;

  // The preview's size slider: headings, notes and spacing scale with it, and
  // the tables start from it. The paper and its margin do not change.
  final size = exporter.size;
  double gap(double points) => points * size;

  // The page's zoom: the original shrank its whole print to fit the widest
  // table, so a day with wide content prints a little smaller here too (the
  // tables only, and not below [_minScale] of the chosen size, or of 150%
  // above it: [sheetScale]); what is still too wide wraps.
  var scale = size;
  double text() => _textSize * scale;
  double small() => _smallSize * scale;
  double padX() => _padX * scale;

  pw.TextAlign align(SheetAlign a) => switch (a) {
    SheetAlign.center => pw.TextAlign.center,
    SheetAlign.start => rtl ? pw.TextAlign.right : pw.TextAlign.left,
    SheetAlign.end => rtl ? pw.TextAlign.left : pw.TextAlign.right,
  };
  Future<pw.Widget> line(
    List<SheetRun> runs,
    double w, {
    required double size,
    double? smallSize,
    bool bold = false,
    PdfColor color = _ink,
    SheetAlign at = SheetAlign.start,
    double spacing = 0,
    bool ellipsis = false,
  }) {
    List<(String, bool, double)> styled(List<SheetRun> parts) => [
      for (final r in parts)
        (r.text, bold || r.bold, r.small ? smallSize ?? size : size),
    ];
    if (ellipsis && renderer.measure(styled(runs)) > w) {
      final characters = [for (final r in runs) r.text.characters.toList()];
      List<SheetRun> prefix(int length) {
        final result = <SheetRun>[];
        var remaining = length;
        for (final (i, run) in runs.indexed) {
          final count = math.min(remaining, characters[i].length);
          if (count > 0) {
            result.add(
              SheetRun(
                characters[i].take(count).join(),
                bold: run.bold,
                small: run.small,
              ),
            );
          }
          remaining -= count;
          if (remaining == 0) break;
        }
        final last = result.lastOrNull ?? runs.first;
        // Close any direction isolate cut off by the ellipsis.
        final value = result.map((r) => r.text).join();
        final open =
            value.runes.where((r) => r == 0x2066 || r == 0x2067).length -
            value.runes.where((r) => r == 0x2069).length;
        result.add(
          SheetRun(
            '…${List.filled(math.max(0, open), _pdi).join()}',
            bold: last.bold,
            small: last.small,
          ),
        );
        return result;
      }

      var low = 0, high = characters.fold(0, (v, c) => v + c.length);
      while (low < high) {
        final middle = (low + high + 1) ~/ 2;
        if (renderer.measure(styled(prefix(middle))) <= w) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      runs = prefix(low);
    }
    return renderer.runs(
      [
        for (final r in runs)
          (r.text, bold || r.bold, r.small ? smallSize ?? size : size),
      ],
      w,
      align: align(at),
      color: color,
      letterSpacing: spacing,
    );
  }

  // One printed row: its own one-row table, as pw.Table has no column spans
  // (a spanning cell is simply wider). Only the head draws a top rule; every
  // row draws the rule under it.
  Future<pw.Widget> row(
    List<SheetCell> cells,
    List<double> widths, {
    bool head = false,
    bool top = false,
  }) async {
    if (exporter.cancelled) throw ReportCancelled();
    final children = <pw.Widget>[], spans = <double>[];
    var column = 0;
    for (final cell in cells) {
      final w = widths.skip(column).take(cell.span).fold(0.0, (v, x) => v + x);
      column += cell.span;
      spans.add(w);
      children.add(
        pw.Padding(
          padding: pw.EdgeInsets.symmetric(
            horizontal: padX(),
            vertical: _padY * scale,
          ),
          // Every line is the cell's full width; its text is aligned in it.
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              for (final (i, l) in cell.lines.indexed)
                await line(
                  l,
                  w - padX() * 2,
                  size: text(),
                  smallSize: small(),
                  at: cell.align,
                  color: cell.muted ? _muted : _ink,
                  spacing: head ? _headSpacing * scale : 0,
                  ellipsis: cell.ellipsis && !(cell.numeric && i == 0),
                ),
            ],
          ),
        ),
      );
    }
    done++;
    exporter.progress?.call(done / math.max(1, total));
    if (done % 15 == 0) await Future<void>.delayed(Duration.zero);
    final ordered = rtl ? children.reversed.toList() : children;
    final sized = rtl ? spans.reversed.toList() : spans;
    return pw.Table(
      border: pw.TableBorder(
        left: _rule,
        right: _rule,
        bottom: _rule,
        verticalInside: _rule,
        top: head ? _rule : pw.BorderSide.none,
      ),
      columnWidths: {
        for (var i = 0; i < sized.length; i++) i: pw.FixedColumnWidth(sized[i]),
      },
      defaultVerticalAlignment: top
          ? pw.TableCellVerticalAlignment.top
          : pw.TableCellVerticalAlignment.middle,
      children: [pw.TableRow(children: ordered)],
    );
  }

  // How wide a cell's longest line is, with its padding and a point of slack
  // so measured text never wraps on a rounding difference. A note in small
  // type under the first line (bulk KG, the entry's note) wraps instead of
  // widening its column.
  double need(SheetCell cell, {bool head = false}) {
    var widest = 0.0;
    for (final (i, l) in cell.lines.indexed) {
      if (i > 0 && l.every((r) => r.small)) continue;
      widest = math.max(
        widest,
        renderer.measure([
          for (final r in l) (r.text, r.bold, r.small ? small() : text()),
        ], letterSpacing: head ? _headSpacing * scale : 0),
      );
    }
    if (cell.ellipsis && !cell.numeric) widest = math.min(widest, 100 * scale);
    return widest + padX() * 2 + 1;
  }

  // How wide a heading's longest word is, for a table whose headings cannot
  // all keep one line: such a heading takes two lines instead.
  double word(SheetCell cell) {
    var widest = 0.0;
    for (final l in cell.lines) {
      for (final r in l) {
        for (final w in r.text.split(' ')) {
          widest = math.max(
            widest,
            renderer.measure([
              (w, r.bold, r.small ? small() : text()),
            ], letterSpacing: _headSpacing * scale),
          );
        }
      }
    }
    return widest + padX() * 2 + 1;
  }

  double sum(Iterable<double> v) => v.fold(0.0, (a, b) => a + b);

  // Each column's heading width and the width its content wants on one line
  // ([words]: the heading's longest word instead of the whole heading).
  (List<double>, List<double>) measured(SheetTable t, {bool words = false}) {
    final heads = [
      for (final c in t.head) words ? word(c) : need(c, head: true),
    ];
    final wants = List.of(heads);
    for (final r in [...t.body, ...t.foot]) {
      var i = 0;
      for (final c in r) {
        if (c.span == 1) {
          wants[i] = math.max(wants[i], need(c));
          if (c.numeric) heads[i] = math.max(heads[i], need(c));
        }
        i += c.span;
      }
    }
    return (heads, wants);
  }

  // What a table wants for its weight: one long note in a text column does
  // not count beyond 40% of the page (it wraps instead).
  List<double> weights(SheetTable t, List<double> wants) => [
    for (var i = 0; i < wants.length; i++)
      t.wrap.contains(i) ? math.min(wants[i], width * .4) : wants[i],
  ];

  // Column widths as the original page's browser laid its tables out: each
  // as wide as its content on one line, the room left shared in proportion.
  // When that is wider than the page, headings and values keep one line and
  // the text columns ([SheetTable.wrap]) share what is left in proportion to
  // their text, each at least as wide as its heading. A table that still
  // does not fit (a report with many figure columns) tries again with each
  // heading as wide as its longest word, so long headings take two lines.
  List<double> columns(SheetTable t) {
    var result = <double>[];
    for (final words in [false, true]) {
      final (heads, wants) = measured(t, words: words);
      final total = sum(wants);
      if (total <= width) return [for (final w in wants) w * width / total];
      result = List.of(wants);
      final open = {
        for (var i = 0; i < wants.length; i++)
          if (t.wrap.contains(i)) i,
      };
      // One long note does not starve the other text columns.
      final weight = weights(t, wants);
      var free =
          width -
          sum([
            for (var i = 0; i < wants.length; i++)
              if (!open.contains(i)) wants[i],
          ]);
      while (open.isNotEmpty) {
        final share = free / sum(open.map((i) => weight[i]));
        final narrow = open.where((i) => share * weight[i] < heads[i]).toList();
        if (narrow.isEmpty) {
          for (final i in open) {
            result[i] = share * weight[i];
          }
          break;
        }
        for (final i in narrow) {
          result[i] = heads[i];
          free -= heads[i];
          open.remove(i);
        }
      }
      if (sum(result) <= width) return result;
    }
    // Only absurd content gets here: everything shrinks to fit.
    final used = sum(result);
    return [for (final w in result) w * width / used];
  }

  // The rows in a one-column table, which splits between rows across pages
  // and repeats the head on each.
  Future<pw.Widget> table(SheetTable t) async {
    final widths = columns(t);
    return pw.Table(
      columnWidths: {0: pw.FixedColumnWidth(width)},
      children: [
        pw.TableRow(
          repeat: true,
          children: [await row(t.head, widths, head: true, top: t.top)],
        ),
        for (final r in [...t.body, ...t.foot])
          pw.TableRow(children: [await row(r, widths, top: t.top)]),
      ],
    );
  }

  final doc = pw.Document(
    title: report.title,
    author: report.business,
    // Helvetica has the reference's Arial metrics and a real bold face. It
    // covers only Latin-1, so dashes and arrows come from Manrope.
    theme: pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      fontFallback: [fallback],
    ),
  );
  for (final sheet in printed) {
    // The summary wraps freely (as the page's did), so only the other
    // tables set the zoom.
    scale = size;
    var fit = 1.0;
    for (final t in sheet.tables) {
      final (_, wants) = measured(t);
      // 1% to spare for the slack that does not shrink with the type.
      fit = math.min(fit, width * .99 / sum(weights(t, wants)));
    }
    scale = sheetScale(size, fit);
    final content = <pw.Widget>[
      await line(
        [SheetRun(sheet.title)],
        width,
        size: gap(_headingSize),
        bold: true,
      ),
      await line(
        [SheetRun(sheet.stamp)],
        width,
        size: gap(_stampSize),
        color: _grey,
      ),
      // An empty heading (the Money statement's, the Roznamcha's) takes no
      // space; the summary then keeps the gap the heading had above it.
      if (sheet.heading.isNotEmpty) ...[
        pw.SizedBox(height: gap(5)),
        await line(
          [SheetRun(sheet.heading)],
          width,
          size: gap(_headingSize),
          bold: true,
        ),
      ],
      if (sheet.summary.head.isNotEmpty) ...[
        pw.SizedBox(height: gap(sheet.heading.isEmpty ? 5 : 2.5)),
        await table(sheet.summary),
      ],
    ];
    for (final t in sheet.tables) {
      content.addAll([
        // A heading never ends a page alone (the page's break-after: avoid).
        pw.NewPage(freeSpace: gap(64)),
        pw.SizedBox(height: gap(6.5)),
        if (t.title.isNotEmpty) ...[
          await line(
            [SheetRun(t.title)],
            width,
            size: gap(_headingSize),
            bold: true,
          ),
          pw.SizedBox(height: gap(2.5)),
        ],
        await table(t),
      ]);
    }
    if (sheet.notes.isNotEmpty) content.add(pw.SizedBox(height: gap(6.5)));
    for (final note in sheet.notes) {
      content.add(await line([SheetRun(note)], width, size: gap(_textSize)));
    }
    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(_margin),
        maxPages: 1000,
        build: (_) => content,
      ),
    );
  }
  return doc.save();
}
