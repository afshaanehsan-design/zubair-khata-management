import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../core/l10n.dart';
import '../core/organizations.dart';
import '../features/ledger/entry_facts.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'entry_composer.dart';
import 'export_ui.dart';
import 'masters.dart';
import 'organizations_ui.dart';
import 'pages.dart' show showHistory;

class SettingsPage extends StatefulWidget {
  final AppController app;
  const SettingsPage(this.app, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final url = TextEditingController(),
      key = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController(),
      code = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    for (final c in [url, key, email, password, code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> action(Future<void> Function() fn, {String? success}) async {
    if (busy) return;
    setState(() => busy = true);
    await perform(context, fn, success: success);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading('Settings', 'Business, in balance.'),
        if (app.lastError != null) Notice(app.lastError!),
        LayoutBuilder(
          builder: (ctx, box) {
            final orgs = app.organizations;
            final left = Column(
              children: [
                if (orgs != null) ...[
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionHeader(
                          'Organization',
                          action: Tag('${orgs.list.length}'),
                        ),
                        Text(
                          ctx.t(
                            'Each organization is a separate khata on this device. Online, each one signs in with its own email.',
                          ),
                          style: const TextStyle(color: muted),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => showOrganizations(context, app),
                              icon: const Icon(
                                Icons.business_outlined,
                                size: 18,
                              ),
                              label: Text(ctx.t('Switch or add organization')),
                            ),
                            // The last organization stays: the app needs one.
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: danger,
                                side: const BorderSide(color: danger),
                              ),
                              onPressed: busy || orgs.list.length < 2
                                  ? null
                                  : () async {
                                      if (!await confirmRemoveOrganization(
                                        ctx,
                                        app,
                                      )) {
                                        return;
                                      }
                                      final gone = orgs.current.id;
                                      await action(() async {
                                        await orgs.removeCurrent();
                                        await clearExportCopies(gone);
                                      });
                                    },
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                              ),
                              label: Text(ctx.t('Remove from this device')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Business profile'),
                      Text(
                        app.businessName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${app.settings['address'] ?? ''}\n${app.settings['phone'] ?? ''}',
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () => editProfile(context, app),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: Text(ctx.t('Edit')),
                      ),
                      const Divider(height: 32),
                      const SectionHeader('Language'),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'en',
                            label: Text(ctx.t('English')),
                          ),
                          ButtonSegment(
                            value: 'ur',
                            label: Text(ctx.t('Urdu')),
                          ),
                        ],
                        selected: {app.language},
                        onSelectionChanged: (v) => app.setLanguage(v.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Backup & restore'),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => action(
                                    () => exportBackup(ctx, app),
                                    success: 'Backup saved',
                                  ),
                            icon: const Icon(Icons.download_outlined, size: 18),
                            label: Text(ctx.t('Export backup')),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => action(() async {
                                    final selected = await openFile(
                                      acceptedTypeGroups: [
                                        const XTypeGroup(
                                          label: 'Khata backup',
                                          extensions: ['json'],
                                        ),
                                      ],
                                    );
                                    if (selected == null) return;
                                    final parsed = decodeObject(
                                      await selected.readAsString(),
                                    );
                                    if (!ctx.mounted) return;
                                    // A local restore replaces everything, so
                                    // say whose backup this is first.
                                    final from =
                                        AppController.backupBusinessName(
                                          parsed,
                                        );
                                    if (from != null &&
                                        AppController.nameKey(from) !=
                                            AppController.nameKey(
                                              app.businessName,
                                            ) &&
                                        !await confirmOtherBackup(
                                          ctx,
                                          from: from,
                                          into: app.businessName,
                                        )) {
                                      return;
                                    }
                                    if (!ctx.mounted) return;
                                    final reason = await askText(
                                      ctx,
                                      'Restore backup',
                                    );
                                    if (reason == null) return;
                                    await app.restoreBackup(parsed);
                                  }, success: 'Restore completed'),
                            icon: const Icon(Icons.restore, size: 18),
                            label: Text(ctx.t('Restore backup')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Archived'),
                      for (final record in app.records.where(
                        (r) =>
                            r.archived &&
                            !r.deleted &&
                            ['party', 'account'].contains(r.kind),
                      ))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(record.name),
                          trailing: TextButton(
                            onPressed: () => perform(
                              ctx,
                              () => app.saveMaster(record.kind, {
                                ...record.data,
                                'archived': false,
                              }, existing: record),
                            ),
                            child: Text(ctx.t('Unarchive')),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
            final right = Column(
              children: [
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Cloud connection'),
                      Row(
                        children: [
                          Icon(
                            app.signedIn
                                ? Icons.cloud_done_outlined
                                : Icons.cloud_off_outlined,
                            color: teal,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              ctx.t(app.syncMessage),
                              style: const TextStyle(color: muted),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (!app.cloudConfigured) ...[
                        TextField(
                          controller: url,
                          textDirection: TextDirection.ltr,
                          decoration: InputDecoration(
                            labelText: ctx.t('Project URL'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: key,
                          textDirection: TextDirection.ltr,
                          decoration: InputDecoration(
                            labelText: ctx.t('Publishable key'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () => action(
                                  () => app.configureCloud(url.text, key.text),
                                  success: 'Saved',
                                ),
                          child: Text(ctx.t('Connect')),
                        ),
                      ] else ...[
                        if (!app.signedIn) ...[
                          TextField(
                            controller: email,
                            textDirection: TextDirection.ltr,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: ctx.t('Email'),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: password,
                            textDirection: TextDirection.ltr,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: ctx.t('Password'),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => action(
                                        () => app.signIn(
                                          email.text,
                                          password.text,
                                        ),
                                      ),
                                child: Text(ctx.t('Sign in')),
                              ),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => action(
                                        () => app.register(
                                          email.text,
                                          password.text,
                                        ),
                                        success: 'Check your email to confirm your account.',
                                      ),
                                child: Text(ctx.t('Create owner account')),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => action(
                                        () => app.client!.auth
                                            .resetPasswordForEmail(
                                              email.text.trim(),
                                              redirectTo: 'com.zubairtraders.khata://auth',
                                            ),
                                        success: 'Password reset email sent.',
                                      ),
                                child: Text(ctx.t('Reset password')),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: code,
                            textDirection: TextDirection.ltr,
                            decoration: InputDecoration(
                              labelText: ctx.t('Recovery code'),
                            ),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => action(() async {
                                    await app.client!.auth.verifyOTP(
                                      type: OtpType.recovery,
                                      email: email.text.trim(),
                                      token: code.text.trim(),
                                    );
                                    await app.client!.auth.updateUser(
                                      UserAttributes(password: password.text),
                                    );
                                  }, success: 'Saved'),
                            child: Text(ctx.t('Update password')),
                          ),
                        ] else ...[
                          Text(
                            app.client!.auth.currentUser?.email ?? '',
                            textDirection: TextDirection.ltr,
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => action(app.syncNow),
                                icon: const Icon(Icons.sync, size: 18),
                                label: Text(ctx.t('Sync now')),
                              ),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => action(app.signOut),
                                child: Text(ctx.t('Sign out')),
                              ),
                              TextButton(
                                onPressed: () async {
                                  final next = await askText(ctx, 'Password');
                                  if (next != null) {
                                    await action(() async {
                                      await app.client!.auth.updateUser(
                                        UserAttributes(password: next),
                                      );
                                    }, success: 'Saved');
                                  }
                                },
                                child: Text(ctx.t('Update password')),
                              ),
                            ],
                          ),
                        ],
                      ],
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: LinearProgressIndicator(),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        'Sync & recovery',
                        action: Tag('${app.pendingCount} ${ctx.t('Pending')}'),
                      ),
                      if (app.sync?.message.contains('Cloud recovery') == true)
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () =>
                                    action(app.recoverCloud, success: 'Saved'),
                          icon: const Icon(Icons.cloud_sync_outlined),
                          label: Text(ctx.t('Reconnect to cloud')),
                        ),
                      if (app.conflictCount == 0)
                        Text(
                          ctx.t('Nothing to review'),
                          style: const TextStyle(color: muted),
                        ),
                      for (final c in app.commands.where(
                        (c) => [
                          'conflict',
                          'rejected',
                          'quarantined',
                        ].contains(c.status),
                      ))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.info_outline, color: amber),
                          title: Text(
                            '${c.action} · ${ctx.t(c.status == 'conflict' ? 'Conflict' : 'Rejected')}',
                          ),
                          subtitle: Text(c.error ?? ''),
                          trailing: TextButton(
                            onPressed: () => reviewCommand(ctx, app, c),
                            child: Text(ctx.t('Review changes')),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader('Reset all data'),
                      Text(
                        ctx.t(
                          'Erase every party, account, entry and closed day, and start again with an empty khata.',
                        ),
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: danger,
                          side: const BorderSide(color: danger),
                        ),
                        onPressed: busy
                            ? null
                            : () async {
                                if (!await confirmReset(ctx, app)) return;
                                await action(() async {
                                  await app.resetAll();
                                  await clearExportCopies(
                                    app.organization?.id ?? Organization.main,
                                  );
                                }, success: 'All data erased');
                              },
                        icon: const Icon(
                          Icons.delete_forever_outlined,
                          size: 18,
                        ),
                        label: Text(ctx.t('Reset all data')),
                      ),
                    ],
                  ),
                ),
              ],
            );
            return box.maxWidth > 950
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: left),
                      const SizedBox(width: 20),
                      Expanded(child: right),
                    ],
                  )
                : Column(children: [left, const SizedBox(height: 20), right]);
          },
        ),
      ],
    );
  }
}

