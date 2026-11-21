import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/controller.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../features/ledger/entry_facts.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'entry_composer.dart';
import 'export_ui.dart';
import 'masters.dart';
import 'roznamcha_form.dart';
import 'roznamcha_widgets.dart' show confirmDelete, confirmPlain;

/// One entry in a list: who, what it contains, how much, and whether it is
/// paid. The same row is used on the Activity page, in the party dialog and in
/// the Roznamcha "other entries" panel.
class TransactionTile extends StatelessWidget {
  final AppController app;
  final Document document;

  /// Use the party as the title. The party dialog turns this off, because
  /// every row there belongs to the same party.
  final bool showParty;

  /// What the party owed after this entry: a running balance, like a khata.
  final int? balanceAfter;

  /// The party whose khata lists this row. For the party a customer paid
  /// directly, the row is the money it got, not the customer's whole sale.
  final String? khata;
  const TransactionTile(
    this.app,
    this.document, {
    this.showParty = true,
    this.balanceAfter,
    this.khata,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final d = document, t = context.words;
    final direct = directFor(d, khata);
    final type = direct ? directTitle(t) : entryTypeLabel(d, t);
    final title = showParty && !direct ? entryTitle(app, d, t) : type;
    final headline = direct
        ? directHeadline(app, d, khata!, t)
        : entryHeadline(app, d, t);
    final status = direct ? null : entryStatus(app, d, t);
    final dueDate =
        d.type == EntryType.sale &&
            !direct &&
            !d.voided &&
            (app.book.invoiceDue[d.id] ?? 0) > 0
        ? '${d.data['dueDate'] ?? ''}'
        : '';
    final meta = [
      if (title != type) type,
      d.date,
      d.reference,
      if (dueDate.isNotEmpty) '${t('Due date')}: $dueDate',
    ].join(' · ');
    // Custom row instead of ListTile: ListTile clamps the trailing slot to a
    // fixed height, which overflows once the amount + status tag (or taller
    // Urdu glyphs) don't fit. This layout grows with its content.
    return Opacity(
      opacity: d.voided ? .55 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showTransaction(context, app, d),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xffeef4ef),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(entryIcon(d.type), color: teal, size: 21),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: ink,
                      ),
                    ),
                    if (headline.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: ink),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      style: const TextStyle(fontSize: 11, color: muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      direct ? rs(d.directTo(khata!)) : entryAmountText(d),
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: entryAmountNegative(d) ? danger : ink,
                      ),
                    ),
                    if (status != null) ...[
                      const SizedBox(height: 5),
                      Tag(status.label, warning: status.warning),
                    ],
                    if (balanceAfter != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        balanceText(balanceAfter!, t),
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                    // Only a signed-in device syncs; elsewhere every entry
                    // would read "waiting" for ever.
                    if (app.signedIn && d.record.pending) ...[
                      const SizedBox(height: 5),
                      const Tag('Waiting to sync'),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label with its value, as one row of a details card. A row that names
/// another entry (an invoice a payment settled) opens it when tapped.
Widget _factRow(BuildContext context, AppController app, Fact f) {
  // Left-to-right text (numbers, "11.8 KG") sits on the page's start or end
  // edge, whichever the page direction makes it: TextAlign.start/end would
  // follow the text's own direction instead.
  final rtlPage = Directionality.of(context) == TextDirection.rtl;
  final startSide = rtlPage ? TextAlign.right : TextAlign.left;
  final endSide = rtlPage ? TextAlign.left : TextAlign.right;
  final label = Text(
    f.label,
    textDirection: valueDirection(context, f.label),
    textAlign: startSide,
    style: const TextStyle(color: muted, fontSize: 13),
  );
  final value = Text(
    f.value,
    textDirection: valueDirection(context, f.value),
    textAlign: endSide,
    style: TextStyle(
      fontWeight: f.strong ? FontWeight.w800 : FontWeight.w600,
      fontSize: f.strong ? 14.5 : 13.5,
      color: f.openId != null ? teal : ink,
    ),
  );
  final chevron = f.openId == null
      ? null
      : const Icon(Icons.chevron_right_rounded, size: 16, color: muted);
  final row = Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: LayoutBuilder(
      builder: (context, box) {
        // On a phone a long label and value would squeeze into three lines
        // each; stack them instead.
        final stacked =
            box.maxWidth < 360 && f.label.length + f.value.length > 28;
        if (stacked) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label,
                    const SizedBox(height: 2),
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        f.value,
                        textDirection: valueDirection(context, f.value),
                        textAlign: startSide,
                        style: TextStyle(
                          fontWeight: f.strong
                              ? FontWeight.w800
                              : FontWeight.w600,
                          fontSize: f.strong ? 14.5 : 13.5,
                          color: f.openId != null ? teal : ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ?chevron,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: label),
            const SizedBox(width: 12),
            Expanded(flex: 6, child: value),
            ?chevron,
          ],
        );
      },
    ),
  );
  final target = f.openId == null ? null : app.record(f.openId!);
  if (target == null) return row;
  return InkWell(
    onTap: () => showTransaction(context, app, Document(target)),
    child: row,
  );
}

