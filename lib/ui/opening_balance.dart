import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../features/ledger/roznamcha.dart';
import 'components.dart';
import 'roznamcha_widgets.dart';

/// There is no "fix the opening" form: every day opens with the previous
/// day's closing, and a wrong entry is corrected with ✏️.
///
/// Without [existing], enters the starting cash once, on the selected day.
/// With it, corrects that adjustment entry (an opening balance or a later
/// balance correction): the old entry is voided with the reason and replaced.
Future<void> editOpeningBalance(
  BuildContext context,
  AppController app, {
  Document? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _OpeningBalanceDialog(app, existing),
);

class _OpeningBalanceDialog extends StatefulWidget {
  final AppController app;
  final Document? existing;
  const _OpeningBalanceDialog(this.app, this.existing);
  @override
  State<_OpeningBalanceDialog> createState() => _OpeningBalanceDialogState();
}

class _OpeningBalanceDialogState extends State<_OpeningBalanceDialog> {
  final amount = TextEditingController();
  final reason = TextEditingController();
  String? error;
  bool saving = false;

  AppController get app => widget.app;
  Document? get existing => widget.existing;
  String get target => '${existing?.data['target'] ?? 'money:cash'}';
  String get id => target.substring(target.indexOf(':') + 1);

  /// Payables are shown the way they are read: what we owe is positive.
  int get sign => target.startsWith('ap:') ? -1 : 1;

  @override
  void initState() {
    super.initState();
    final d = existing;
    if (d != null) {
      final shown = sign * d.value('amount');
      amount.text = shown % 100 == 0
          ? '${shown ~/ 100}'
          : decimalText(shown, 2);
    }
  }

  @override
  void dispose() {
    amount.dispose();
    reason.dispose();
    super.dispose();
  }

  String get _name {
    if (target == 'money:cash') return context.t('Cash');
    if (target.startsWith('money:')) {
      final account = app.record(id);
      final name = account == null ? id : accountLabel(account);
      return '$name (${context.t('Account')})';
    }
    return '${app.name(id)} (${context.t(target.startsWith('ap:') ? 'Company' : 'Customer')})';
  }

  String get _amountLabel {
    final d = existing;
    if (d == null) return 'Cash in hand';
    if (!isOpeningBalance(d)) return 'Signed amount (+ / −)';
    return target.startsWith('ar:')
        ? 'Opening receivable'
        : target.startsWith('ap:')
        ? 'Opening payable'
        : 'Opening balance';
  }

  /// Why the entry cannot be saved yet, or null.
  String? _check(int value) {
    final d = existing;
    if (value == 0) return 'Raqam likhna zaroori hai';
    if (d == null && value < 0) {
      return 'Amounts and quantities cannot be negative';
    }
    if (d != null && reason.text.trim().isEmpty) return 'A reason is required';
    return null;
  }

  Future<void> _save() async {
    if (saving) return;
    final int value;
    try {
      value = decimal(amount.text, 2);
    } catch (e) {
      setState(() => error = errorText(context, e));
      return;
    }
    final d = existing;
    if (d != null && sign * value == d.value('amount')) {
      Navigator.pop(context);
      return;
    }
    final problem = _check(value);
    if (problem != null) {
      setState(() => error = context.t(problem));
      return;
    }
    final why = reason.text.trim();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (d == null) {
        await app.post({
          'type': 'adjustment',
          'date': app.selectedDate,
          'occurredAt': 0,
          'target': 'money:cash',
          'amount': value,
          'note': openingBalanceNote,
          'reference': app.nextReference('OP'),
          'form': RozForm.opening.name,
        });
      } else {
        await app.post(
          {
            'type': 'adjustment',
            'date': d.date,
            'occurredAt': integer(d.data['occurredAt']),
            'party': d.party,
            'target': target,
            'amount': sign * value,
            'note': d.note,
            if (d.data['form'] != null) 'form': d.data['form'],
          },
          replace: d,
          reason: why,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.t('Saved'))));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorText(context, e);
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = existing;
    final title = d == null
        ? 'Opening cash'
        : isOpeningBalance(d)
        ? 'Opening balance'
        : 'Adjustment';
    return AlertDialog(
      title: Text(context.t(title)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              d == null
                  ? context.t(
                      'Kaam shuru karte waqt haath mein kitna cash tha? Yeh sirf ek dafa daalna hai. Galti ho to ✏️ se theek karein.',
                    )
                  : '$_name · ${dmy(d.date)}',
              style: const TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            RozInput(
              _amountLabel,
              amount,
              key: const ValueKey('opening-amount'),
              hint: 'Rs. 0',
              signed: d != null,
              helper: d != null && target.startsWith('ar:')
                  ? context.t(
                      'Opening balance may be negative when you owe money.',
                    )
                  : null,
              onSubmitted: d == null ? _save : null,
              onChanged: (_) {
                if (error != null) setState(() => error = null);
              },
            ),
            if (d != null) ...[
              const SizedBox(height: 12),
              RozInput(
                'Reason for correction',
                reason,
                key: const ValueKey('opening-reason'),
                number: false,
                onSubmitted: _save,
                onChanged: (_) {
                  if (error != null) setState(() => error = null);
                },
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  key: const ValueKey('opening-error'),
                  style: const TextStyle(
                    color: rozRed,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.t('Cancel')),
        ),
        FilledButton(
          key: const ValueKey('opening-save'),
          onPressed: saving ? null : _save,
          child: Text(context.t(d == null ? 'Save' : 'Update')),
        ),
      ],
    );
  }
}
