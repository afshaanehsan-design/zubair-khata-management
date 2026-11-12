import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'export_ui.dart';

class ReportsPage extends StatefulWidget {
  final AppController app;
  const ReportsPage(this.app, {super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String selected = 'Daily roznamcha',
      from = '${businessDate().substring(0, 8)}01',
      to = businessDate(),
      party = '',
      account = '';
  bool? urdu;
  bool exporting = false;
  @override
  Widget build(BuildContext context) {
    final report = buildReport(
      widget.app,
      selected,
      from,
      to,
      party: party.isEmpty ? null : party,
      account: account.isEmpty ? null : account,
      urdu: urdu ?? widget.app.urdu,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading('Reports', 'Overview'),
        LayoutBuilder(
          builder: (ctx, box) {
            final choices = Panel(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  for (final name in reportNames)
                    ListTile(
                      dense: true,
                      selected: selected == name,
                      selectedTileColor: const Color(0xffeaf1e5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      title: Text(
                        ctx.t(name),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      leading: Icon(
                        name == 'Profit report'
                            ? Icons.trending_up
                            : Icons.article_outlined,
                        size: 18,
                      ),
                      onTap: () => setState(() => selected = name),
                    ),
                ],
              ),
            );
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ctx.t(selected),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 10,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final v = await pickDate(ctx, from);
                              if (v != null) {
                                setState(() {
                                  from = v;
                                  if (to.compareTo(from) < 0) to = from;
                                });
                              }
                            },
                            icon: const Icon(Icons.date_range, size: 17),
                            label: Text(from),
                          ),
                          OutlinedButton(
                            onPressed: () async {
                              final v = await pickDate(ctx, to);
                              if (v != null) {
                                setState(() {
                                  to = v;
                                  if (from.compareTo(to) > 0) from = to;
                                });
                              }
                            },
                            child: Text(to),
                          ),
                          if (selected == 'Party statement')
                            OutlinedButton(
                              onPressed: () async {
                                final id = await pickRecord(
                                  ctx,
                                  widget.app,
                                  'party',
                                );
                                if (id != null) setState(() => party = id);
                              },
                              child: Text(
                                party.isEmpty
                                    ? ctx.t('Choose a party')
                                    : widget.app.name(party),
                              ),
                            ),
                          if (selected == 'Bank book')
                            OutlinedButton(
                              onPressed: () async {
                                final id = await pickRecord(
                                  ctx,
                                  widget.app,
                                  'account',
                                );
                                if (id != null) setState(() => account = id);
                              },
                              child: Text(
                                account.isEmpty
                                    ? ctx.t('Choose an account')
                                    : widget.app.name(account),
                              ),
                            ),
                          FilterChip(
                            label: Text(ctx.t('Urdu')),
                            selected: urdu ?? widget.app.urdu,
                            onSelected: (v) => setState(() => urdu = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: exporting
                                ? null
                                : () => previewReport(ctx, report),
                            icon: const Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 18,
                            ),
                            label: Text(ctx.t('Preview PDF')),
                          ),
                          OutlinedButton.icon(
                            onPressed: exporting
                                ? null
                                : () => export(report, 'xlsx'),
                            icon: const Icon(Icons.grid_on_outlined, size: 18),
                            label: Text(ctx.t('Export Excel')),
                          ),
                          TextButton(
                            onPressed: exporting
                                ? null
                                : () => export(report, 'csv'),
                            child: Text(ctx.t('Export CSV')),
                          ),
                          IconButton(
                            tooltip: ctx.t('Copy table'),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: [
                                  report.columns.join('\t'),
                                  ...report.rows.map(
                                    (r) => r.map((c) => c.text).join('\t'),
                                  ),
                                ].join('\n'),
                              ),
                            ),
                            icon: const Icon(Icons.copy_outlined, size: 18),
                          ),
                        ],
                      ),
                      if (exporting) const LinearProgressIndicator(),
                      for (final note in report.notes)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Notice(note),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ReportDataTable(report),
              ],
            );
            return box.maxWidth > 1050
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 232, child: choices),
                      const SizedBox(width: 20),
                      Expanded(child: content),
                    ],
                  )
                : Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: DropdownButtonFormField<String>(
                          initialValue: selected,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: ctx.t('Reports'),
                          ),
                          items: reportNames
                              .map(
                                (name) => DropdownMenuItem(
                                  value: name,
                                  child: Text(ctx.t(name)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => selected = v!),
                        ),
                      ),
                      const SizedBox(height: 20),
                      content,
                    ],
                  );
          },
        ),
      ],
    );
  }

  Future<void> export(Report report, String format) async {
    setState(() => exporting = true);
    await perform(context, () async {
      final exporter = ReportExporter();
      final bytes = format == 'xlsx'
          ? exporter.excel(report)
          : exporter.csvBytes(report);
      await saveBytes(
        context,
        bytes,
        'ZubairKhata_${selected.replaceAll(' ', '_')}_$to',
        format,
      );
    });
    if (mounted) setState(() => exporting = false);
  }
}

class ReportDataTable extends StatefulWidget {
  final Report report;
  const ReportDataTable(this.report, {super.key});
  @override
  State<ReportDataTable> createState() => _ReportDataTableState();
}

class _ReportDataTableState extends State<ReportDataTable> {
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.all(8),
    child: widget.report.rows.isEmpty
        ? const EmptyState('No results', 'Your entries will appear here.')
        // PaginatedDataTable already scrolls horizontally on its own; wrapping
        // it in another horizontal scroll view gives it infinite width and
        // its stretched header/footer fail to lay out.
        : PaginatedDataTable(
              key: ValueKey(
                '${widget.report.title}|${widget.report.subtitle}|${widget.report.urdu}',
              ),
              headingRowColor: const WidgetStatePropertyAll(Color(0xfff1f5ed)),
              columnSpacing: 22,
              horizontalMargin: 16,
              dataRowMinHeight: 50,
              dataRowMaxHeight: 100,
              showFirstLastButtons: true,
              rowsPerPage: widget.report.rows.length < 10
                  ? widget.report.rows.length
                  : 10,
              columns: widget.report.columns
                  .map(
                    (label) => DataColumn(
                      label: SizedBox(
                        width: 125,
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: muted,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
              source: _ReportSource(widget.report),
            ),
  );
}

class _ReportSource extends DataTableSource {
  final Report report;
  _ReportSource(this.report);
  @override
  int get rowCount => report.rows.length;
  @override
  bool get isRowCountApproximate => false;
  @override
  int get selectedRowCount => 0;
  @override
  DataRow? getRow(int index) => index >= report.rows.length
      ? null
      : DataRow.byIndex(
          index: index,
          cells: report.rows[index]
              .map(
                (c) => DataCell(
                  SizedBox(
                    width: 125,
                    child: Text(
                      c.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textDirection: c.numeric == null
                          ? null
                          : TextDirection.ltr,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              )
              .toList(),
        );
}