/// One line of the bill: "11.8 KG × 20" with its weight underneath.
Widget _billRow(BuildContext context, BillRow r) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              r.label,
              textDirection: valueDirection(context, r.label),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            if (r.caption != null)
              Text(
                r.caption!,
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: muted, fontSize: 11.5),
              ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Text(
        rs(r.amount),
        textDirection: TextDirection.ltr,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    ],
  ),
);

/// A white card with a small heading, one per topic of the details dialog.
Widget _card(String title, List<Widget> children) => Padding(
  padding: const EdgeInsets.only(top: 12),
  child: Panel(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Builder(
          builder: (c) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              c.t(title),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ),
        ),
        ...children,
      ],
    ),
  ),
);

/// An explanation under a figure, so a number that looks wrong is explained
/// where it is shown.
Widget _hint(String text) => Padding(
  padding: const EdgeInsets.only(top: 6, bottom: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.info_outline_rounded, size: 16, color: amber),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(color: Color(0xff855b20), fontSize: 12.5),
        ),
      ),
    ],
  ),
);

Future<void> showTransaction(
  BuildContext context,
  AppController app,
  Document initial,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: app,
      builder: (ctx, _) {
        final d = Document(app.record(initial.id) ?? initial.record);
        final t = ctx.words;
        final postings = app.book.postings
            .where((p) => p.document == d.id)
            .toList();
        final bill = d.type == EntryType.sale || d.type == EntryType.creditNote;
        final status = entryStatus(app, d, t);
        final cylinders = cylinderFacts(app, d, t);
        final payment = paymentFacts(app, d, t);
        final notes = paymentNotes(app, d, t);
        final received = billPayments(app, d, t);
        final applied = appliedFacts(app, d, t);
        final details = detailFacts(app, d, t);
        final replaces = d.data['replaces'] == null
            ? null
            : app.record('${d.data['replaces']}');
        final replacement = d.data['replacement'] == null
            ? null
            : app.record('${d.data['replacement']}');
        return AlertDialog(
          title: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xffeef4ef),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(entryIcon(d.type), color: teal, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entryTypeLabel(d, t),
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      d.reference,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        color: muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // What it is, in one glance: who, how much, and its state.
                  Panel(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entryTitle(app, d, t),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: ink,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Tag(d.date),
                              if (status != null)
                                Tag(status.label, warning: status.warning),
                              if (app.signedIn && d.record.pending)
                                const Tag('Waiting to sync'),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            entryAmountLabel(d, t),
                            style: const TextStyle(color: muted, fontSize: 12),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            entryAmountText(d),
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: entryAmountNegative(d) ? danger : ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (bill)
                    _card(
                      d.type == EntryType.sale
                          ? 'What was sold'
                          : 'Items credited',
                      [
                        for (final r in billRows(
                          d,
                          t,
                          shareFrom: app.shareSource(d),
                        ))
                          _billRow(ctx, r),
                        const Divider(height: 18),
                        _factRow(
                          ctx,
                          app,
                          Fact(t('Rate per 11.8 KG'), rs(d.rate)),
                        ),
                        _factRow(
                          ctx,
                          app,
                          Fact(
                            entryAmountLabel(d, t),
                            rs(entryAmount(d)),
                            strong: true,
                          ),
                        ),
                      ],
                    ),
                  if (cylinders.isNotEmpty)
                    _card('Cylinders', [
                      for (final f in cylinders) _factRow(ctx, app, f),
                    ]),
                  if (payment.isNotEmpty)
                    _card('Payment', [
                      for (final f in payment) _factRow(ctx, app, f),
                      for (final n in notes) _hint(n),
                    ]),
                  if (received.isNotEmpty)
                    _card('Payments received for this bill', [
                      for (final f in received) _factRow(ctx, app, f),
                    ]),
                  if (applied.isNotEmpty)
                    _card('Applied to', [
                      for (final f in applied) _factRow(ctx, app, f),
                    ]),
                  if (details.isNotEmpty)
                    _card('Details', [
                      for (final f in details) _factRow(ctx, app, f),
                    ]),
                  if (postings.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Panel(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Theme(
                          data: Theme.of(ctx)
                              .copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 10),
                            title: Text(
                              ctx.t('Accounting entries'),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: ink,
                              ),
                            ),
                            children: [
                              for (final p in postings)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 5,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          p.setOff
                                              ? '${postingLabel(app, p.account, t)} · ${t('Set off')}'
                                              : postingLabel(app, p.account, t),
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        signedRs(
                                          postingEffect(p.account, p.debit),
                                        ),
                                        textDirection: TextDirection.ltr,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color:
                                              postingEffect(
                                                    p.account,
                                                    p.debit,
                                                  ) <
                                                  0
                                              ? danger
                                              : ink,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (replaces != null || replacement != null || d.voided)
                    _card('Audit trail', [
                      if ('${d.data['voidReason'] ?? ''}'.isNotEmpty)
                        _factRow(
                          ctx,
                          app,
                          Fact(
                            t('Reason for correction'),
                            '${d.data['voidReason']}',
                          ),
                        ),
                      if (replaces != null)
                        _factRow(
                          ctx,
                          app,
                          Fact(
                            t('Replaces'),
                            Document(replaces).reference,
                            openId: replaces.id,
                          ),
                        ),
                      if (replacement != null)
                        _factRow(
                          ctx,
                          app,
                          Fact(
                            t('Replaced by'),
                            Document(replacement).reference,
                            openId: replacement.id,
                          ),
                        ),
                    ]),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () =>
                  previewReport(ctx, invoiceReport(app, d, urdu: app.urdu)),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(ctx.t('Preview PDF')),
            ),
            if (!d.voided)
              TextButton(
                // Deleting voids the entry. The ledger is replayed without
                // it, so any gas it took goes back to its FIFO lots by
                // itself; there is nothing to choose.
                onPressed: () async {
                  final reason = await confirmDelete(
                    ctx,
                    'Delete this entry? Its gas goes back to stock automatically and its amounts leave the khata.',
                  );
                  if (reason == null || !ctx.mounted) return;
                  final ok = await perform(
                    ctx,
                    () => app.voidDocument(d, reason),
                    success: 'Entry delete ho gayi',
                  );
                  if (ok && ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(
                  ctx.t('Delete'),
                  style: const TextStyle(color: Color(0xffa33d3d)),
                ),
              ),
            if (!d.voided)
              FilledButton.tonal(
                onPressed: () async {
                  await composeEntry(ctx, app, replace: d);
                },
                child: Text(ctx.t(d.isDraft ? 'Open' : 'Correct entry')),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.t('Close')),
            ),
          ],
        );
      },
    ),
  );
}

