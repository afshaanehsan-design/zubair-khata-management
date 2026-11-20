import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/l10n.dart';
import '../core/models.dart';

import '../features/ledger/book.dart';
import '../features/ledger/entry_facts.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'details.dart';
import 'entry_composer.dart';
import 'export_ui.dart';
import 'masters.dart';
import 'profit_ui.dart';
import 'roznamcha_form.dart';
import 'roznamcha_widgets.dart' show confirmPlain;

class ActivityPage extends StatefulWidget {
  final AppController app;
  const ActivityPage(this.app, {super.key});
  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  String type = 'All', from = '', to = '', party = '', account = '';
  bool voided = false;
  int limit = 100;
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final docs =
        app
            .ofKind('document')
            .map(Document.new)
            .where(
              (d) =>
                  (voided || !d.voided) &&
                  (type == 'All' || d.type.name == type) &&
                  (from.isEmpty || d.date.compareTo(from) >= 0) &&
                  (to.isEmpty || d.date.compareTo(to) <= 0) &&
                  (party.isEmpty ||
                      d.party == party ||
                      d.directParties.contains(party)) &&
                  (account.isEmpty ||
                      d.account == account ||
                      d.bankAccount == account ||
                      d.bankLines.any(
                        (l) => !l.direct && l.account == account,
                      ) ||
                      d.data['toAccount'] == account) &&
                  '${app.name(d.party)} ${d.directParties.map(app.name).join(' ')} ${d.reference} ${d.note} ${d.date}'
                      .toLowerCase()
                      .contains(app.search.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => b.date.compareTo(a.date) != 0
                ? b.date.compareTo(a.date)
                : integer(b.data['occurredAt'])
                      .compareTo(integer(a.data['occurredAt'])),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          'Activity',
          'Documents',
          actions: [
            TextButton.icon(
              onPressed: () => showHistory(context, app),
              icon: const Icon(Icons.history),
              label: Text(context.t('Day history')),
            ),
          ],
        ),
        Wrap(
          spacing: 10,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: type,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.t('Activity')),
                items: [
                  DropdownMenuItem(value: 'All', child: Text(context.t('All'))),
                  for (final v in EntryType.values)
                    DropdownMenuItem(
                      value: v.name,
                      child: Text(context.t(entryLabel(v.name))),
                    ),
                ],
                onChanged: (v) => setState(() => type = v!),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final v = await pickDate(
                  context,
                  from.isEmpty ? app.selectedDate : from,
                );
                if (v != null) setState(() => from = v);
              },
              icon: const Icon(Icons.date_range, size: 18),
              label: Text(from.isEmpty ? context.t('From date') : from),
            ),
            OutlinedButton(
              onPressed: () async {
                final v = await pickDate(
                  context,
                  to.isEmpty ? app.selectedDate : to,
                );
                if (v != null) setState(() => to = v);
              },
              child: Text(to.isEmpty ? context.t('To date') : to),
            ),
            FilterChip(
              label: Text(party.isEmpty ? context.t('Party') : app.name(party)),
              selected: party.isNotEmpty,
              onSelected: (_) async {
                if (party.isNotEmpty) {
                  setState(() => party = '');
                } else {
                  final v = await pickRecord(context, app, 'party');
                  if (v != null) setState(() => party = v);
                }
              },
            ),
            FilterChip(
              label: Text(
                account.isEmpty ? context.t('Money') : app.name(account),
              ),
              selected: account.isNotEmpty,
              onSelected: (_) async {
                if (account.isNotEmpty) {
                  setState(() => account = '');
                } else {
                  final v = await pickRecord(context, app, 'account');
                  if (v != null) setState(() => account = v);
                }
              },
            ),
            FilterChip(
              label: Text(context.t('Voided')),
              selected: voided,
              onSelected: (v) => setState(() => voided = v),
            ),
            if (from.isNotEmpty || to.isNotEmpty)
              IconButton(
                onPressed: () => setState(() {
                  from = '';
                  to = '';
                }),
                icon: const Icon(Icons.filter_alt_off_outlined),
              ),
          ],
        ),
        const SizedBox(height: 22),
        Panel(
          child: docs.isEmpty
              ? const EmptyState('No results', 'Your entries will appear here.')
              : Column(
                  children: [
                    for (final d in docs.take(limit)) TransactionTile(app, d),
                    if (docs.length > limit)
                      TextButton(
                        onPressed: () => setState(() => limit += 100),
                        child: Text(context.t('More')),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The Parties page's filter chips after All, in the order shown: what kind
/// of party it is, then which way its balance points.
const partyKindFilters = ['Customers', 'Companies', 'Udhari'];
const partyBalanceFilters = ['You will receive', 'You will pay'];
const partyFilters = [...partyKindFilters, ...partyBalanceFilters];

/// The parties the Parties page lists for the chosen filter chips and the
/// Archived switch, matching the top-bar search by name or phone. Several
/// chips can be on at once: a party is listed when it is any of the chosen
/// kinds and its balance is any of the chosen sides, so Customers with
/// Companies lists both, and Customers with You will receive the customers
/// who owe you. No chip (or only All) lists everyone. Records keep the order
/// they were first saved in (KhataDatabase), so the reversed list is newest
/// first. The pending balances PDF prints this same list.
List<Record> visibleParties(
  AppController app,
  Set<String> filters,
  bool archived,
) {
  final b = app.book, search = app.search.toLowerCase();
  final kinds = partyKindFilters.where(filters.contains).toList();
  final sides = partyBalanceFilters.where(filters.contains).toList();
  bool isKind(Record p, String kind) => switch (kind) {
    'Customers' => p.data['customer'] == true,
    'Companies' => p.data['supplier'] == true,
    _ => p.data['udhari'] == true,
  };
  bool onSide(Record p) {
    final owed = partyOwed(b, p.id);
    return sides.any(
      (side) => side == 'You will receive' ? owed.receive > 0 : owed.pay > 0,
    );
  }

  return app
      .ofKind('party', archived: archived)
      .where(
        (p) =>
            '${p.name} ${p.data['phone'] ?? ''}'.toLowerCase().contains(
              search,
            ) &&
            (kinds.isEmpty || kinds.any((kind) => isKind(p, kind))) &&
            (sides.isEmpty || onSide(p)),
      )
      .toList()
      .reversed
      .toList();
}

/// Parties, newest first. On a wide screen the left column (heading, filters
/// and list) and the chosen party's full-height details on the right each
/// scroll on their own; on a narrower screen the whole page scrolls and a tap
/// opens the details in a dialog. The page scrolls itself: the Workspace gives
/// it the full height instead of a scroll view.
class PartiesPage extends StatefulWidget {
  final AppController app;
  const PartiesPage(this.app, {super.key});

  /// From this width the list and the details sit side by side.
  static const splitWidth = 840.0;

  /// The party list beside the details (for tests).
  static const listKey = Key('parties-list-rows');

  /// The listed parties' totals beside the heading (for tests).
  static const totalsKey = Key('parties-totals');
  @override
  State<PartiesPage> createState() => _PartiesPageState();
}

class _PartiesPageState extends State<PartiesPage> {
  /// The filter chips that are on; none means All. A tap turns a chip on or
  /// off without touching the others; All turns them all off.
  final filters = <String>{};
  bool archived = false;

  /// The party shown beside the list. Until one is picked (or when it is
  /// filtered out, archived or deleted) the newest party is shown.
  String? selected;

  /// The Pending balances button's two sheets, in a menu under [button]:
  /// every pending balance, or only those the top bar's day changed. Under
  /// them, Arrange: exactly one of A to Z (the default), Biggest balance
  /// first and Newest first is ticked ([AppController.pendingOrder]);
  /// choosing another ticks it and opens the menu again.
  Future<void> _pendingMenu(BuildContext button, List<Record> list) async {
    final app = widget.app, day = app.selectedDate;
    final box = button.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(button).context.findRenderObject()! as RenderBox;
    while (true) {
      if (!mounted || !button.mounted) return;
      final choice = await showMenu<String>(
        context: button,
        position: RelativeRect.fromRect(
          Rect.fromPoints(
            box.localToGlobal(
              box.size.bottomLeft(const Offset(0, 4)),
              ancestor: overlay,
            ),
            box.localToGlobal(
              box.size.bottomRight(const Offset(0, 4)),
              ancestor: overlay,
            ),
          ),
          Offset.zero & overlay.size,
        ),
        items: [
          PopupMenuItem(
            key: const ValueKey('parties-pending-all'),
            value: 'all',
            child: Text('${context.t('All pending balances')} · $day'),
          ),
          PopupMenuItem(
            key: const ValueKey('parties-pending-day'),
            value: 'day',
            child: Text('${context.t('Changed on this day only')} · $day'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            enabled: false,
            height: 32,
            child: Text(
              context.t('Arrange'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          for (final order in PendingOrder.values)
            CheckedPopupMenuItem(
              key: ValueKey('parties-pending-order-${order.name}'),
              value: 'order:${order.name}',
              checked: app.pendingOrder == order,
              child: Text(context.t(order.label)),
            ),
        ],
      );
      if (choice == null || !mounted) return;
      if (choice.startsWith('order:')) {
        app.pendingOrder = PendingOrder.values.byName(choice.substring(6));
        continue;
      }
      await _pending(list, day: choice == 'day' ? day : null);
      return;
    }
  }

  /// Pending balances of exactly the parties the list shows, at the end of
  /// the top bar's date: all of them (shading those whose balance changed on
  /// it), or with [day] (that date) only those.
  Future<void> _pending(List<Record> list, {String? day}) async {
    final app = widget.app;
    final report = pendingReport(
      app,
      list,
      filters: partyFilters.where(filters.contains),
      archived: archived,
      search: app.search,
      urdu: app.urdu,
      day: day,
      asOf: day == null ? app.selectedDate : null,
      order: app.pendingOrder,
    );
    if (report.rows.isEmpty) {
      showMessage(
        context,
        context.t(
          day == null
              ? 'No pending balances'
              : 'No pending balance changed on this day',
        ),
      );
      return;
    }
    await previewReport(context, report);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app, b = app.book;
    final list = visibleParties(app, filters, archived);
    final header = [
      PageHeading(
        'Parties',
        'Newest first',
        count: list.length,
        beside: _totals(list, b),
        actions: [
          // The complete sheet, or only the day's changes.
          Builder(
            builder: (button) => OutlinedButton.icon(
              key: const ValueKey('parties-pending'),
              onPressed: () => _pendingMenu(button, list),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(context.t('Pending balances')),
            ),
          ),
          FilledButton.icon(
            onPressed: () => editMaster(context, app, 'party'),
            icon: const Icon(Icons.add),
            label: Text(context.t('Add party')),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilterChip(
            label: Text(context.t('All')),
            selected: filters.isEmpty,
            onSelected: (_) => setState(filters.clear),
          ),
          for (final value in partyFilters)
            FilterChip(
              label: Text(context.t(value)),
              selected: filters.contains(value),
              onSelected: (on) => setState(
                () => on ? filters.add(value) : filters.remove(value),
              ),
            ),
          FilterChip(
            label: Text(context.t('Archived')),
            selected: archived,
            onSelected: (v) => setState(() => archived = v),
          ),
        ],
      ),
      const SizedBox(height: 18),
    ];
    final empty = Panel(
      child: EmptyState(
        'No results',
        'Add parties, accounts and stock to begin.',
        action: FilledButton(
          onPressed: () => editMaster(context, app, 'party'),
          child: Text(context.t('Add party')),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < PartiesPage.splitWidth) {
          return SingleChildScrollView(
            // Room for the floating "New entry" button.
            padding: const EdgeInsets.only(bottom: 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...header,
                if (list.isEmpty)
                  empty
                else
                  Panel(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        for (final p in list)
                          _partyRow(
                            p,
                            b,
                            onTap: () => showParty(context, app, p),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }
        final current =
            list.where((p) => p.id == selected).firstOrNull ?? list.firstOrNull;
        if (current == null) {
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [...header, empty],
            ),
          );
        }
        // The left column holds everything for finding a party (heading,
        // Add party, filters and the list) and scrolls as one, so the heading
        // scrolls away with the list. The chosen party's details take the
        // whole height on the right and scroll on their own.
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: (box.maxWidth * .34).clamp(330.0, 420.0),
                child: SingleChildScrollView(
                  key: const PageStorageKey('parties-list'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...header,
                      Panel(
                        padding: const EdgeInsets.all(6),
                        child: Column(
                          key: PartiesPage.listKey,
                          children: [
                            for (final p in list)
                              _partyRow(
                                p,
                                b,
                                selected: p.id == current.id,
                                onTap: () => setState(() => selected = p.id),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Panel(
                  padding: EdgeInsets.zero,
                  // A new key per party starts its details at the top.
                  child: PartyDetails(app, current, key: ValueKey(current.id)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// An amount over what it is, on the far side: a party's in its row, the
  /// listed parties' in the heading.
  Widget _amount(int value, String label, Color color, {double size = 14}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Rs ${money(value)}',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontSize: size,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          Text(
            context.t(label),
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 10.5, color: muted),
          ),
        ],
      );

  /// What the listed parties owe you and what you owe them in all: the sums
  /// of the rows' own figures, so they follow the filter and the search.
  Widget _totals(List<Record> list, Book b) {
    var receive = 0, pay = 0;
    for (final p in list) {
      final owed = partyOwed(b, p.id);
      receive += owed.receive;
      pay += owed.pay;
    }
    return ConstrainedBox(
      key: PartiesPage.totalsKey,
      constraints: const BoxConstraints(maxWidth: 170),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _amount(receive, 'You will receive', ink, size: 16),
          const SizedBox(height: 4),
          _amount(pay, 'You will pay', danger, size: 16),
        ],
      ),
    );
  }

  /// One party in the list: name, phone and kind, and on the far side what
  /// it owes you and what you owe it (or "Settled").
  Widget _partyRow(
    Record p,
    Book b, {
    bool selected = false,
    required VoidCallback onTap,
  }) {
    final (:receive, :pay) = partyOwed(b, p.id);
    final phone = '${p.data['phone'] ?? ''}'.trim();
    final about = [
      if (phone.isNotEmpty) phone,
      if (p.data['customer'] == true) context.t('Customer'),
      if (p.data['supplier'] == true) context.t('Supplier'),
      if (p.data['udhari'] == true) context.t('Udhari'),
      if (p.archived) context.t('Archived'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? const Color(0xffe6f0eb) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: selected
                      ? Colors.white
                      : const Color(0xffe9efe4),
                  child: Text(
                    p.name.isEmpty ? '?' : p.name.characters.first,
                    style: const TextStyle(color: teal),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: ink,
                        ),
                      ),
                      if (about.isNotEmpty)
                        Text(
                          about.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: muted),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (receive == 0 && pay == 0)
                        _amount(0, 'Settled', muted),
                      if (receive > 0)
                        _amount(receive, 'You will receive', ink),
                      if (receive > 0 && pay > 0) const SizedBox(height: 4),
                      if (pay > 0) _amount(pay, 'You will pay', danger),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cash and the bank accounts. Every number on this page is for the end of
/// the day chosen in the top bar, so the cards, the rows, the statement and
/// the reconciliation always agree.
class MoneyPage extends StatefulWidget {
  final AppController app;
  const MoneyPage(this.app, {super.key});
  @override
  State<MoneyPage> createState() => _MoneyPageState();
}

class _MoneyPageState extends State<MoneyPage> {
  bool showArchived = false;
  AppController get app => widget.app;

  /// Cash book / Bank book from the account's first entry up to the chosen
  /// day.
  Future<void> statement(Record a) {
    final ledger = app.book.ledger('money:${a.id}');
    final to = app.selectedDate;
    final first = ledger.isEmpty ? to : ledger.first.date;
    return previewReport(
      context,
      buildReport(
        app,
        a.id == 'cash' ? 'Cash book' : 'Bank book',
        first.compareTo(to) < 0 ? first : to,
        to,
        account: a.id,
        urdu: app.urdu,
      ),
    );
  }

  /// Cash, every bank, Total bank and Total at the end of the chosen day,
  /// printed like the Roznamcha.
  Future<void> moneyStatement() => previewReport(
    context,
    moneyReport(app, app.selectedDate, urdu: app.urdu),
  );

  Future<void> transfer() async {
    if (app.ofKind('account').where((a) => a.id != 'cash').length < 2) {
      showMessage(
        context,
        context.t('Add a second bank account to transfer between banks.'),
      );
      return;
    }
    await composeEntry(context, app, type: EntryType.transfer);
  }

  /// Only an empty account can be archived, so no money disappears from
  /// this page. It comes back with Restore in the Archived list.
  Future<void> archive(Record a) async {
    final balance = app.book.money(a.id);
    if (balance != 0) {
      showMessage(
        context,
        context
            .t(
              '{name} still has {amount}. Move the money to another account first; only an account with Rs 0 can be archived.',
            )
            .replaceAll('{name}', a.name)
            .replaceAll('{amount}', 'Rs ${money(balance)}'),
        error: true,
      );
      return;
    }
    final ok = await confirmPlain(
      context,
      context
          .t(
            'Archive {name}? It will be hidden from the Money page and the entry forms. You can restore it later from the Archived list.',
          )
          .replaceAll('{name}', a.name),
    );
    if (!ok || !mounted) return;
    await perform(
      context,
      () =>
          app.saveMaster('account', {...a.data, 'archived': true}, existing: a),
      success: 'Account archived',
    );
  }

  Future<void> restore(Record a) => perform(
    context,
    () =>
        app.saveMaster('account', {...a.data, 'archived': false}, existing: a),
    success: 'Account restored',
  );

  @override
  Widget build(BuildContext context) {
    final date = app.selectedDate;
    final today = date == businessDate();
    final b = app.bookAt(date);
    final accounts = app.ofKind('account');
    final banks = accounts.where((a) => a.id != 'cash').length;
    final archived = app
        .ofKind('account', archived: true)
        .where((a) => a.archived)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          'Money',
          'Cash book',
          actions: [
            OutlinedButton.icon(
              key: const ValueKey('money-statement'),
              onPressed: moneyStatement,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(context.t('Statement')),
            ),
            FilledButton.icon(
              onPressed: () => editMaster(context, app, 'account'),
              icon: const Icon(Icons.add),
              label: Text(context.t('Add account')),
            ),
          ],
        ),
        if (!today)
          Notice(
            context
                .t('These balances are for the end of {date}, not today.')
                .replaceAll('{date}', date),
            action: TextButton(
              onPressed: () => app.setDate(businessDate()),
              child: Text(context.t('Go to today')),
            ),
          ),
        MetricGrid([
          for (final a in accounts) ...[
            Metric(
              a.name,
              'Rs ${money(b.money(a.id))}',
              a.id == 'cash'
                  ? Icons.wallet_outlined
                  : Icons.account_balance_outlined,
              highlighted: a.id == 'cash',
              detail: a.data['bank'] as String?,
              onTap: () => statement(a),
            ),
            // All the banks together, right after Cash.
            if (a.id == 'cash')
              Metric(
                'Total bank',
                'Rs ${money(b.bankMoney)}',
                Icons.account_balance_wallet_outlined,
                key: const ValueKey('money-total-bank'),
                detail: context
                    .t('Banks: {count}')
                    .replaceAll('{count}', '$banks'),
                onTap: moneyStatement,
              ),
          ],
        ]),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            for (final tab in RozTab.values)
              OutlinedButton.icon(
                onPressed: () => openRoznamchaForm(context, app, tab: tab),
                icon: Icon(tab.icon, size: 18),
                label: Text(context.t(tab.label)),
              ),
            OutlinedButton.icon(
              onPressed: transfer,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(context.t('Bank se bank transfer')),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Panel(
          child: Column(
            children: [
              SectionHeader(
                'Account reconciliation',
                action: archived.isEmpty
                    ? null
                    : FilterChip(
                        label: Text(
                          '${context.t('Archived')} (${archived.length})',
                        ),
                        selected: showArchived,
                        onSelected: (v) => setState(() => showArchived = v),
                      ),
              ),
              for (final a in [...accounts, if (showArchived) ...archived])
                accountRow(a, b, date, today),
            ],
          ),
        ),
      ],
    );
  }

  Widget accountRow(Record a, Book b, String date, bool today) {
    final bank = '${a.data['bank'] ?? ''}'.trim();
    final change = today
        ? context.t('Change today')
        : context.t('Change on {date}').replaceAll('{date}', date);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      leading: const Icon(Icons.account_balance_outlined, color: teal),
      title: Row(
        children: [
          Flexible(
            child: Text(
              a.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (a.archived) ...[const SizedBox(width: 8), const Tag('Archived')],
        ],
      ),
      subtitle: Text(
        [
          if (bank.isNotEmpty) bank,
          '$change: ${signedRs(b.dayMovement(date, 'money:${a.id}'))}',
        ].join(' · '),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'ledger':
              await statement(a);
            case 'reconcile':
              await reconcile(context, app, a.id);
            case 'edit':
              await editMaster(context, app, 'account', existing: a);
            case 'archive':
              await archive(a);
            case 'restore':
              await restore(a);
          }
        },
        itemBuilder: (ctx) => [
          PopupMenuItem(value: 'ledger', child: Text(ctx.t('Statement'))),
          if (a.archived)
            PopupMenuItem(value: 'restore', child: Text(ctx.t('Restore')))
          else ...[
            PopupMenuItem(
              value: 'reconcile',
              child: Text(ctx.t('Account reconciliation')),
            ),
            PopupMenuItem(value: 'edit', child: Text(ctx.t('Edit'))),
            if (a.id != 'cash')
              PopupMenuItem(value: 'archive', child: Text(ctx.t('Archive'))),
          ],
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Amount(b.money(a.id)),
            const SizedBox(width: 12),
            const Icon(Icons.more_horiz),
          ],
        ),
      ),
    );
  }
}

/// Count the real money (the cash drawer, or the balance in the bank app)
/// and record the difference as a correction on the day chosen in the top
/// bar. Nothing is saved when the count matches or the reason is cancelled.
Future<void> reconcile(
  BuildContext context,
  AppController app,
  String account,
) async {
  final date = app.selectedDate;
  final counted = await askText(
    context,
    'Counted balance',
    initial: decimalText(app.bookAt(date).money(account), 2),
    keyboard: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
  );
  if (counted == null || !context.mounted) return;
  var delta = 0;
  final valid = await perform(context, () async {
    delta = decimal(counted, 2) - app.bookAt(date).money(account);
  });
  if (!valid || !context.mounted) return;
  if (delta == 0) {
    showMessage(context, context.t('Balance matches. Nothing to correct.'));
    return;
  }
  // The difference is shown, so a typing mistake is caught before saving.
  final reason = await askText(
    context,
    '${context.t('Reason for correction')} (${signedRs(delta)})',
  );
  if (reason == null || !context.mounted) return;
  await perform(
    context,
    () => app.post({
      'type': 'adjustment',
      'date': date,
      'target': 'money:$account',
      'amount': delta,
      'note': reason,
    }),
    success: 'Saved',
  );
}

class StockPage extends StatelessWidget {
  final AppController app;
  const StockPage(this.app, {super.key});
  @override
  Widget build(BuildContext context) {
    final b = app.book;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          'Stock',
          'Gas remaining',
          actions: [
            FilledButton.icon(
              onPressed: () =>
                  composeEntry(context, app, type: EntryType.purchase),
              icon: const Icon(Icons.add),
              label: Text(context.t('Purchase')),
            ),
          ],
        ),
        MetricGrid([
          Metric(
            'Gas remaining',
            '${kg(b.gasGrams)} KG',
            Icons.propane_tank_outlined,
            highlighted: true,
          ),
          Metric(
            'FIFO value',
            'Rs ${money(b.lots.fold(0, (v, l) => v + (l.cost ?? 0)))}',
            Icons.layers_outlined,
          ),
          Metric(
            'Unvalued quantity',
            '${kg(b.uncostedSales.values.fold(0, (a, b) => a + b))} KG',
            Icons.info_outline,
          ),
        ]),
        const SizedBox(height: 20),
        for (final warning in stockWarnings(app, b)) Notice(warning),
        if (b.documents.any(
          (d) =>
              d.type == EntryType.sale &&
              '${d.data['dueDate'] ?? ''}'.isNotEmpty &&
              '${d.data['dueDate']}'.compareTo(app.selectedDate) < 0 &&
              (b.invoiceDue[d.id] ?? 0) > 0,
        ))
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('Overdue'),
                for (final d
                    in b.documents
                        .where(
                          (d) =>
                              d.type == EntryType.sale &&
                              '${d.data['dueDate'] ?? ''}'.isNotEmpty &&
                              '${d.data['dueDate']}'.compareTo(
                                    app.selectedDate,
                                  ) <
                                  0 &&
                              (b.invoiceDue[d.id] ?? 0) > 0,
                        )
                        .take(5))
                  TransactionTile(app, d),
              ],
            ),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: () =>
                  composeEntry(context, app, type: EntryType.stockAdjustment),
              icon: const Icon(Icons.tune),
              label: Text(context.t('Stock adjustment')),
            ),
            if (needsGasPrice(app))
              OutlinedButton.icon(
                key: const ValueKey('stock-purchase-price'),
                onPressed: () => editGasPrices(context, app),
                icon: const Icon(Icons.price_change_outlined),
                label: Text(context.t('Purchase price')),
              ),
            TextButton(
              onPressed: () => previewReport(
                context,
                buildReport(
                  app,
                  'FIFO allocations',
                  '2000-01-01',
                  businessDate(),
                  urdu: app.urdu,
                ),
              ),
              child: Text(context.t('FIFO allocations')),
            ),
          ],
        ),
        const SizedBox(height: 22),
        StockProfit(app),
        // Gas is tracked by KG and cylinder fills are never entered, so the
        // shop's full/empty counts are not shown; only cylinders customers
        // still hold, and only when there are any.
        if (b.held.values.any((v) => v != 0)) ...[
          const SizedBox(height: 22),
          Panel(
            child: Column(
              children: [
                const SectionHeader('Cylinders'),
                for (final size in sizes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.propane_tank_outlined,
                          color: teal,
                          size: 32,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            sizeLabel(size),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                context.t('Customer-held'),
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 11,
                                ),
                              ),
                              Text(
                                '${b.held.entries.where((e) => e.key.endsWith(':$size')).fold(0, (v, e) => v + e.value)}',
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 22),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader('Purchase lot'),
              if (b.lots.isEmpty)
                const EmptyState(
                  'No transactions yet',
                  'Your entries will appear here.',
                )
              else
                for (final lot in b.lots.where((l) => l.grams > 0))
                  _lotTile(context, lot),
            ],
          ),
        ),
      ],
    );
  }

  /// One gas purchase still in stock: who it came from, what it cost per
  /// unit, how much of it is left, and what that remainder is worth.
  Widget _lotTile(BuildContext context, StockLot lot) {
    final t = context.words;
    final record = app.record(lot.id);
    final source = record == null ? null : Document(record);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: source == null
          ? null
          : () => showTransaction(context, app, source),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.layers_outlined, color: teal),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source == null ? lot.id : entryTitle(app, source, t),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${t('Remaining')}: ${kg(lot.grams)} KG'
                    '${source == null ? '' : ' · ${entryHeadline(app, source, t)}'}',
                    style: const TextStyle(fontSize: 12.5, color: ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      lot.date,
                      if (source != null) source.reference,
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: lot.cost == null
                  ? const Tag('Unvalued quantity', warning: true)
                  : Amount(lot.cost!),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showHistory(
  BuildContext context,
  AppController app, {
  String? filterDate,
  Future<void> Function()? onRestored,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: app,
      builder: (ctx, _) {
        final list =
            app
                .ofKind('snapshot')
                .where(
                  (s) => filterDate == null || s.data['date'] == filterDate,
                )
                .toList()
              ..sort(
                (a, b) =>
                    '${b.data['savedAt']}'.compareTo('${a.data['savedAt']}'),
              );
        return AlertDialog(
          title: Text(ctx.t('Day history')),
          content: SizedBox(
            width: 600,
            height: 440,
            child: list.isEmpty
                ? const EmptyState(
                    'No results',
                    'Your entries will appear here.',
                  )
                : ListView(
                    children: [
                      for (final s in list)
                        ListTile(
                          title: Text('${s.data['date']}'),
                          subtitle: Text(
                            '${s.data['savedAt']} · ${(s.data['documents'] as List).length}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'restore') {
                                final reason = await askText(
                                  ctx,
                                  'Reason for correction',
                                );
                                if (reason != null && ctx.mounted) {
                                  await perform(ctx, () async {
                                    await app.restoreSnapshot(s, reason);
                                    await onRestored?.call();
                                  }, success: 'Saved');
                                }
                              } else if (v == 'view') {
                                if (ctx.mounted) {
                                  await previewReport(
                                    ctx,
                                    snapshotReport(app, s, urdu: app.urdu),
                                  );
                                }
                              } else {
                                await perform(
                                  ctx,
                                  () => app.commit([
                                    Change(s.id, 'snapshot', {
                                      ...s.data,
                                      'archived': true,
                                    }, s.version),
                                  ]),
                                );
                              }
                            },
                            itemBuilder: (ctx) => [
                              PopupMenuItem(
                                value: 'view',
                                child: Text(ctx.t('Preview PDF')),
                              ),
                              PopupMenuItem(
                                value: 'restore',
                                child: Text(ctx.t('Restore day')),
                              ),
                              PopupMenuItem(
                                value: 'archive',
                                child: Text(ctx.t('Archive')),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
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