Future<void> exportBackup(BuildContext context, AppController app) async {
  final backup = await app.backup();
  // The business name is in the file name, so the backups of two
  // organizations made on the same day are told apart.
  final name = app.businessName.trim().replaceAll(
    RegExp(r'[\\/:*?"<>|\s]+'),
    '_',
  );
  if (context.mounted) {
    await saveBytes(
      context,
      utf8.encode(jsonEncode(backup)),
      'ZubairKhata_${name.isEmpty ? '' : '${name}_'}Backup_${businessDate()}',
      'json',
    );
  }
}

/// Asks before [Organizations.removeCurrent]: says what is deleted, offers a
/// backup and only enables the button once the organization's name is typed.
Future<bool> confirmRemoveOrganization(
  BuildContext context,
  AppController app,
) async {
  final typed = TextEditingController();
  final name = app.businessName;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Remove organization?')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                ctx.t(
                  'This permanently deletes this organization from this device: every party, account, entry, closed day, saved day, pending change and draft.',
                ),
              ),
              const SizedBox(height: 10),
              if (app.owner == null)
                Text(
                  ctx.t(
                    'This organization is only on this device. Without a backup it cannot be recovered.',
                  ),
                )
              else ...[
                Text(ctx.t('The cloud copy is not erased.')),
                if (app.pendingCount > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    ctx
                        .t(
                          '{count} changes have not reached the cloud and will be lost.',
                        )
                        .replaceAll('{count}', '${app.pendingCount}'),
                    style: const TextStyle(
                      color: danger,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 10),
              Text(
                ctx.t(
                  'This cannot be undone. Export a backup first if you might need this data.',
                ),
                style: const TextStyle(
                  color: danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => perform(
                  ctx,
                  () => exportBackup(ctx, app),
                  success: 'Backup saved',
                ),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(ctx.t('Export backup')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: typed,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: ctx.t('Type the organization name to confirm'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.t('Cancel')),
        ),
        ValueListenableBuilder(
          valueListenable: typed,
          builder: (ctx, value, _) => FilledButton(
            style: FilledButton.styleFrom(backgroundColor: danger),
            onPressed:
                AppController.nameKey(value.text) == AppController.nameKey(name)
                ? () => Navigator.pop(ctx, true)
                : null,
            child: Text(ctx.t('Remove organization')),
          ),
        ),
      ],
    ),
  );
  // Dialog route animations can still reference its controller for one frame.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  typed.dispose();
  return confirmed ?? false;
}

