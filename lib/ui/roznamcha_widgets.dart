import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'masters.dart';

const rozBorder = Color(0xffdfe6dc),
    rozSoft = Color(0xfff4f7f2),
    rozSoft2 = Color(0xffe7eee4),
    rozAccentSoft = Color(0xfffbf1e1),
    rozRed = Color(0xffa33d3d);

/// "Rs 1,234" with brackets for negatives, like the original page.
String rs(int minor) =>
    minor < 0 ? 'Rs (${money(-minor)})' : 'Rs ${money(minor)}';

/// Day/month/year as on the original page.
String dmy(String date) {
  final p = date.split('-');
  return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : date;
}

String nextDate(String date, int days) =>
    DateTime.parse(date)
        .add(Duration(days: days))
        .toIso8601String()
        .substring(0, 10);

/// Panel with an accented heading, as on the HTML Roznamcha.
class RozPanel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  final Color accent;
  const RozPanel({
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const [],
    this.accent = teal,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: rozBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: accent, width: 3),
              bottom: const BorderSide(color: rozBorder),
            ),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.t(title),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: accent == teal ? ink : accent,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          context.t(subtitle!),
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              if (actions.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
            ],
          ),
        ),
        child,
      ],
    ),
  );
}

/// Summary card with a coloured top border (HTML stat-card).
class RozStat extends StatelessWidget {
  final String label, value;
  final String? sub;
  final Color color;
  final Widget? extra;
  const RozStat(
    this.label,
    this.value, {
    this.sub,
    this.color = teal,
    this.extra,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: rozBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 3, color: color),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t(label),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: muted,
                  letterSpacing: .2,
                ),
              ),
              const SizedBox(height: 6),
              Directionality(
                textDirection: TextDirection.ltr,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: color == teal ? ink : color,
                    ),
                  ),
                ),
              ),
              if (sub != null && sub!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    sub!,
                    style: const TextStyle(fontSize: 11.5, color: muted),
                  ),
                ),
              ?extra,
            ],
          ),
        ),
      ],
    ),
  );
}

class RozBadge extends StatelessWidget {
  final String text;
  final bool accent;
  final bool outlined;
  const RozBadge(
    this.text, {
    this.accent = false,
    this.outlined = false,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: accent ? rozAccentSoft : rozSoft2,
      borderRadius: BorderRadius.circular(4),
      border: outlined
          ? Border.all(
              color: accent ? const Color(0xffe6d4ac) : const Color(0xffc5d6c6),
            )
          : null,
    ),
    child: Text(
      context.t(text),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: accent ? amber : teal,
      ),
    ),
  );
}

class GridItem {
  final Widget child;
  final int span;
  const GridItem(this.child, {this.span = 1});
}

/// A responsive form grid: as many columns as fit, items may span columns.
class FormGrid extends StatelessWidget {
  final List<GridItem> items;
  final double minWidth;
  final int maxColumns;
  const FormGrid(
    this.items, {
    this.minWidth = 150,
    this.maxColumns = 6,
    super.key,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 10.0;
      final columns = ((box.maxWidth + gap) / (minWidth + gap)).floor().clamp(
        1,
        maxColumns,
      );
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          for (final item in items)
            SizedBox(
              width:
                  width * item.span.clamp(1, columns) +
                  gap * (item.span.clamp(1, columns) - 1),
              child: item.child,
            ),
        ],
      );
    },
  );
}

/// Small label above an input, like the HTML form.
class Labeled extends StatelessWidget {
  final String label;
  final Widget child;
  final String? helper;
  final Color? helperColor;
  const Labeled(
    this.label,
    this.child, {
    this.helper,
    this.helperColor,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        context.t(label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: muted,
          letterSpacing: .3,
        ),
      ),
      const SizedBox(height: 5),
      child,
      if (helper != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            helper!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: helperColor ?? muted,
            ),
          ),
        ),
    ],
  );
}