/// Deletes a party that has no entries. With entries it explains why not (a
/// dialog, because a snack bar would sit behind the party dialog).
/// [onDeleted] closes the party dialog; beside the list there is nothing to
/// close, the list simply loses the party.
Future<void> _deleteParty(
  BuildContext ctx,
  AppController app,
  Record p, {
  VoidCallback? onDeleted,
}) async {
  if (app.partyHasEntries(p.id)) {
    await showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        content: Text(
          c
              .t(
                '{name} has entries, so it cannot be deleted. Delete its entries first, or use Archive to hide it.',
              )
              .replaceAll('{name}', p.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(c.t('Close')),
          ),
        ],
      ),
    );
    return;
  }
  final ok = await confirmPlain(
    ctx,
    ctx
        .t('Delete {name}? It has no entries and will be removed.')
        .replaceAll('{name}', p.name),
  );
  if (!ok || !ctx.mounted) return;
  final done = await perform(
    ctx,
    () => app.deleteParty(p),
    success: 'Party deleted',
  );
  if (done && ctx.mounted) onDeleted?.call();
}

/// An unpaid invoice of a party: its bill, what was paid, and what is left.
Widget _unpaidInvoice(BuildContext ctx, AppController app, Document d) {
  final t = ctx.words;
  final due = app.book.invoiceDue[d.id] ?? 0;
  final dueDate = '${d.data['dueDate'] ?? ''}';
  return InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: () => showTransaction(ctx, app, d),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.reference,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 14, color: ink),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    d.date,
                    '${t('Bill')} ${rs(d.total)}',
                    '${t('Paid')} ${rs(d.total - due)}',
                    if (dueDate.isNotEmpty) '${t('Due date')}: $dueDate',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 11.5, color: muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Amount(due),
              const SizedBox(height: 3),
              Text(
                t('Still due'),
                style: const TextStyle(fontSize: 11, color: amber),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<void> showParty(
  BuildContext context,
  AppController app,
  Record party,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 960,
        height: MediaQuery.sizeOf(ctx).height * .9,
        child: AnimatedBuilder(
          animation: app,
          builder: (ctx, _) =>
              PartyDetails(app, party, onClose: () => Navigator.pop(ctx)),
        ),
      ),
    ),
  );
}