/// Asks before [AppController.resetAll]: says what is erased, offers a backup
/// and only enables the button once RESET is typed.
Future<bool> confirmReset(BuildContext context, AppController app) async {
  final typed = TextEditingController();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Reset all data?')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ctx.t(
                  'This permanently erases every party, account, entry, closed day, saved day, pending change and draft on this device.',
                ),
              ),
              if (app.owner != null) ...[
                const SizedBox(height: 10),
                Text(
                  ctx.t(
                    'The cloud copy is erased too. On other devices, use Reconnect to cloud afterwards.',
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                // An organization also keeps its name (see `_seedDefaults`).
                app.organization == null
                    ? ctx.t(
                        'Language, the cloud connection and your sign-in are kept.',
                      )
                    : ctx.t(
                        'The organization name, language, the cloud connection and your sign-in are kept.',
                      ),
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 10),
              Text(
                ctx.t(
                  'This cannot be undone. Export a backup first if you might need this data.',
                ),
                style: const TextStyle(
                  color: danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => perform(
                  ctx,
                  () => exportBackup(ctx, app),
                  success: 'Backup saved',
                ),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(ctx.t('Export backup')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: typed,
                autofocus: true,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: ctx.t('Type RESET to confirm'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.t('Cancel')),
        ),
        ValueListenableBuilder(
          valueListenable: typed,
          builder: (ctx, value, _) => FilledButton(
            style: FilledButton.styleFrom(backgroundColor: danger),
            onPressed: value.text.trim().toUpperCase() == 'RESET'
                ? () => Navigator.pop(ctx, true)
                : null,
            child: Text(ctx.t('Erase everything')),
          ),
        ),
      ],
    ),
  );
  // Dialog route animations can still reference its controller for one frame.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  typed.dispose();
  return confirmed ?? false;
}