InputDecoration rozDecoration(String? hint, {String? prefix}) =>
    InputDecoration(
      isDense: true,
      hintText: hint,
      prefixText: prefix,
      hintStyle: const TextStyle(fontSize: 13, color: Color(0xffa0aca6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: rozBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: rozBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: teal, width: 1.5),
      ),
    );

/// Numeric or text input with the original page's look.
class RozInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool number, signed;
  final int decimals;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final String? helper;
  final Color? helperColor;
  final String? prefix;
  const RozInput(
    this.label,
    this.controller, {
    this.hint,
    this.number = true,
    this.signed = false,
    this.decimals = 2,
    this.onChanged,
    this.onSubmitted,
    this.helper,
    this.helperColor,
    this.prefix,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Labeled(
    label,
    TextField(
      controller: controller,
      textDirection: number ? TextDirection.ltr : null,
      keyboardType: number
          ? TextInputType.numberWithOptions(
              decimal: decimals > 0,
              signed: signed,
            )
          : TextInputType.text,
      inputFormatters: number
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9۰-۹٠-٩.,٫\-−]'))]
          : null,
      textInputAction: onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      style: const TextStyle(fontSize: 14),
      decoration: rozDecoration(
        hint == null ? null : context.t(hint!),
        prefix: prefix,
      ),
      onChanged: onChanged,
    ),
    helper: helper,
    helperColor: helperColor,
  );
}

/// Text input with remembered suggestions (HTML datalist).
class SuggestInput extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  final List<String> suggestions;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  const SuggestInput(
    this.label,
    this.controller,
    this.suggestions, {
    this.hint,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });
  @override
  State<SuggestInput> createState() => _SuggestInputState();
}

class _SuggestInputState extends State<SuggestInput> {
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Labeled(
    widget.label,
    RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: focus,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return const [];
        return widget.suggestions
            .where((s) => s.toLowerCase().contains(q) && s.toLowerCase() != q)
            .take(8);
      },
      fieldViewBuilder: (context, controller, focusNode, submit) => TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: widget.onSubmitted == null
            ? TextInputAction.next
            : TextInputAction.done,
        onSubmitted: (_) {
          submit();
          widget.onSubmitted?.call();
        },
        style: const TextStyle(fontSize: 14),
        decoration: rozDecoration(
          widget.hint == null ? null : context.t(widget.hint!),
        ),
        onChanged: widget.onChanged,
      ),
      optionsViewBuilder: (context, select, options) => _OptionsList<String>(
        options: options.toList(),
        select: select,
        title: (s) => s,
      ),
      onSelected: (v) => widget.onChanged?.call(v),
    ),
  );
}

