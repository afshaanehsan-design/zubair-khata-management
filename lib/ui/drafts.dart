import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/l10n.dart' show Words, entryLabel;
import '../core/models.dart';
import '../features/ledger/entry_facts.dart'
    show entryAmountText, entryHeadline, entryTitle, entryTypeLabel;
import '../features/reports/reports.dart' show kg, money;
import 'components.dart';
import 'roznamcha_form.dart';
import 'roznamcha_widgets.dart' show confirmPlain, dmy, rozBorder, rozRed, rs;

/// What a list row says about a draft: who, what, how much and what is
/// still missing, so it makes sense without opening it.
class DraftFacts {
  final String title, kind, details, amount;
  final IconData icon;
  const DraftFacts(this.title, this.kind, this.details, this.amount, this.icon);
}

int _number(dynamic text, int places) {
  try {
    return decimal('${text ?? ''}', places);
  } catch (_) {
    return 0;
  }
}

String _joined(Iterable<String> parts) =>
    parts.where((p) => p.trim().isNotEmpty).join(' · ');

/// The time a draft was saved, in Pakistan time like every entry time.
String draftSavedAt(EntryDraft d) {
  final at = DateTime.fromMillisecondsSinceEpoch(d.savedAt)
      .toUtc()
      .add(const Duration(hours: 5));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(at.day)}-${two(at.month)}-${at.year} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// Reads a Roznamcha form snapshot (the text as typed) or a composer payload
/// leniently: a draft is unfinished, so nothing here may throw.
DraftFacts draftFacts(AppController app, EntryDraft d, Words t) {
  if (d.source == EntryDraft.composer) {
    try {
      final doc = Document(Record('draft', 'document', d.data));
      final amount = entryAmountText(doc);
      return DraftFacts(
        entryTitle(app, doc, t),
        entryTypeLabel(doc, t),
        entryHeadline(app, doc, t),
        amount == rs(0) ? '' : amount,
        entryIcon(doc.type),
      );
    } catch (_) {
      final type = EntryType.values.where((v) => v.name == d.tab).firstOrNull;
      return DraftFacts(
        t(entryLabel(d.tab)),
        '',
        '',
        '',
        type == null ? Icons.tune_rounded : entryIcon(type),
      );
    }
  }
  final s = d.data;
  final tab =
      RozTab.values.where((v) => v.name == d.tab).firstOrNull ?? RozTab.aamad;
  final kharcha =
      KharchaKind.values.where((v) => v.name == s['kind']).firstOrNull ??
      KharchaKind.cash;
  final lessMode = '${s['lessMode'] ?? 'discount'}';
  final kind = switch (tab) {
    RozTab.kharcha => t(kharcha.label),
    RozTab.less => t(switch (lessMode) {
      'bank' => 'Bank deposit (account mein jama)',
      'cashOut' => 'Cash kam (nuqsan / khata se bahar)',
      'cashIn' => 'Cash zyada (izafa)',
      _ => 'Khata se minus (discount)',
    }),
    _ => t(tab.label),
  };
  final party = '${s['party'] ?? ''}'.trim();
  final note = '${s['note'] ?? ''}'.trim();
  final parts = <String>[];
  var amount = 0;
  switch (tab) {
    case RozTab.aamad:
      final lines = [
        for (final size in sizes)
          if (_number(s['q$size'], 0) > 0)
            '${sizeLabel(size)} × ${_number(s['q$size'], 0)}',
      ];
      if (lines.isNotEmpty) parts.add(lines.join(', '));
      final bulk = _number(s['bulk'], 3);
      if (bulk > 0) parts.add('${t('Bulk KG')} ${kg(bulk)}');
      final rate = _number(s['rate'], 2);
      final gas = sizes.any((size) => _number(s['q$size'], 0) > 0);
      if (rate > 0 && (gas || (bulk > 0 && s['bulkAtCost'] == false))) {
        parts.add('${t('Rate')} ${money(rate)}');
      }
      final cash = _number(s['cash'], 2);
      if (cash > 0) parts.add('${t('Cash')} ${money(cash)}');
      var bank = _number(s['bank'], 2);
      final companies = <String>[
        if (s['bankDirect'] == true && '${s['directParty'] ?? ''}'.isNotEmpty)
          '${s['directParty']}',
      ];
      for (final l in (s['extraBanks'] as List?) ?? const []) {
        if (l is! Map) continue;
        bank += _number(l['amount'], 2);
        if (l['direct'] == true && '${l['company'] ?? ''}'.isNotEmpty) {
          companies.add('${l['company']}');
        }
      }
      if (bank > 0) parts.add('${t('Bank')} ${money(bank)}');
      if (companies.isNotEmpty) {
        parts.add('${t('Direct to party')}: ${companies.join(', ')}');
      }
      amount = cash + bank;
    case RozTab.companyIn:
      final cash = _number(s['cash'], 2), bank = _number(s['bank'], 2);
      if (cash > 0) parts.add('${t('Cash')} ${money(cash)}');
      if (bank > 0) parts.add('${t('Bank')} ${money(bank)}');
      amount = cash + bank;
    default:
      amount = _number(s['amount'], 2);
      final account = app.record('${s['account'] ?? ''}');
      final bankUsed = switch (tab) {
        RozTab.nikali => true,
        RozTab.kharcha =>
          kharcha == KharchaKind.bankJama || s['payBank'] == true,
        RozTab.office => s['payBank'] == true,
        RozTab.less => lessMode == 'bank',
        _ => false,
      };
      if (bankUsed && account != null && account.kind == 'account') {
        parts.add(account.name);
      }
  }
  if (note.isNotEmpty) parts.add(note);
  return DraftFacts(
    party.isEmpty ? kind : party,
    party.isEmpty ? '' : kind,
    _joined(parts),
    amount > 0 ? rs(amount) : '',
    tab.icon,
  );
}