Future<void> editProfile(
  BuildContext context,
  AppController app, {
  Json? proposed,
  Future<void> Function()? onSaved,
}) async {
  final original = app.record('business')!;
  final initial = proposed ?? app.settings;
  final fields = {
    for (final name in ['name', 'phone', 'address', 'defaultRate'])
      name: TextEditingController(
        text: name == 'defaultRate'
            ? decimalText(integer(initial[name]), 2)
            : '${initial[name] ?? ''}',
      ),
  };
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Business profile')),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextField(
                    controller: field.value,
                    textDirection:
                        field.key == 'defaultRate' || field.key == 'phone'
                        ? TextDirection.ltr
                        : null,
                    decoration: InputDecoration(
                      labelText: ctx.t(
                        {
                          'name': 'Business name',
                          'phone': 'Phone',
                          'address': 'Address',
                          'defaultRate': 'Default rate',
                        }[field.key]!,
                      ),
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
          child: Text(ctx.t('Cancel')),
        ),
        FilledButton(
          onPressed: () async {
            final ok = await perform(ctx, () async {
              await app.commit([
                Change('business', 'settings', {
                  'name': fields['name']!.text.trim(),
                  'phone': fields['phone']!.text.trim(),
                  'address': fields['address']!.text.trim(),
                  'defaultRate': decimal(fields['defaultRate']!.text, 2),
                }, original.version),
              ]);
            });
            if (ok) await onSaved?.call();
            if (ok && ctx.mounted) Navigator.pop(ctx);
          },
          child: Text(ctx.t('Save')),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final c in fields.values) {
    c.dispose();
  }
}

