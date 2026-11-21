import 'package:flutter/material.dart';

import '../core/controller.dart';
import 'components.dart';

const _add = '+';

/// Lists the organizations on this device, opens the one that is chosen or
/// adds a new one. Opening another organization rebuilds the whole app (see
/// `KhataRoot`), so [context] is gone once that has happened.
Future<void> showOrganizations(BuildContext context, AppController app) async {
  final orgs = app.organizations;
  if (orgs == null) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Organizations')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ctx.t(
                  'Each organization is a separate khata on this device. Online, each one signs in with its own email.',
                ),
                style: const TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (final o in orgs.list)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    o.id == orgs.current.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: teal,
                  ),
                  title: Text(
                    o.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    o.email ?? ctx.t('Local device'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: o.email == null ? null : TextDirection.ltr,
                  ),
                  trailing: o.id == orgs.current.id ? const Tag('Open now') : null,
                  onTap: o.id == orgs.current.id
                      ? null
                      : () => Navigator.pop(ctx, o.id),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.t('Close')),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, _add),
          icon: const Icon(Icons.add, size: 18),
          label: Text(ctx.t('New organization')),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice != _add) {
    await perform(context, () => orgs.switchTo(choice));
    return;
  }
  final name = await askText(
    context,
    'New organization',
    label: 'Organization name',
    keyboard: TextInputType.name,
  );
  if (name == null || !context.mounted) return;
  await perform(context, () => orgs.create(name));
}

/// Asks before a backup made in one organization is restored into another.
Future<bool> confirmOtherBackup(
  BuildContext context, {
  required String from,
  required String into,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Restore backup')),
        content: SizedBox(
          width: 420,
          child: Text(
            ctx
                .t('This backup belongs to “{from}”. Restore it into “{into}”?')
                .replaceAll('{from}', from)
                .replaceAll('{into}', into),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.t('Restore')),
          ),
        ],
      ),
    ) ??
    false;
