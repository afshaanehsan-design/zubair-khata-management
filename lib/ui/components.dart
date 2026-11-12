import 'package:flutter/material.dart';

import '../core/controller.dart';
import '../core/l10n.dart';
import '../core/models.dart';
import '../features/reports/reports.dart';

const teal = Color(0xff126b60),
    ink = Color(0xff183e37),
    muted = Color(0xff71857e),
    paper = Color(0xfff5f6f1),
    amber = Color(0xffad681d),
    danger = Color(0xffa33d3d);

extension Translation on BuildContext {
  Words get words => Words(Localizations.localeOf(this).languageCode == 'ur');
  String t(String key) => words(key);
}

/// Direction for a value shown next to its label: numbers, amounts and Latin
/// text stay left-to-right; text containing Urdu follows the page.
TextDirection valueDirection(BuildContext context, String value) =>
    RegExp(r'[؀-ۿ]').hasMatch(value)
    ? Directionality.of(context)
    : TextDirection.ltr;

/// Shows [message] at the bottom of the screen; red, and longer, when [error].
/// The caller translates the message.
void showMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? const Color(0xffa33d3d) : null,
      duration: Duration(seconds: error ? 7 : 4),
    ),
  );
}

Future<bool> perform(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      showMessage(context, context.t(success));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      final message = e.toString().replaceFirst(
        RegExp(r'^(FormatException: |Bad state: |Exception: )'),
        '',
      );
      showMessage(context, context.t(message), error: true);
    }
    return false;
  }
}

class PageHeading extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> actions;
  const PageHeading(
    this.title,
    this.subtitle, {
    this.actions = const [],
    super.key,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: LayoutBuilder(
      builder: (context, constraints) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: [
          SizedBox(
            width: (constraints.maxWidth - (actions.isEmpty ? 0 : 250))
                .clamp(180, 600)
                .toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t(title),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.7,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  context.t(subtitle),
                  style: const TextStyle(color: muted, fontSize: 14),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    ),
  );
}

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const Panel({
    required this.child,
    this.padding = const EdgeInsets.all(22),
    super.key,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xffe4e9e1)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class Metric extends StatelessWidget {
  final String label, value;
  final String? detail;
  final IconData icon;
  final bool highlighted;

  /// Makes the card clickable. Only clickable cards show the ↗ arrow.
  final VoidCallback? onTap;
  const Metric(
    this.label,
    this.value,
    this.icon, {
    this.detail,
    this.highlighted = false,
    this.onTap,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    Widget content = Padding(
      padding: const EdgeInsets.all(20),
      child: _content(context),
    );
    if (onTap != null) {
      content = InkWell(onTap: onTap, borderRadius: radius, child: content);
    }
    // Ink (not Container) so the click ripple shows on the card colour.
    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: BoxDecoration(
          color: highlighted ? ink : Colors.white,
          borderRadius: radius,
          border: Border.all(
            color: highlighted ? ink : const Color(0xffe4e9e1),
          ),
        ),
        child: content,
      ),
    );
  }

  Widget _content(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: highlighted
                  ? Colors.white.withValues(alpha: .12)
                  : const Color(0xffeff4ee),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 19,
              color: highlighted ? const Color(0xffd9ebbc) : teal,
            ),
          ),
          const Spacer(),
          if (onTap != null)
            Icon(
              Icons.north_east_rounded,
              size: 16,
              color: highlighted ? Colors.white54 : muted,
            ),
        ],
      ),
      const SizedBox(height: 18),
      Text(
        context.t(label),
        style: TextStyle(
          color: highlighted ? Colors.white70 : muted,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(height: 6),
      Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            color: highlighted ? Colors.white : ink,
            letterSpacing: -.7,
          ),
        ),
      ),
      if (detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Text(
            context.t(detail!),
            style: TextStyle(
              fontSize: 11,
              color: highlighted ? Colors.white60 : muted,
            ),
          ),
        ),
    ],
  );
}

class MetricGrid extends StatelessWidget {
  final List<Metric> metrics;
  const MetricGrid(this.metrics, {super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final count = box.maxWidth > 1120
          ? (metrics.length == 6 ? 3 : 4)
          : box.maxWidth > 580
          ? 3
          : box.maxWidth > 330
          ? 2
          : 1;
      return Wrap(
        spacing: 14,
        runSpacing: 14,
        children: metrics
            .map(
              (m) => SizedBox(
                width: (box.maxWidth - (count - 1) * 14) / count,
                child: m,
              ),
            )
            .toList(),
      );
    },
  );
}

