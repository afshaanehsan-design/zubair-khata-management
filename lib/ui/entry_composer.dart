import 'dart:async';

import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'roznamcha_widgets.dart' show dmy, errorText;
import 'masters.dart';
import 'opening_balance.dart';
import 'roznamcha_form.dart';

/// Opens the right form: daily cash-book entries use the Roznamcha form
/// (same tabs and fields as the original page); opening balances use their
/// own dialog; purchases, stock, cylinders, credit notes and conflict reviews
/// use the general composer below.
Future<void> composeEntry(
  BuildContext context,
  AppController app, {
  EntryType? type,
  Document? replace,
  String? party,
  Json? prefill,
  Future<void> Function()? onSaved,
}) async {
  // Opening balances and other adjustments are corrected in their own small
  // dialog, which shows payables the way they are read.
  if (prefill == null &&
      onSaved == null &&
      replace?.type == EntryType.adjustment) {
    await editOpeningBalance(context, app, existing: replace);
    return;
  }
  if (prefill == null &&
      onSaved == null &&
      (replace != null
          ? rozEditable(replace)
          : type == null || type == EntryType.sale)) {
    await openRoznamchaForm(context, app, party: party, replace: replace);
    return;
  }
  final child = EntryComposer(
    app: app,
    initial: type,
    replace: replace,
    initialParty: party,
    prefill: prefill,
    onSaved: onSaved,
  );
  if (MediaQuery.sizeOf(context).width < 700) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: paper,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .96,
        child: child,
      ),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: paper,
        child: SizedBox(
          width: 740,
          height: MediaQuery.sizeOf(context).height * .9,
          child: child,
        ),
      ),
    );
  }
}

/// General composer for every entry type. Daily Roznamcha entries normally
/// use [RoznamchaForm]; this remains for purchases, stock, cylinders, credit
/// notes, transfers between banks and reviewing conflicting changes.
class EntryComposer extends StatefulWidget {
  final AppController app;
  final EntryType? initial;
  final Document? replace;
  final String? initialParty;
  final Json? prefill;
  final Future<void> Function()? onSaved;
  const EntryComposer({
    required this.app,
    this.initial,
    this.replace,
    this.initialParty,
    this.prefill,
    this.onSaved,
    super.key,
  });
  @override
  State<EntryComposer> createState() => _EntryComposerState();
}

class _EntryComposerState extends State<EntryComposer> {
  final fields = <String, TextEditingController>{};
  EntryType type = EntryType.sale;

  /// Roznamcha form the edited entry came from; kept on corrections.
  String form = '';
  String date = '',
      party = '',
      account = 'cash',
      bankAccount = '',
          // The party a customer paid directly (Roznamcha "Direct to Party").
          directParty =
          '',
      toAccount = '',
      category = 'General',
      target = '',
      dueDate = '',
      sourceInvoice = '',
      cylinderMode = 'Acquire';
  int rateUnit = 11800, cylinderSize = 11800;
  bool customerOwned = false,
      bulkAtCost = true,
      stockReturned = false,
      supplierPayment = false,
      supplierRefund = false,
      costKnown = false,
      acquireFull = false,
      saving = false,
      loading = true;
  Json? allocations;
  dynamic bankLines;
  String? shareCostError;

  /// The reference of the purchase a share comes from; '' for oldest stock
  /// first (FIFO).
  String sharePurchase = '';
  int occurredAt = DateTime.now().millisecondsSinceEpoch;
  final returnedEdited = <int, bool>{};