/// A party's balances as small tiles: side by side when there is room,
/// stacked on a phone. Compact, so the ledger below stays in view.
Widget _balanceStrip(
  BuildContext ctx,
  List<(String, int, Color, String?)> items,
) => LayoutBuilder(
  builder: (context, box) {
    final wide = box.maxWidth >= 420;
    final tiles = [
      for (final (label, value, color, detail) in items)
        Container(
          width: wide ? null : double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
          decoration: BoxDecoration(
            color: const Color(0xfff3f6f2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ctx.t(label),
                style: const TextStyle(fontSize: 11.5, color: muted),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'Rs ${money(value)}',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ),
              if (detail != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    detail,
                    style: const TextStyle(fontSize: 10.5, color: muted),
                  ),
                ),
            ],
          ),
        ),
    ];
    if (!wide) {
      return Column(
        children: [
          for (final t in tiles)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: t),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  },
);

/// Everything about one party: what it owes and is owed, cylinders, unpaid
/// invoices and its ledger with a running balance. Shown in the party dialog
/// and, on a wide screen, beside the party list on the Parties page.
class PartyDetails extends StatelessWidget {
  final AppController app;
  final Record party;

  /// Closes the party dialog. Null beside the list, where there is nothing to
  /// close.
  final VoidCallback? onClose;
  const PartyDetails(this.app, this.party, {this.onClose, super.key});

