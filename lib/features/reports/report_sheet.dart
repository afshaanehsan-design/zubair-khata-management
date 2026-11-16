import '../../core/l10n.dart';
import '../../core/models.dart' show businessDate;
import 'reports.dart' show Cell, Report, hasUrduScript;
import 'roznamcha_sheet.dart';

// Every report's PDF is printed in the Roznamcha sheet's design
// (roznamcha_sheet.dart): a title and print stamp, a bold heading, a summary
// row of figures like the Roznamcha's cards, then titled tables with capital
// heads, a '#' column, amounts on the end side and bold Total rows. These
// helpers build such a sheet from a report's own columns and rows of [Cell].

/// One box of a report's summary row, like the Roznamcha's cards: a capital
/// heading, the figure in bold and small notes beside it.
class SheetFigure {
  final String label, value;
  final List<String> notes;
  const SheetFigure(this.label, this.value, [this.notes = const []]);
}

final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _isoTime = RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}');
final _datesIn = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b');

/// A report cell's text as the sheet prints it: a date like the Roznamcha
/// (25-10-2026), a moment like its print stamp, anything else as it is.
String sheetText(String text) {
  if (_isoDate.hasMatch(text)) return rozDmy(text);
  if (_isoTime.hasMatch(text)) {
    final time = DateTime.tryParse(text);
    if (time != null) return rozTime(time.toLocal());
  }
  return text;
}

/// [text] with every date in it written like the Roznamcha.
String sheetDates(String text) =>
    text.replaceAllMapped(_datesIn, (m) => '${m[3]}-${m[2]}-${m[1]}');

/// The dates a report covers, as its heading starts.
String sheetRange(String from, String to) =>
    from == to ? rozDmy(from) : '${rozDmy(from)} — ${rozDmy(to)}';

/// The summary row of [figures]; no row at all when there are none.
SheetTable summaryTable(List<SheetFigure> figures) => SheetTable(
  title: '',
  wrap: {for (var i = 0; i < figures.length; i++) i},
  head: [
    for (final f in figures) SheetCell.text(f.label.toUpperCase(), bold: true),
  ],
  body: [
    if (figures.isNotEmpty) [for (final f in figures) _figure(f)],
  ],
  top: true,
);

SheetCell _figure(SheetFigure f) {
  // With Urdu in the box, each part is isolated so it stays whole and in
  // its place ("2,568.5 kg" beside its notes), as the Roznamcha's gas box.
  final mixed = hasUrduScript([f.value, ...f.notes].join());
  String part(String s) => mixed
      ? '${String.fromCharCode(hasUrduScript(s) ? 0x2067 : 0x2066)}$s'
            '${String.fromCharCode(0x2069)}'
      : s;
  return SheetCell([
    [
      SheetRun(part(f.value), bold: true),
      if (f.notes.isNotEmpty) ...[
        const SheetRun(' '),
        SheetRun(f.notes.map(part).join(' | '), small: true),
      ],
    ],
  ]);
}

/// A report's rows as a table of the sheet, like the Roznamcha's tables:
/// capital heads, a '#' column numbering [rows] (unless not [numbered]), and
/// columns with figures (any [Cell] with a number) on the end side, with '—'
/// for nothing. [after] rows follow unnumbered (a balance brought forward),
/// then [total] in bold, its first cell's label spanning the columns up to
/// its first figure. [bold] columns and [boldRows] (indexes of [rows]) are
/// bold, like the Roznamcha's names and totals. Text columns with more than
/// one word may wrap; dates, references and figures keep one line.
SheetTable reportTable(
  Words t, {
  String title = '',
  required List<String> columns,
  required List<List<Cell>> rows,
  List<List<Cell>> after = const [],
  List<Cell>? total,
  Set<int> bold = const {},
  Set<int> boldRows = const {},
  bool numbered = true,
}) {
  final all = [...rows, ...after, ?total];
  final figure = [
    for (var i = 0; i < columns.length; i++)
      all.any((r) => i < r.length && r[i].numeric != null),
  ];
  final shift = numbered ? 1 : 0;
  SheetCell cell(Cell c, int i, {bool strong = false, bool dash = true}) {
    final text = sheetText(c.text);
    final heavy = strong || bold.contains(i);
    return figure[i]
        ? SheetCell.text(
            dash && text.trim().isEmpty ? '—' : text,
            align: SheetAlign.end,
            bold: heavy,
            numeric: true,
          )
        : SheetCell.text(text, bold: heavy);
  }

  List<SheetCell> line(List<Cell> r, String number, {bool strong = false}) => [
    if (numbered) SheetCell.text(number),
    for (var i = 0; i < columns.length; i++)
      cell(i < r.length ? r[i] : const Cell(''), i, strong: strong),
  ];
  final body = [
    for (final (k, r) in rows.indexed)
      line(r, '${k + 1}', strong: boldRows.contains(k)),
    for (final r in after) line(r, ''),
  ];
  if (body.isEmpty) {
    body.add([
      SheetCell.text(
        t('— Koi entry nahi —'),
        span: columns.length + shift,
        align: SheetAlign.center,
        muted: true,
      ),
    ]);
  }
  final foot = <List<SheetCell>>[];
  if (total != null) {
    var first = 1;
    while (first < columns.length && total[first].text.trim().isEmpty) {
      first++;
    }
    foot.add([
      SheetCell.text(total.first.text, bold: true, span: first + shift),
      for (var i = first; i < columns.length; i++)
        cell(total[i], i, strong: true, dash: false),
    ]);
  }
  return SheetTable(
    title: title,
    wrap: {
      for (var i = 0; i < columns.length; i++)
        if (!figure[i] &&
            all.any((r) => i < r.length && r[i].text.trim().contains(' ')))
          i + shift,
    },
    head: [
      if (numbered) SheetCell.text('#', bold: true),
      for (var i = 0; i < columns.length; i++)
        SheetCell.text(
          columns[i].toUpperCase(),
          bold: true,
          align: figure[i] ? SheetAlign.end : SheetAlign.start,
        ),
    ],
    body: body,
    foot: foot,
  );
}

/// A report printed as one sheet: [title] and [stamp], the bold [heading],
/// the summary row of [figures], then [tables] and [notes].
RozSheet reportSheet({
  required String date,
  required String title,
  required String stamp,
  required String heading,
  List<SheetFigure> figures = const [],
  required List<SheetTable> tables,
  List<String> notes = const [],
}) => RozSheet(
  date: date,
  title: title,
  stamp: stamp,
  heading: heading,
  summary: summaryTable(figures),
  tables: tables,
  notes: notes,
);

/// Any report without sheets of its own, as one sheet: its columns and rows
/// as one table under its business, title and subtitle.
RozSheet autoSheet(Report report) {
  final t = Words(report.urdu), today = businessDate();
  return reportSheet(
    date: today,
    title: [
      report.business,
      report.title,
    ].where((s) => s.trim().isNotEmpty).join(' — '),
    stamp: rozStamp(today, t),
    heading: sheetDates(report.subtitle),
    tables: [
      reportTable(t, columns: report.columns, rows: report.rows),
    ],
    notes: report.notes,
  );
}