Future<void> reviewCommand(
  BuildContext context,
  AppController app,
  Command command,
) async {
  Widget proposal(BuildContext ctx, Change change) {
    final current = app.record(change.id);
    final label = change.kind == 'document'
        ? entryLabel('${change.data['type']}')
        : '${change.data['name'] ?? ''}';
    final amount = change.kind == 'document'
        ? Document(Record(change.id, change.kind, change.data)).total
        : 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ctx.t(label),
              style: const TextStyle(fontWeight: FontWeight.w700, color: ink),
            ),
            const SizedBox(height: 10),
            if (current != null)
              Text(
                '${ctx.t('Current')}: ${current.kind == 'document' ? '${ctx.t(current.data['voided'] == true ? 'Voided' : entryLabel('${current.data['type']}'))} · Rs ${money(Document(current).total)}' : current.name}',
                style: const TextStyle(color: muted),
              ),
            if (current != null && current.kind == 'document')
              Text(
                entryHeadline(app, Document(current), ctx.words),
                style: const TextStyle(color: muted),
              ),
            if (change.kind == 'document') ...[
              Text(
                '${ctx.t('Proposed')}: ${ctx.t(change.data['voided'] == true ? 'Voided' : entryLabel('${change.data['type']}'))} · ${change.data['date']}',
              ),
              const SizedBox(height: 6),
              Amount(amount),
              if ('${change.data['party'] ?? ''}'.isNotEmpty)
                Text(app.name('${change.data['party']}')),
              Text(
                entryHeadline(
                  app,
                  Document(Record(change.id, change.kind, change.data)),
                  ctx.words,
                ),
              ),
              if (integer(change.data['cash']) != 0)
                Text(
                  '${ctx.t('Cash received')}: Rs ${money(integer(change.data['cash']))}',
                ),
              if (integer(change.data['bank']) != 0)
                Text(
                  '${ctx.t('Bank received')}: Rs ${money(integer(change.data['bank']))}',
                ),
              if ('${change.data['note'] ?? ''}'.isNotEmpty)
                Text('${change.data['note']}'),
            ] else ...[
              Text('${ctx.t('Proposed')}: ${change.data['name'] ?? ''}'),
              if ('${change.data['phone'] ?? ''}'.isNotEmpty)
                Text('${change.data['phone']}'),
            ],
          ],
        ),
      ),
    );
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Review changes')),
      content: SizedBox(
        width: 660,
        height: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ctx.t(command.error ?? ''),
                style: const TextStyle(color: amber),
              ),
              const SizedBox(height: 16),
              for (final change in command.changes) proposal(ctx, change),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await app.dismissConflict(command);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: Text(ctx.t('Use synced version')),
        ),
        if (!['close', 'reopen'].contains(command.action))
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!context.mounted) return;
              Future<void> resolved() => app.dismissConflict(command);
              final masters = command.changes
                  .where((c) => ['party', 'account'].contains(c.kind))
                  .toList();
              if (masters.isNotEmpty) {
                final c = masters.first;
                final openings = command.changes.where(
                  (d) => d.kind == 'document' && d.data['type'] == 'adjustment',
                );
                await editMaster(
                  context,
                  app,
                  c.kind,
                  existing: app.record(c.id),
                  proposed: c.data,
                  newId: c.id,
                  openingValue: openings
                      .where(
                        (d) =>
                            d.data['target'] == 'ar:${c.id}' ||
                            d.data['target'] == 'money:${c.id}',
                      )
                      .fold(0, (v, d) => v + integer(d.data['amount'])),
                  payableValue: -openings
                      .where((d) => d.data['target'] == 'ap:${c.id}')
                      .fold(0, (v, d) => v + integer(d.data['amount'])),
                  openingDate: openings.firstOrNull?.data['date'] as String?,
                  onSaved: resolved,
                );
                return;
              }
              if (command.changes.length == 1 &&
                  command.changes.first.kind == 'settings') {
                await editProfile(
                  context,
                  app,
                  proposed: command.changes.first.data,
                  onSaved: resolved,
                );
                return;
              }
              final candidates = command.changes
                  .where(
                    (c) => c.kind == 'document' && c.data['voided'] != true,
                  )
                  .toList();
              if (command.action == 'restore') {
                await showHistory(
                  context,
                  app,
                  filterDate: candidates.firstOrNull?.data['date'] as String?,
                  onRestored: resolved,
                );
                return;
              }
              if (candidates.length > 1) {
                if (candidates.every((c) => c.data['type'] == 'sale')) {
                  final rate = await askText(
                    context,
                    'Daily rate update',
                    initial: decimalText(
                      integer(candidates.first.data['rate']),
                      2,
                    ),
                    keyboard: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  );
                  if (rate == null || !context.mounted) return;
                  final reason = await askText(
                    context,
                    'Reason for correction',
                  );
                  if (reason != null && context.mounted) {
                    await perform(context, () async {
                      app.setDate('${candidates.first.data['date']}');
                      await app.applyDailyRate(decimal(rate, 2), reason);
                      await resolved();
                    }, success: 'Saved');
                  }
                }
                return;
              }
              if (candidates.isNotEmpty) {
                Document? replace;
                if (command.action == 'correct') {
                  final old = command.changes
                      .where(
                        (c) => c.kind == 'document' && c.data['voided'] == true,
                      )
                      .firstOrNull;
                  var current = old == null ? null : app.record(old.id);
                  if (current?.data['voided'] == true &&
                      current?.data['replacement'] != null) {
                    current = app.record('${current!.data['replacement']}');
                  }
                  if (current != null && current.data['voided'] != true) {
                    replace = Document(current);
                  }
                }
                await composeEntry(
                  context,
                  app,
                  replace: replace,
                  prefill: candidates.single.data,
                  onSaved: resolved,
                );
                return;
              }
              if (command.action == 'void') {
                final current = app.record(command.changes.first.id);
                if (current == null || current.data['voided'] == true) {
                  await resolved();
                  return;
                }
                final reason = await askText(
                  context,
                  'Reason for correction',
                  initial: command.reason,
                );
                if (reason != null && context.mounted) {
                  await perform(context, () async {
                    await app.voidDocument(Document(current), reason);
                    await resolved();
                  }, success: 'Saved');
                }
              }
            },
            child: Text(ctx.t('Review my change')),
          ),
      ],
    ),
  );
}