  @override
  Widget build(BuildContext ctx) {
    final p = app.record(party.id) ?? party, book = app.book;
    // Its own entries, and what customers paid to it directly.
    final documents = book.documents
        .where((d) => d.party == p.id || directFor(d, p.id))
        .toList()
        .reversed
        .toList();
    final balances = partyBalances(book, p.id);
    final (:receive, :pay) = partyOwed(book, p.id);
    final net = receive - pay;
    final unpaid = documents
        .where(
          (d) =>
              d.type == EntryType.sale &&
              d.party == p.id &&
              (book.invoiceDue[d.id] ?? 0) > 0,
        )
        .toList();
    final holds = [
      for (final size in sizes)
        if ((book.held['${p.id}:$size'] ?? 0) != 0)
          '${sizeLabel(size)} × ${book.held['${p.id}:$size']}',
    ];
    // Beside the list the pane is shorter than the dialog, so it is a little
    // tighter.
    final gap = onClose == null ? 16.0 : 20.0;
    // Paying an Udhari party or a company back has its own button, which
    // opens the Kharcha tab already on the right type for this khata. It
    // leads for a party that is not a customer.
    final payKind = p.data['udhari'] == true || p.data['supplier'] == true
        ? kharchaKindFor(p)
        : null;
    final payFirst = payKind != null && p.data['customer'] == false;
    void openPay() =>
        openRoznamchaForm(ctx, app, tab: RozTab.kharcha, party: p.id);
    void openAamad() =>
        composeEntry(ctx, app, type: EntryType.sale, party: p.id);
    final payIcon = Icon(RozTab.kharcha.icon);
    final payLabel = Text(ctx.t(payKind?.label ?? ''));
    const aamadIcon = Icon(Icons.add);
    final aamadLabel = Text(ctx.t('Aamad / Wasooli'));
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gap, gap, gap - 4, gap - 4),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xffe4eee2),
                child: Text(
                  p.name.isEmpty ? '?' : p.name.characters.first,
                  style: const TextStyle(color: teal),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ('${p.data['phone'] ?? ''}'.isNotEmpty)
                      Text(
                        '${p.data['phone']}',
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(color: muted),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: ctx.t('Edit'),
                onPressed: () => editMaster(ctx, app, 'party', existing: p),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: ctx.t('Delete'),
                onPressed: () => _deleteParty(ctx, app, p, onDeleted: onClose),
                icon: const Icon(Icons.delete_outline),
              ),
              if (onClose != null)
                IconButton(
                  tooltip: ctx.t('Close'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(gap + 2, 0, gap + 2, gap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _balanceStrip(ctx, [
                  (
                    'You will receive',
                    receive,
                    receive > 0 ? ink : muted,
                    receive > 0 && pay > 0 && net >= 0
                        ? '${ctx.t('Net: you will receive')} Rs ${money(net)}'
                        : null,
                  ),
                  (
                    'You will pay',
                    pay,
                    pay > 0 ? danger : muted,
                    receive > 0 && pay > 0 && net < 0
                        ? '${ctx.t('Net: you will pay')} Rs ${money(-net)}'
                        : null,
                  ),
                  (
                    'Refundable deposit',
                    book.deposits(p.id),
                    book.deposits(p.id) != 0 ? ink : muted,
                    null,
                  ),
                ]),
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (payFirst) ...[
                      FilledButton.icon(
                        key: const ValueKey('party-pay'),
                        onPressed: openPay,
                        icon: payIcon,
                        label: payLabel,
                      ),
                      OutlinedButton.icon(
                        onPressed: openAamad,
                        icon: aamadIcon,
                        label: aamadLabel,
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: openAamad,
                        icon: aamadIcon,
                        label: aamadLabel,
                      ),
                      if (payKind != null)
                        OutlinedButton.icon(
                          key: const ValueKey('party-pay'),
                          onPressed: openPay,
                          icon: payIcon,
                          label: payLabel,
                        ),
                    ],
                    // Gas bought from a company, with the company filled in.
                    if (p.data['supplier'] == true)
                      OutlinedButton.icon(
                        key: const ValueKey('party-purchase'),
                        onPressed: () => composeEntry(
                          ctx,
                          app,
                          type: EntryType.purchase,
                          party: p.id,
                        ),
                        icon: Icon(entryIcon(EntryType.purchase)),
                        label: Text(ctx.t('Purchase')),
                      ),
                    // A deposit taken with a sale is paid back from here.
                    if (book.deposits(p.id) > 0)
                      OutlinedButton.icon(
                        key: const ValueKey('party-deposit-refund'),
                        onPressed: () => composeEntry(
                          ctx,
                          app,
                          type: EntryType.depositRefund,
                          party: p.id,
                        ),
                        icon: const Icon(Icons.undo_rounded),
                        label: Text(ctx.t('Refund deposit')),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => previewReport(
                        ctx,
                        buildReport(
                          app,
                          'Party statement',
                          // From the party's first entry (the list is
                          // newest first).
                          documents.isEmpty
                              ? businessDate()
                              : documents.last.date,
                          businessDate(),
                          party: p.id,
                          urdu: app.urdu,
                        ),
                      ),
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: Text(ctx.t('Statement')),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final t = Words(app.urdu);
                        await SharePlus.instance.share(
                          ShareParams(
                            text:
                                '${app.businessName}\n${p.name}\n${t('You will receive')}: Rs ${money(receive)}\n${t('Date')}: ${businessDate()}',
                          ),
                        );
                      },
                      icon: const Icon(Icons.share_outlined),
                      label: Text(ctx.t('Share reminder')),
                    ),
                    // In the button row rather than a footer, so it costs no
                    // height in the pane beside the list.
                    TextButton.icon(
                      onPressed: () => perform(
                        ctx,
                        () => app.saveMaster('party', {
                          ...p.data,
                          'archived': !p.archived,
                        }, existing: p),
                      ),
                      icon: Icon(
                        p.archived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                      ),
                      label: Text(ctx.t(p.archived ? 'Unarchive' : 'Archive')),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const SectionHeader('Cylinders with customer'),
                if (holds.isEmpty)
                  Text(
                    ctx.t('No cylinders with this customer'),
                    style: const TextStyle(color: muted),
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [for (final h in holds) Tag(h)],
                  ),
                const SizedBox(height: 24),
                const SectionHeader('Unpaid invoices'),
                if (unpaid.isEmpty)
                  Text(
                    ctx.t('No unpaid invoices'),
                    style: const TextStyle(color: muted),
                  )
                else
                  for (final d in unpaid) _unpaidInvoice(ctx, app, d),
                const SizedBox(height: 20),
                const SectionHeader('Activity'),
                if (documents.isEmpty)
                  const EmptyState(
                    'No transactions yet',
                    'Your entries will appear here.',
                  ),
                for (final d in documents)
                  TransactionTile(
                    app,
                    d,
                    showParty: false,
                    balanceAfter: balances[d.id],
                    khata: p.id,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