  /// Only a new entry keeps a draft ([AppController.composerDrafts]); a
  /// correction or a reviewed change always starts from its own data.
  bool get keepsDraft => widget.replace == null && widget.prefill == null;
  String get draftKey =>
      widget.initial != null &&
          ![
            EntryType.sale,
            EntryType.receipt,
            EntryType.payment,
            EntryType.expense,
            EntryType.transfer,
            EntryType.discount,
            EntryType.adjustment,
          ].contains(widget.initial)
      ? 'context:${widget.initial!.name}'
      : 'new-entry';
  @override
  void initState() {
    super.initState();
    for (final key in [
      'amount',
      'cash',
      'bank',
      'direct',
      'directBank',
      'rate',
      'extraGrams',
      'grams',
      'cost',
      'note',
      'vehicle',
      'branch',
      'customerNote',
      'depositCharge',
      'count',
      'fullDelta',
      'emptyDelta',
      'heldDelta',
      for (final size in sizes) ...['q$size', 'r$size'],
    ]) {
      fields[key] = TextEditingController();
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    date = widget.app.selectedDate;
    type = widget.replace?.type ?? widget.initial ?? EntryType.sale;
    party = widget.initialParty ?? '';
    var draft = keepsDraft ? widget.app.composerDrafts[draftKey] : null;
    // A draft begun for another party is not used for this one.
    if (widget.initialParty != null && draft?['party'] != widget.initialParty) {
      draft = null;
    }
    final saved = widget.prefill ?? widget.replace?.data ?? draft;
    if (saved != null &&
        (widget.initial == null ||
            saved['type'] == type.name ||
            widget.replace != null)) {
      _hydrate(saved);
      if (identical(saved, draft)) {
        // A draft keeps what was typed, not when: the entry goes on the
        // page's date at the current time, never on the day it was begun.
        date = widget.app.selectedDate;
        occurredAt = DateTime.now().millisecondsSinceEpoch;
      }
    }
    if (type == EntryType.transfer &&
        widget.replace == null &&
        widget.prefill == null) {
      // A new transfer here is bank to bank. Cash has its own Roznamcha
      // forms (Bank se Cash Nikala, Bank account mein jama).
      if (account == 'cash') account = '';
      if (toAccount == 'cash') toAccount = '';
    }
    if (fields['rate']!.text.isEmpty &&
        integer(widget.app.settings['defaultRate']) > 0) {
      fields['rate']!.text = decimalText(
        integer(widget.app.settings['defaultRate']),
        2,
      );
    }
    if (mounted) setState(() => loading = false);
    if (party.isNotEmpty && widget.app.record(party) == null) party = '';
  }

  void _hydrate(Json data) {
    if (data.containsKey('occurredAt')) {
      occurredAt = integer(data['occurredAt']);
    }
    form = '${data['form'] ?? ''}';
    sourceInvoice = '${data['sourceInvoice'] ?? ''}';
    stockReturned = data['stockReturned'] == true;
    type = EntryType.values.byName('${data['type']}');
    date = '${data['date']}';
    party = '${data['party'] ?? party}';
    account = '${data['account'] ?? 'cash'}';
    bankAccount = '${data['bankAccount'] ?? ''}';
    directParty = '${data['directParty'] ?? ''}';
    bankLines = data['bankLines'];
    toAccount = '${data['toAccount'] ?? ''}';
    category = '${data['category'] ?? 'General'}';
    target = '${data['target'] ?? ''}';
    dueDate = '${data['dueDate'] ?? ''}';
    customerOwned = data['customerOwned'] == true;
    bulkAtCost = data['shareBulkChoice'] as bool? ?? data['bulkAtCost'] == true;
    sharePurchase = '${data['sharePurchase'] ?? ''}';
    supplierPayment = data['supplierPayment'] == true;
    supplierRefund = data['supplierRefund'] == true;
    costKnown = data['costKnown'] == true;
    cylinderMode = '${data['cylinderMode'] ?? 'Acquire'}';
    cylinderSize = integer(data['size']) == 0 ? 11800 : integer(data['size']);
    acquireFull = data['acquireFull'] == true;
    rateUnit = integer(data['rateUnit']) == 0
        ? 11800
        : integer(data['rateUnit']);
    allocations = data['allocations'] == null
        ? null
        : Map<String, dynamic>.from(data['allocations'] as Map);
    for (final key in [
      'amount',
      'cash',
      'bank',
      'direct',
      'rate',
      'cost',
      'depositCharge',
    ]) {
      if (integer(data[key]) != 0) {
        fields[key]!.text = decimalText(integer(data[key]), 2);
      }
    }
    for (final key in ['extraGrams', 'grams']) {
      if (integer(data[key]) != 0) {
        fields[key]!.text = decimalText(integer(data[key]), 3);
      }
    }
    for (final key in [
      'note',
      'directBank',
      'vehicle',
      'branch',
      'customerNote',
      'count',
      'fullDelta',
      'emptyDelta',
      'heldDelta',
    ]) {
      fields[key]!.text = '${data[key] ?? ''}';
    }
    for (final size in sizes) {
      fields['q$size']!.text =
          '${(data['quantities'] as Map?)?['$size'] ?? ''}';
      fields['r$size']!.text = '${(data['returned'] as Map?)?['$size'] ?? ''}';
      returnedEdited[size] =
          integer((data['returned'] as Map?)?['$size']) !=
          integer((data['quantities'] as Map?)?['$size']);
    }
  }

  int _number(String key, int places, {bool strict = false}) {
    try {
      return decimal(fields[key]!.text, places);
    } catch (_) {
      if (strict) rethrow;
      return 0;
    }
  }

  Json _payload({bool strict = false}) {
    var full = _number('fullDelta', 0, strict: strict),
        empty = _number('emptyDelta', 0, strict: strict),
        held = _number('heldDelta', 0, strict: strict);
    // A loss or correction is entered as the three changes; the quantity
    // field is hidden then, so whatever it still holds is not sent.
    final count = cylinderMode == 'Loss / correction'
        ? 0
        : _number('count', 0, strict: strict);
    if (type == EntryType.cylinder && cylinderMode != 'Loss / correction') {
      full = switch (cylinderMode) {
        'Acquire' => acquireFull ? count : 0,
        'Fill' => count,
        'Issue' => -count,
        _ => 0,
      };
      empty = switch (cylinderMode) {
        'Acquire' => acquireFull ? 0 : count,
        'Fill' => -count,
        'Return' => count,
        _ => 0,
      };
      held = switch (cylinderMode) {
        'Issue' => count,
        'Return' => -count,
        _ => 0,
      };
    }
    final payload = <String, dynamic>{
      'type': type.name,
      'shareBulkChoice': bulkAtCost,
      if (form.isNotEmpty) 'form': form,
      'date': date,
      'party': party,
      'account': account,
      'bankAccount': bankAccount,
      'directParty': _number('direct', 2) > 0 ? directParty : '',
      if (bankLines != null) 'bankLines': bankLines,
      'toAccount': toAccount,
      'category': category,
      'target': target,
      'dueDate': dueDate,
      'customerOwned': customerOwned,
      'supplierPayment': supplierPayment,
      'supplierRefund': supplierRefund,
      'costKnown': costKnown,
      'rateUnit': rateUnit,
      'size': cylinderSize,
      'cylinderMode': cylinderMode,
      'acquireFull': acquireFull,
      'count': count,
      'fullDelta': full,
      'emptyDelta': empty,
      'heldDelta': held,
      for (final key in [
        'amount',
        'cash',
        'bank',
        'direct',
        'rate',
        'cost',
        'depositCharge',
      ])
        key: _number(key, 2, strict: strict),
      for (final key in ['extraGrams', 'grams'])
        key: _number(key, 3, strict: strict),
      for (final key in [
        'note',
        'vehicle',
        'branch',
        'customerNote',
        'directBank',
      ])
        key: fields[key]!.text.trim(),
      'quantities': {
        for (final size in sizes) '$size': _number('q$size', 0, strict: strict),
      },
      'returned': {
        for (final size in sizes) '$size': _number('r$size', 0, strict: strict),
      },
      if (allocations != null) 'allocations': allocations,
      'occurredAt': occurredAt,
      if (type == EntryType.sale && customerOwned) 'depositCharge': 0,
      if (type == EntryType.stockAdjustment && _number('grams', 3) < 0) ...{
        'cost': 0,
        'costKnown': false,
      },
      if (type == EntryType.creditNote) ...{
        'sourceInvoice': sourceInvoice,
        'stockReturned': stockReturned,
        'quantities':
            widget.app.record(sourceInvoice)?.data['quantities'] ?? {},
        'rate': widget.app.record(sourceInvoice)?.data['rate'] ?? 0,
        'extraGrams': widget.app.record(sourceInvoice)?.data['extraGrams'] ?? 0,
        if (widget.app.record(sourceInvoice)?.data['bulkAtCost'] == true) ...{
          'bulkAtCost': true,
          'bulkCost': widget.app.record(sourceInvoice)?.data['bulkCost'] ?? 0,
          if (widget.app.record(sourceInvoice)?.data['sharePurchase'] != null)
            'sharePurchase':
                widget.app.record(sourceInvoice)?.data['sharePurchase'],
        },
        'cash': 0,
        'bank': 0,
        'depositCharge': 0,
      },
    };
    shareCostError = null;
    if (type == EntryType.sale &&
        bulkAtCost &&
        integer(payload['extraGrams']) > 0) {
      payload['bulkAtCost'] = true;
      if (sharePurchase.isNotEmpty) payload['sharePurchase'] = sharePurchase;
      try {
        payload['bulkCost'] = widget.app.quoteBulkCost(
          payload,
          replace: widget.replace,
        );
      } catch (e) {
        if (strict) rethrow;
        shareCostError = errorText(context, e);
        payload['bulkCost'] = widget.replace?.value('bulkCost') ?? 0;
      }
    }
    return payload;
  }

  void changed() {
    setState(() {});
    if (keepsDraft) widget.app.composerDrafts[draftKey] = _payload();
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    String key,
    String label, {
    int places = 2,
    bool text = false,
    bool signed = false,
    String? suffix,
    void Function(String)? onChanged,
  }) => TextField(
    key: ValueKey('field-$key'),
    controller: fields[key],
    textDirection: text ? null : TextDirection.ltr,
    keyboardType: text
        ? TextInputType.text
        : TextInputType.numberWithOptions(decimal: places > 0, signed: signed),
    maxLines: key == 'note' ? 2 : 1,
    decoration: InputDecoration(
      labelText: context.t(label),
      suffixText: suffix,
      prefixText: !text && places == 2 ? 'Rs ' : null,
    ),
    onChanged: (v) {
      onChanged?.call(v);
      changed();
    },
  );
  Widget grid(List<Widget> children, {int columns = 2}) => LayoutBuilder(
    builder: (context, box) {
      final n = box.maxWidth < 400 ? 1 : columns;
      return Wrap(
        spacing: 14,
        runSpacing: 16,
        children: children
            .map(
              (w) =>
                  SizedBox(width: (box.maxWidth - (n - 1) * 14) / n, child: w),
            )
            .toList(),
      );
    },
  );
  Widget select(
    String label,
    String value,
    List<(String, String)> options,
    ValueChanged<String> onChanged,
  ) => DropdownButtonFormField<String>(
    initialValue: options.any((o) => o.$1 == value) ? value : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: context.t(label)),
    items: options
        .map(
          (o) => DropdownMenuItem(
            value: o.$1,
            child: Text(context.t(o.$2), overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: (v) {
      if (v != null) {
        onChanged(v);
        changed();
      }
    },
  );
  Widget accountSelect(
    String label,
    String selected,
    ValueChanged<String> onChanged, {
    bool bankOnly = false,
  }) {
    final accounts = widget.app
        .ofKind('account')
        .where((r) => !bankOnly || r.id != 'cash')
        .toList();
    // An older entry may use an account this list leaves out (Cash, or an
    // archived account); show it instead of an empty field.
    final current = widget.app.record(selected);
    if (current != null &&
        current.kind == 'account' &&
        !accounts.any((r) => r.id == selected)) {
      accounts.add(current);
    }
    return select(label, selected, [
      for (final r in accounts) (r.id, r.name),
    ], onChanged);
  }

  Widget partySelect() => Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.all(18),
          ),
          onPressed: () async {
            final id = await pickRecord(
              context,
              widget.app,
              'party',
              companiesOnly: type == EntryType.purchase,
            );
            if (id != null && mounted) {
              party = id;
              changed();
            }
          },
          icon: const Icon(Icons.person_outline),
          label: Text(
            party.isEmpty
                ? context.t('Choose a party')
                : widget.app.name(party),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        tooltip: context.t('Add party'),
        onPressed: () async {
          await editMaster(context, widget.app, 'party');
          if (mounted) changed();
        },
        icon: const Icon(Icons.person_add_alt_1_outlined),
      ),
    ],
  );
  Widget collection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      grid([field('cash', 'Cash received'), field('bank', 'Bank received')]),
      const SizedBox(height: 16),
      if (_number('bank', 2) > 0 || bankAccount.isNotEmpty)
        accountSelect(
          'Bank account',
          bankAccount,
          (v) => bankAccount = v,
          bankOnly: true,
        ),
      // Paid by the customer straight to a company: no cash or bank moves.
      if (!supplierRefund) ...[
        const SizedBox(height: 16),
        field('direct', 'Direct to Party'),
        if (_number('direct', 2) > 0) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsets.all(18),
            ),
            onPressed: () async {
              final id = await pickRecord(context, widget.app, 'party');
              if (id != null && mounted) {
                directParty = id;
                changed();
              }
            },
            icon: const Icon(Icons.business_outlined),
            label: Text(
              widget.app.record(directParty) == null
                  ? context.t('Kis party ko diye? (Company)')
                  : widget.app.name(directParty),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 12),
          field('directBank', 'Kis bank mein? (company ka)', text: true),
        ],
      ],
      if (party.isNotEmpty && !supplierRefund)
        TextButton.icon(
          onPressed: _allocationDialog,
          icon: const Icon(Icons.account_tree_outlined, size: 18),
          label: Text(
            context.t(
              allocations == null
                  ? 'Automatic oldest first'
                  : 'Manual allocation',
            ),
          ),
        ),
    ],
  );
  Future<void> _allocationDialog() async {
    final invoices = widget.app.book.documents
        .where(
          (d) =>
              d.type == EntryType.sale &&
              d.party == party &&
              (widget.app.book.invoiceDue[d.id] ?? 0) > 0,
        )
        .toList();
    final edits = {
      for (final d in invoices)
        d.id: TextEditingController(
          text: allocations == null
              ? ''
              : decimalText(integer(allocations![d.id]), 2),
        ),
    };
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Settlement allocation')),
        content: SizedBox(
          width: 420,
          height: 300,
          child: ListView(
            children: [
              for (final d in invoices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextField(
                    controller: edits[d.id],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText:
                          '${d.reference} · Rs ${money(widget.app.book.invoiceDue[d.id] ?? 0)}',
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              allocations = null;
              Navigator.pop(ctx);
            },
            child: Text(ctx.t('Automatic oldest first')),
          ),
          FilledButton(
            onPressed: () async {
              await perform(ctx, () async {
                final proposed = {
                  for (final e in edits.entries)
                    e.key: decimal(e.value.text, 2),
                };
                if (proposed.values.any((v) => v < 0) ||
                    proposed.values.fold(0, (a, b) => a + b) >
                        _number('cash', 2) +
                            _number('bank', 2) +
                            _number('direct', 2)) {
                  throw const FormatException('Enter a valid number');
                }
                allocations = proposed;
                if (ctx.mounted) Navigator.pop(ctx);
              });
            },
            child: Text(ctx.t('Save')),
          ),
        ],
      ),
    );
    if (mounted) changed();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final c in edits.values) {
      c.dispose();
    }
  }

  Future<void> save(bool next) async {
    if (saving) return;
    setState(() => saving = true);
    var posted = false;
    await perform(context, () async {
      final payload = _payload(strict: true);
      if (type == EntryType.stockAdjustment &&
          costKnown &&
          _number('grams', 3) > 0 &&
          fields['cost']!.text.trim().isEmpty) {
        throw const FormatException('Enter stock cost');
      }
      String reason = '';
      if (widget.replace != null) {
        reason = await askText(context, 'Reason for correction') ?? '';
        if (reason.isEmpty) throw const FormatException('A reason is required');
      }
      if (type == EntryType.cylinder &&
          cylinderMode != 'Loss / correction' &&
          _number('count', 0) <= 0) {
        throw const FormatException('Enter cylinder count changes');
      }
      // Gas is bought from a company: a purchase from a party not yet marked
      // as one marks it, in the same change, as the Roznamcha form does.
      final seller = type == EntryType.purchase
          ? widget.app.record('${payload['party'] ?? ''}')
          : null;
      await widget.app.post(
        payload,
        replace: widget.replace,
        reason: reason,
        before: [
          if (seller != null &&
              seller.kind == 'party' &&
              seller.data['supplier'] != true)
            Change(seller.id, 'party', {
              ...seller.data,
              'supplier': true,
            }, seller.version),
        ],
      );
      posted = true;
      await widget.onSaved?.call();
      if (keepsDraft) widget.app.composerDrafts.remove(draftKey);
    }, success: 'Saved locally');
    if (!mounted) return;
    if (posted && !next) {
      Navigator.pop(context);
      return;
    }
    if (posted) {
      for (final e in fields.entries) {
        if (!['rate', 'branch'].contains(e.key)) e.value.clear();
      }
      allocations = null;
      returnedEdited.clear();
      occurredAt = DateTime.now().millisecondsSinceEpoch;
    }
    setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final document = Document(Record('preview', 'document', _payload()));
    final hasParty = [
      EntryType.creditNote,
      EntryType.sale,
      EntryType.receipt,
      EntryType.payment,
      EntryType.purchase,
      EntryType.discount,
      EntryType.deposit,
      EntryType.depositRefund,
      EntryType.cylinder,
    ].contains(type);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: teal.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(entryIcon(type), color: teal),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  context.t(
                    widget.replace == null ? 'New entry' : 'Correct entry',
                  ),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              IconButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tag(entryLabel(type.name)),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final result = await pickDate(context, date);
                        if (result != null && mounted) {
                          date = result;
                          changed();
                        }
                      },
                      icon: const Icon(Icons.calendar_today_outlined, size: 18),
                      label: Text(date),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                if (hasParty) ...[partySelect(), const SizedBox(height: 22)],
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: () async {
                      final at = DateTime.fromMillisecondsSinceEpoch(occurredAt)
                          .toUtc()
                          .add(const Duration(hours: 5));
                      final value = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(at),
                      );
                      if (value != null && mounted) {
                        occurredAt = DateTime.parse(
                          '${date}T${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:00+05:00',
                        ).millisecondsSinceEpoch;
                        changed();
                      }
                    },
                    icon: const Icon(Icons.schedule, size: 17),
                    label: Text(
                      occurredAt == 0
                          ? context.t('Opening')
                          : '${context.t('Time')}: ${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(occurredAt).toUtc().add(const Duration(hours: 5))).format(context)}',
                    ),
                  ),
                ),
                if (widget.app.isClosed(date)) const Notice('Day is closed'),
                if (type == EntryType.creditNote) ...[
                  select(
                    'Invoices',
                    sourceInvoice,
                    widget.app.book.documents
                        .where(
                          (d) => d.type == EntryType.sale && d.party == party,
                        )
                        .map((d) => (d.id, d.reference))
                        .toList(),
                    (v) => sourceInvoice = v,
                  ),
                  const SizedBox(height: 16),
                  Panel(
                    child: Row(
                      children: [
                        Expanded(child: Text(context.t('Credit note'))),
                        Amount(document.bill),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.t('Return gas to stock')),
                    value: stockReturned,
                    onChanged: (v) {
                      stockReturned = v;
                      changed();
                    },
                  ),
                  Text(
                    context.t(
                      'Collections and deposits stay unchanged. Record cylinder returns separately.',
                    ),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
                if (type == EntryType.sale) ...[
                  const SectionHeader('Cylinder quantities'),
                  grid([
                    for (final size in sizes)
                      field(
                        'q$size',
                        sizeLabel(size),
                        places: 0,
                        onChanged: (v) {
                          if (returnedEdited[size] != true) {
                            fields['r$size']!.text = v;
                          }
                        },
                      ),
                  ], columns: 3),
                  const SizedBox(height: 18),
                  grid([
                    if (!document.purchaseShare)
                      field('rate', 'Rate per 11.8 KG'),
                    field('extraGrams', 'Bulk KG', places: 3),
                  ]),
                  if (document.extraGrams > 0)
                    SwitchListTile(
                      key: const ValueKey('composer-share-at-cost'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.t('Share bulk at purchase cost')),
                      subtitle: Text(
                        context.t(
                          'Not our sale; the party pays our purchase price.',
                        ),
                      ),
                      value: bulkAtCost,
                      onChanged: (v) {
                        bulkAtCost = v;
                        changed();
                      },
                    ),
                  if (document.extraGrams > 0 && bulkAtCost)
                    KeyedSubtree(
                      key: const ValueKey('composer-share-purchase'),
                      child: select('Share from', sharePurchase, [
                        ('', 'Oldest stock first (FIFO)'),
                        for (final (p, free) in widget.app.sharePurchaseOptions(
                          date,
                          replace: widget.replace,
                          selected: sharePurchase,
                        ))
                          (
                            '${p.data['reference']}',
                            '${dmy(p.date)} · ${widget.app.name(p.party)} · '
                                '${kg(p.value('grams'))} KG '
                                '(${context.t('free')} ${kg(free)})',
                          ),
                      ], (v) => sharePurchase = v),
                    ),
                  if (shareCostError != null)
                    Text(
                      shareCostError!,
                      style: const TextStyle(color: danger),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    context.t('Bulk gas reduces gas stock.'),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(context.t('Cylinder details (optional)')),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.t('Customer-owned cylinders')),
                        value: customerOwned,
                        onChanged: (v) {
                          customerOwned = v;
                          changed();
                        },
                      ),
                      if (!customerOwned) ...[
                        const SectionHeader('Empty cylinders returned'),
                        grid([
                          for (final size in sizes)
                            field(
                              'r$size',
                              sizeLabel(size),
                              places: 0,
                              onChanged: (_) => returnedEdited[size] = true,
                            ),
                        ], columns: 3),
                        const SizedBox(height: 16),
                        field('depositCharge', 'Deposit charged'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 18),
                  Panel(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.t('Bill total'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Amount(document.total, large: true),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.t('Cylinder billing'),
                                style: const TextStyle(color: muted),
                              ),
                            ),
                            Amount(document.cylinderRevenue),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.t(
                                  document.bulkAtCost
                                      ? 'Purchase share (at cost)'
                                      : 'Extra-KG billing',
                                ),
                                style: const TextStyle(color: muted),
                              ),
                            ),
                            Amount(document.bulkBill),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () {
                        fields['cash']!.text = decimalText(document.total, 2);
                        fields['bank']!.clear();
                        changed();
                      },
                      child: Text(context.t('Receive full bill')),
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () {
                        fields['bank']!.text = decimalText(document.total, 2);
                        fields['cash']!.clear();
                        changed();
                      },
                      child: Text(context.t('Receive full into bank')),
                    ),
                  ),
                  collection(),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final result = await pickDate(
                        context,
                        dueDate.isEmpty ? date : dueDate,
                      );
                      if (result != null && mounted) {
                        dueDate = result;
                        changed();
                      }
                    },
                    icon: const Icon(Icons.event_outlined),
                    label: Text('${context.t('Due date')}: $dueDate'),
                  ),
                ],
                if (type == EntryType.receipt) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.t('Supplier refund')),
                    value: supplierRefund,
                    onChanged: (v) {
                      supplierRefund = v;
                      changed();
                    },
                  ),
                  collection(),
                ],
                if (type == EntryType.payment) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.t('Supplier payment')),
                    subtitle: Text(context.t('Customer payout / loan')),
                    value: supplierPayment,
                    onChanged: (v) {
                      supplierPayment = v;
                      changed();
                    },
                  ),
                  grid([
                    field('amount', 'Amount'),
                    accountSelect('From account', account, (v) => account = v),
                  ]),
                  const SizedBox(height: 16),
                  grid([
                    field('branch', 'Branch', text: true),
                    field('customerNote', 'Customer annotation', text: true),
                  ]),
                ],
                if (type == EntryType.expense) ...[
                  grid([
                    field('amount', 'Amount'),
                    accountSelect('From account', account, (v) => account = v),
                  ]),
                  const SizedBox(height: 16),
                  select(
                    'Category',
                    category,
                    [
                      'General',
                      'Office',
                      'Transport',
                      'Utilities',
                      'Maintenance',
                    ].map((s) => (s, s)).toList(),
                    (v) => category = v,
                  ),
                ],
                if (type == EntryType.purchase) ...[
                  grid([
                    field('grams', 'Weight (KG)', places: 3),
                    field('rate', 'Rate'),
                  ]),
                  const SizedBox(height: 16),
                  select('Rate unit', '$rateUnit', [
                    ('1000', 'per KG'),
                    ('11800', 'per 11.8 KG'),
                    ('1000000', 'per tonne'),
                  ], (v) => rateUnit = int.parse(v)),
                  const SizedBox(height: 18),
                  Panel(
                    child: Row(
                      children: [
                        Expanded(child: Text(context.t('Bill total'))),
                        Amount(document.purchaseBill, large: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  grid([
                    field('amount', 'Paid now'),
                    accountSelect('From account', account, (v) => account = v),
                  ]),
                ],
                if (type == EntryType.transfer) ...[
                  grid([
                    accountSelect(
                      'From account',
                      account,
                      (v) => account = v,
                      bankOnly: true,
                    ),
                    accountSelect(
                      'To account',
                      toAccount,
                      (v) => toAccount = v,
                      bankOnly: true,
                    ),
                  ]),
                  const SizedBox(height: 16),
                  field('amount', 'Amount'),
                ],
                if ([
                  EntryType.discount,
                  EntryType.deposit,
                  EntryType.depositRefund,
                ].contains(type)) ...[
                  field('amount', 'Amount'),
                  if (type != EntryType.discount) ...[
                    const SizedBox(height: 16),
                    accountSelect(
                      type == EntryType.deposit ? 'To account' : 'From account',
                      account,
                      (v) => account = v,
                    ),
                  ],
                ],
                if (type == EntryType.adjustment) ...[
                  select('Balance to correct', target, [
                    for (final a in widget.app.ofKind('account'))
                      ('money:${a.id}', a.name),
                    for (final p in widget.app.ofKind('party')) ...[
                      ('ar:${p.id}', '${context.t('Receivable')}: ${p.name}'),
                      ('ap:${p.id}', '${context.t('Payable')}: ${p.name}'),
                      if (target == 'deposit:${p.id}')
                        (
                          'deposit:${p.id}',
                          '${context.t('Deposit')}: ${p.name}',
                        ),
                    ],
                  ], (v) => target = v),
                  const SizedBox(height: 16),
                  field('amount', 'Signed amount (+ / −)', signed: true),
                ],
                if (type == EntryType.stockAdjustment) ...[
                  field('grams', 'Stock change (KG)', places: 3, signed: true),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.t('Cost is known')),
                    value: costKnown,
                    onChanged: (v) {
                      costKnown = v;
                      changed();
                    },
                  ),
                  if (costKnown && _number('grams', 3) > 0)
                    field('cost', 'Known total cost'),
                ],
                if (type == EntryType.cylinder) ...[
                  grid([
                    select(
                      'Cylinder movement',
                      cylinderMode,
                      [
                        'Acquire',
                        'Fill',
                        'Issue',
                        'Return',
                        'Loss / correction',
                      ].map((s) => (s, s)).toList(),
                      (v) => cylinderMode = v,
                    ),
                    select(
                      'Size',
                      '$cylinderSize',
                      sizes.map((s) => ('$s', sizeLabel(s))).toList(),
                      (v) => cylinderSize = int.parse(v),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  if (cylinderMode != 'Loss / correction')
                    field('count', 'Quantity', places: 0),
                  if (cylinderMode == 'Acquire')
                    SwitchListTile(
                      title: Text(context.t('Full')),
                      contentPadding: EdgeInsets.zero,
                      value: acquireFull,
                      onChanged: (v) {
                        acquireFull = v;
                        changed();
                      },
                    ),
                  if (cylinderMode == 'Loss / correction')
                    grid([
                      field(
                        'fullDelta',
                        'Full count change',
                        places: 0,
                        signed: true,
                      ),
                      field(
                        'emptyDelta',
                        'Empty count change',
                        places: 0,
                        signed: true,
                      ),
                      field(
                        'heldDelta',
                        'Customer-held change',
                        places: 0,
                        signed: true,
                      ),
                    ]),
                ],
                if (type == EntryType.historicalSale)
                  grid([
                    field('grams', 'Weight (KG)', places: 3),
                    field('amount', 'Amount'),
                  ]),
                const SizedBox(height: 18),
                if ([EntryType.sale, EntryType.purchase].contains(type)) ...[
                  field('vehicle', 'Vehicle / parchi', text: true),
                  const SizedBox(height: 18),
                ],
                field('note', 'Note / reason', text: true),
                if (type == EntryType.sale && party.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Row(
                      children: [
                        Expanded(child: Text(context.t('Remaining balance'))),
                        Amount(
                          widget.app.book.partyBalance(party) -
                              (widget.replace?.total ?? 0) +
                              (widget.replace?.collected ?? 0) +
                              document.total -
                              document.collected,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(
            24,
            16,
            24,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xffe0e7dc))),
          ),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 10,
            children: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: Text(context.t('Cancel')),
              ),
              if (widget.replace == null && widget.prefill == null)
                OutlinedButton(
                  onPressed: saving ? null : () => save(true),
                  child: Text(context.t('Save & next')),
                ),
              FilledButton.icon(
                onPressed: saving ? null : () => save(false),
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text(context.t('Save')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
