import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/models.dart';
import 'components.dart';

Future<void> editMaster(
  BuildContext context,
  AppController app,
  String kind, {
  Record? existing,
  Json? proposed,
  Future<void> Function()? onSaved,
  String? newId,
  int openingValue = 0,
  int payableValue = 0,
  String? openingDate,
}) async {
  final initial = proposed ?? existing?.data ?? <String, dynamic>{};
  final fields = {
    for (final key in ['name', 'phone', 'bank', 'category', 'address'])
      key: TextEditingController(text: '${initial[key] ?? ''}'),
  };
  final opening = TextEditingController(
        text: openingValue == 0 ? '' : decimalText(openingValue, 2),
      ),
      payable = TextEditingController(
        text: payableValue == 0 ? '' : decimalText(payableValue, 2),
      );
  var customer = initial['customer'] != false,
      supplier = initial['supplier'] == true,
      udhari = initial['udhari'] == true,
      saving = false;
  // The day the opening balances are entered on; starts at the page's date.
  var openedOn = openingDate ?? app.selectedDate;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text(
          ctx.t(
            existing == null
                ? kind == 'party'
                      ? 'Add party'
                      : 'Add account'
                : 'Edit',
          ),
        ),
        content: SizedBox(
          width: 470,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final key
                    in (kind == 'party'
                        ? ['name', 'phone', 'address']
                        : ['name', 'bank', 'category']))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 15),
                    child: TextField(
                      controller: fields[key],
                      textDirection: key == 'phone' ? TextDirection.ltr : null,
                      keyboardType: key == 'phone' ? TextInputType.phone : null,
                      decoration: InputDecoration(
                        labelText: ctx.t(
                          {
                            'name': 'Name',
                            'phone': 'Phone',
                            'address': 'Address',
                            'bank': 'Bank',
                            'category': 'Category',
                          }[key]!,
                        ),
                      ),
                      autofocus: key == 'name',
                    ),
                  ),
                if (kind == 'party') ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(ctx.t('Customer')),
                    value: customer,
                    onChanged: (v) => update(() => customer = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(ctx.t('Supplier')),
                    value: supplier,
                    onChanged: (v) => update(() => supplier = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(ctx.t('Udhari')),
                    value: udhari,
                    onChanged: (v) => update(() => udhari = v),
                  ),
                ],
                if (existing == null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: opening,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: ctx.t(
                        kind == 'party'
                            ? 'Opening receivable'
                            : 'Opening balance',
                      ),
                      prefixText: 'Rs ',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ctx.t(
                      'Opening balance may be negative when you owe money.',
                    ),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  if (kind == 'party')
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: TextField(
                        controller: payable,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          labelText: ctx.t('Opening payable'),
                          prefixText: 'Rs ',
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        final picked = await pickDate(ctx, openedOn);
                        if (picked != null) update(() => openedOn = picked);
                      },
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: ctx.t('Opening balance date'),
                          suffixIcon: const Icon(
                            Icons.calendar_today_outlined,
                            size: 18,
                          ),
                        ),
                        child: Text(openedOn, textDirection: TextDirection.ltr),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(ctx),
            child: Text(ctx.t('Cancel')),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    update(() => saving = true);
                    final ok = await perform(ctx, () async {
                      await app.saveMaster(
                        kind,
                        {
                          for (final entry in fields.entries)
                            entry.key: entry.value.text.trim(),
                          if (kind == 'party') ...{
                            'customer': customer,
                            'supplier': supplier,
                            'udhari': udhari,
                          },
                          'archived': existing?.archived ?? false,
                        },
                        existing: existing,
                        newId: newId,
                        opening: decimal(opening.text, 2),
                        supplierOpening: decimal(payable.text, 2),
                        openingDate: openedOn,
                      );
                    }, success: 'Saved');
                    if (ok) await onSaved?.call();
                    if (ctx.mounted) {
                      if (ok) {
                        Navigator.pop(ctx);
                      } else {
                        update(() => saving = false);
                      }
                    }
                  },
            child: Text(ctx.t('Save')),
          ),
        ],
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final c in [...fields.values, opening, payable]) {
    c.dispose();
  }
}