/// The Drafts tab of the New entry section: every saved draft, newest first,
/// with Open and Delete.
class DraftList extends StatelessWidget {
  final AppController app;
  final ValueChanged<EntryDraft> onOpen;
  const DraftList({required this.app, required this.onOpen, super.key});

  @override
  Widget build(BuildContext context) {
    final drafts = app.entryDrafts;
    if (drafts.isEmpty) {
      return Container(
        key: const ValueKey('drafts-empty'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: rozBorder),
        ),
        child: Column(
          children: [
            const Icon(Icons.drafts_outlined, color: muted, size: 28),
            const SizedBox(height: 8),
            Text(
              context.t('Koi draft nahi'),
              style: const TextStyle(fontWeight: FontWeight.w700, color: ink),
            ),
            const SizedBox(height: 4),
            Text(
              context.t(
                'Adhoori entry ko "Draft" daba kar yahan rakhein. Baad mein kholein, poori karein aur Add karein.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: muted),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in drafts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _DraftRow(app: app, draft: d, onOpen: onOpen),
          ),
      ],
    );
  }
}

class _DraftRow extends StatelessWidget {
  final AppController app;
  final EntryDraft draft;
  final ValueChanged<EntryDraft> onOpen;
  const _DraftRow({
    required this.app,
    required this.draft,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final f = draftFacts(app, draft, context.words);
    final missing = draft.missing.trim();
    return Container(
      key: ValueKey('draft-${draft.id}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: rozBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(f.icon, size: 18, color: teal),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    if (f.kind.isNotEmpty || f.details.isNotEmpty)
                      Text(
                        _joined([f.kind, f.details]),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: ink),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      '${context.t('Tareekh')}: ${dmy(draft.date)} · '
                      '${context.t('Saved at')}: ${draftSavedAt(draft)}',
                      style: const TextStyle(fontSize: 11.5, color: muted),
                    ),
                  ],
                ),
              ),
              if (f.amount.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  f.amount,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ],
            ],
          ),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: amber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${context.t('Baqi')}: ${context.t(missing)}',
                      key: ValueKey('draft-missing-${draft.id}'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff855b20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton.icon(
                key: ValueKey('draft-delete-${draft.id}'),
                style: TextButton.styleFrom(
                  foregroundColor: rozRed,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () async {
                  if (await confirmPlain(context, 'Yeh draft delete karein?')) {
                    await app.deleteEntryDraft(draft.id);
                  }
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(context.t('Delete')),
              ),
              TextButton.icon(
                key: ValueKey('draft-open-${draft.id}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => onOpen(draft),
                icon: const Icon(Icons.edit_note_rounded, size: 18),
                label: Text(context.t('Kholein')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