class _OptionsList<T extends Object> extends StatelessWidget {
  final List<T> options;
  final AutocompleteOnSelected<T> select;
  final String Function(T) title;
  final Widget Function(T)? trailing;
  const _OptionsList({
    required this.options,
    required this.select,
    required this.title,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, i) {
            final highlighted = AutocompleteHighlightedOption.of(context) == i;
            return InkWell(
              onTap: () => select(options[i]),
              child: Container(
                color: highlighted ? rozSoft2 : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title(options[i]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5),
                      ),
                    ),
                    if (trailing != null) trailing!(options[i]),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Who a party field is for. A company and an Udhari party are both kept on
/// the payable side (`ap:`): what you owe them.
enum PartyRole {
  customer,
  company,
  udhari;

  /// The party flag this role sets when an entry is saved for the party.
  String get flag => switch (this) {
    customer => 'customer',
    company => 'supplier',
    udhari => 'udhari',
  };

  bool get payable => this != customer;

  bool fits(Record p) =>
      this == customer ? p.data['customer'] != false : p.data[flag] == true;
}

/// Customer / company typed by name, as in the HTML. A new name creates the
/// party when the entry is saved; the helper line says so before saving.
class PartyInput extends StatefulWidget {
  final AppController app;
  final String label;
  final TextEditingController controller;
  final PartyRole role;
  final ValueChanged<String>? onChanged;
  final String? hint;
  final FocusNode? focusNode;

  /// Key of the text field, for a form that has a second party field.
  final Key fieldKey;
  const PartyInput({
    required this.app,
    required this.label,
    required this.controller,
    required this.role,
    this.onChanged,
    this.hint,
    this.focusNode,
    this.fieldKey = const ValueKey('roz-party'),
    super.key,
  });
  @override
  State<PartyInput> createState() => _PartyInputState();
}

class _PartyInputState extends State<PartyInput> {
  FocusNode? _own;
  FocusNode get focus => widget.focusNode ?? (_own ??= FocusNode());
  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  bool _fits(Record p) => widget.role.fits(p);

  /// The party's whole khata balance (both sides), read for this role. A
  /// customer you owe money (an opening payable, an advance) shows "Dena",
  /// as on the Parties page.
  String _balance(Record p) {
    final net = widget.app.book.partyBalance(p.id);
    if (widget.role.payable) {
      final v = -net;
      return v == 0
          ? ''
          : v > 0
          ? '${context.t('Dena')} ${money(v)}'
          : '${context.t(widget.role == PartyRole.udhari ? 'Lena' : 'Advance')} ${money(-v)}';
    }
    final v = net;
    return v == 0
        ? ''
        : v > 0
        ? '${context.t('Lena')} ${money(v)}'
        : '${context.t('Dena')} ${money(-v)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text.trim();
    final match = widget.app.partyByName(text);
    String? helper;
    Color? color;
    if (text.isNotEmpty && match == null) {
      helper = context.t(switch (widget.role) {
        PartyRole.company => 'Nayi company banegi',
        PartyRole.udhari => 'Naya udhari khata banega',
        PartyRole.customer => 'Naya customer banega',
      });
      color = amber;
    } else if (match != null) {
      final balance = _balance(match);
      helper = [
        if (match.archived) context.t('Archived'),
        if (balance.isNotEmpty) '${context.t('Baqaya')}: $balance',
      ].join(' · ');
      if (helper.isEmpty) helper = null;
    }
    return Labeled(
      widget.label,
      RawAutocomplete<Record>(
        textEditingController: widget.controller,
        focusNode: focus,
        displayStringForOption: (r) => r.name,
        optionsBuilder: (value) {
          final q = AppController.nameKey(value.text);
          if (q.isEmpty) return const <Record>[];
          final list = widget.app
              .ofKind('party')
              .where(_fits)
              .where(
                (p) =>
                    q.isEmpty ||
                    AppController.nameKey(p.name).contains(q) ||
                    '${p.data['phone'] ?? ''}'.contains(q),
              )
              .toList();
          list.sort((a, b) {
            final sa = AppController.nameKey(a.name).startsWith(q) ? 0 : 1;
            final sb = AppController.nameKey(b.name).startsWith(q) ? 0 : 1;
            return sa != sb ? sa - sb : a.name.compareTo(b.name);
          });
          if (list.length == 1 &&
              AppController.nameKey(list.single.name) == q) {
            return const [];
          }
          return list.take(12);
        },
        fieldViewBuilder: (context, controller, focusNode, submit) => TextField(
          key: widget.fieldKey,
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => submit(),
          style: const TextStyle(fontSize: 14),
          decoration: rozDecoration(
            context.t(widget.hint ?? 'Naam likhein ya list se chunein'),
          ),
          onChanged: (v) {
            setState(() {});
            widget.onChanged?.call(v);
          },
        ),
        optionsViewBuilder: (context, select, options) => _OptionsList<Record>(
          options: options.toList(),
          select: select,
          title: (r) => r.name,
          trailing: (r) => Text(
            _balance(r),
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 11.5, color: muted),
          ),
        ),
        onSelected: (r) {
          setState(() {});
          widget.onChanged?.call(r.name);
        },
      ),
      helper: helper,
      helperColor: color,
    );
  }
}

String accountLabel(Record a) {
  final bank = '${a.data['bank'] ?? ''}'.trim();
  return bank.isEmpty ||
          AppController.nameKey(a.name).contains(AppController.nameKey(bank))
      ? a.name
      : '${a.name} · $bank';
}

/// Bank / personal account picker with "+ new account", like the HTML
/// "Naya Bank..." option.
class AccountPicker extends StatelessWidget {
  final AppController app;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? helper;

  /// Choices listed after the accounts (value, label), such as Direct to
  /// Party on the Wasooli form.
  final List<(String, String)> extra;
  const AccountPicker({
    required this.app,
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.extra = const [],
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final accounts = app
        .ofKind('account')
        .where((a) => a.id != 'cash')
        .toList();
    if (value.isNotEmpty &&
        !accounts.any((a) => a.id == value) &&
        app.record(value) != null) {
      accounts.add(app.record(value)!);
    }
    return Labeled(
      label,
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('acc-$label-${accounts.length}'),
              initialValue: accounts.any((a) => a.id == value) ? value : null,
              isExpanded: true,
              isDense: true,
              decoration: rozDecoration(context.t('Account chunein')),
              items: [
                for (final a in accounts)
                  DropdownMenuItem(
                    value: a.id,
                    child: Text(
                      a.id == 'cash'
                          ? context.t('Cash (haath ki cash)')
                          : accountLabel(a),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                for (final (id, text) in extra)
                  DropdownMenuItem(
                    value: id,
                    child: Text(
                      context.t(text),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: amber,
                      ),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: context.t('Naya account'),
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              final id = uuid.v4();
              await editMaster(context, app, 'account', newId: id);
              if (app.record(id) != null) onChanged(id);
            },
            icon: const Icon(Icons.add_card_outlined, size: 20, color: teal),
          ),
        ],
      ),
      helper: helper,
    );
  }
}

/// A small dropdown with label above (Cash / Bank, Less kaise?, Kis ka?).
class RozSelect extends StatelessWidget {
  final String label;
  final String value;
  final List<(String, String)> options;
  final ValueChanged<String> onChanged;
  const RozSelect(
    this.label,
    this.value,
    this.options,
    this.onChanged, {
    super.key,
  });
  @override
  Widget build(BuildContext context) => Labeled(
    label,
    DropdownButtonFormField<String>(
      initialValue: options.any((o) => o.$1 == value) ? value : null,
      isExpanded: true,
      isDense: true,
      decoration: rozDecoration(null),
      items: [
        for (final o in options)
          DropdownMenuItem(
            value: o.$1,
            child: Text(
              context.t(o.$2),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );
}

/// "Pakka?" confirmation (HTML confirm modal: Nahi / Haan).
Future<bool> confirmPlain(BuildContext context, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Pakka?')),
        content: SizedBox(
          width: 400,
          child: Text(
            ctx.t(message),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.t('Nahi')),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.t('Haan')),
          ),
        ],
      ),
    ) ==
    true;

/// "Pakka?" confirmation that also collects the audit reason.
Future<String?> confirmReason(
  BuildContext context,
  String message, {
  String confirm = 'Haan, delete',
  String? initial,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _ReasonDialog(message: message, confirm: confirm, initial: initial),
);

class _ReasonDialog extends StatefulWidget {
  final String message, confirm;
  final String? initial;
  const _ReasonDialog({
    required this.message,
    required this.confirm,
    this.initial,
  });
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  late final field = TextEditingController(text: widget.initial ?? '');
  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  void _done() {
    if (field.text.trim().isNotEmpty) Navigator.pop(context, field.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.t('Pakka?')),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(widget.message),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: field,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.t('Wajah (zaroori)'),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _done(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.t('Nahi')),
      ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: rozRed),
        onPressed: field.text.trim().isEmpty ? null : _done,
        child: Text(context.t(widget.confirm)),
      ),
    ],
  );
}

/// Error text shown to the user, without exception prefixes.
String errorText(BuildContext context, Object e) => context.t(
  e.toString().replaceFirst(
    RegExp(r'^(FormatException: |Bad state: |Exception: )'),
    '',
  ),
);