class EmptyState extends StatelessWidget {
  final String title, description;
  final Widget? action;
  final IconData icon;
  const EmptyState(
    this.title,
    this.description, {
    this.action,
    this.icon = Icons.auto_stories_outlined,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 12),
    child: Center(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              color: Color(0xffeff4ee),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 32, color: teal),
          ),
          const SizedBox(height: 18),
          Text(
            context.t(title),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.t(description),
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted),
          ),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 18), child: action!),
        ],
      ),
    ),
  );
}

class Tag extends StatelessWidget {
  final String text;
  final bool warning;
  const Tag(this.text, {this.warning = false, super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: warning ? const Color(0xfffff3df) : const Color(0xffeaf3ea),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      context.t(text),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: warning ? amber : teal,
      ),
    ),
  );
}

class Notice extends StatelessWidget {
  final String text;
  final Widget? action;
  const Notice(this.text, {this.action, super.key});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xfffff6e7),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xffeedfbd)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline_rounded, color: amber, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            context.t(text),
            style: const TextStyle(color: Color(0xff855b20), fontSize: 13),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const SectionHeader(this.title, {this.action, super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            context.t(title),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class Amount extends StatelessWidget {
  final int value;
  final bool large;
  const Amount(this.value, {this.large = false, super.key});
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Text(
      'Rs ${money(value)}',
      style: TextStyle(
        fontSize: large ? 22 : 14,
        color: value < 0 ? const Color(0xffa33d3d) : ink,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  bool required = true,
  TextInputType? keyboard,
  String? label,
}) async {
  final field = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t(title)),
      content: TextField(
        controller: field,
        autofocus: true,
        keyboardType: keyboard,
        maxLines: keyboard == null ? 3 : 1,
        decoration: InputDecoration(labelText: ctx.t(label ?? title)),
        onSubmitted: (v) {
          if (!required || v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.t('Cancel')),
        ),
        FilledButton(
          onPressed: () {
            if (!required || field.text.trim().isNotEmpty) {
              Navigator.pop(ctx, field.text.trim());
            }
          },
          child: Text(ctx.t('Confirm')),
        ),
      ],
    ),
  );
  // Dialog route animations can still reference its controller for one frame.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  field.dispose();
  return result;
}

Future<String?> pickDate(BuildContext context, String current) async {
  final date = await showDatePicker(
    context: context,
    initialDate: DateTime.tryParse(current) ?? DateTime.now(),
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );
  return date?.toIso8601String().substring(0, 10);
}

Future<String?> pickRecord(
  BuildContext context,
  AppController app,
  String kind, {
  bool bankOnly = false,
}) async {
  var query = '';
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final list = app
            .ofKind(kind)
            .where(
              (r) =>
                  (!bankOnly || r.id != 'cash') &&
                  '${r.name} ${r.data['phone'] ?? ''}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
            )
            .toList();
        return AlertDialog(
          title: Text(
            ctx.t(kind == 'party' ? 'Choose a party' : 'Choose an account'),
          ),
          content: SizedBox(
            width: 420,
            height: 380,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    labelText: ctx.t('Search'),
                  ),
                  onChanged: (v) => setState(() => query = v),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text(list[i].name),
                      subtitle: Text(
                        '${list[i].data['phone'] ?? list[i].data['bank'] ?? ''}',
                      ),
                      onTap: () => Navigator.pop(ctx, list[i].id),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.t('Cancel')),
            ),
          ],
        );
      },
    ),
  );
}

IconData entryIcon(EntryType type) => switch (type) {
  EntryType.sale => Icons.shopping_bag_outlined,
  EntryType.receipt => Icons.south_west_rounded,
  EntryType.payment => Icons.north_east_rounded,
  EntryType.expense => Icons.receipt_long_outlined,
  EntryType.purchase => Icons.local_shipping_outlined,
  EntryType.transfer => Icons.swap_horiz_rounded,
  EntryType.cylinder ||
  EntryType.stockAdjustment => Icons.propane_tank_outlined,
  _ => Icons.tune_rounded,
};
