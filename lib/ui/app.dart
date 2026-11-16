import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/controller.dart';
import '../core/organizations.dart';
import 'components.dart';
import 'entry_composer.dart';
import 'organizations_ui.dart';
import 'pages.dart';
import 'reports_page.dart';
import 'roznamcha_page.dart';
import 'settings_page.dart';

const destinations = [
  ('roznamcha', 'Roznamcha', Icons.menu_book_outlined),
  ('activity', 'Activity', Icons.swap_vert_rounded),
  ('parties', 'Parties', Icons.people_outline_rounded),
  ('money', 'Money', Icons.account_balance_wallet_outlined),
  ('stock', 'Stock', Icons.propane_tank_outlined),
  ('reports', 'Reports', Icons.analytics_outlined),
  ('settings', 'Settings', Icons.tune_rounded),
];

/// Shows the open organization. When another one is opened the whole app is
/// built again for it, so no page, dialog or field of the previous
/// organization stays on screen.
class KhataRoot extends StatelessWidget {
  final Organizations organizations;
  const KhataRoot(this.organizations, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: organizations,
    builder: (context, _) {
      if (!organizations.switching && organizations.ready) {
        return KhataApp(
          organizations.app,
          key: ValueKey(organizations.current.id),
        );
      }
      final failure = organizations.failure;
      return failure == null || organizations.switching
          ? const ColoredBox(color: paper)
          : MaterialApp(home: CouldNotOpen(failure));
    },
  );
}

/// Shown instead of the app when the records cannot be opened.
class CouldNotOpen extends StatelessWidget {
  final String error;
  const CouldNotOpen(this.error, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: SelectableText(
          'Could not open your records. Your database has not been deleted.\n\n$error',
        ),
      ),
    ),
  );
}

class KhataApp extends StatelessWidget {
  final AppController app;
  const KhataApp(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (ctx, _) => MaterialApp(
        title: 'Zubair Khata',
        debugShowCheckedModeBanner: false,
        // The only route. The Android sign-in link is handled by
        // supabase_flutter alone (flutter_deeplinking_enabled is off in
        // AndroidManifest.xml), so no route name other than "/" arrives.
        home: Workspace(app),
        locale: Locale(app.language),
        supportedLocales: const [Locale('en'), Locale('ur')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: paper,
          fontFamily: app.urdu ? 'NotoUrdu' : 'Manrope',
          fontFamilyFallback: const ['NotoUrdu'],
          colorScheme: ColorScheme.fromSeed(
            seedColor: teal,
            primary: teal,
            secondary: const Color(0xffa26d26),
            surface: Colors.white,
            onSurface: ink,
          ),
          textTheme: ThemeData.light().textTheme
              .apply(bodyColor: ink, displayColor: ink)
              .apply(fontFamily: app.urdu ? 'NotoUrdu' : 'Manrope'),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 17,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xffdce4d8)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xffdce4d8)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: teal, width: 1.5),
            ),
            labelStyle: const TextStyle(color: muted, fontSize: 13),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: TextStyle(
                fontWeight: FontWeight.w600,
                fontFamily: app.urdu ? 'NotoUrdu' : 'Manrope',
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 17),
              side: const BorderSide(color: Color(0xffdce4d8)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          chipTheme: ChipThemeData(
            side: const BorderSide(color: Color(0xffdde5d7)),
            selectedColor: const Color(0xffdcebdd),
            backgroundColor: Colors.white,
            checkmarkColor: teal,
            // A label style without colour/font is painted white by the
            // text engine, which made every filter chip label invisible.
            labelStyle: TextStyle(
              fontSize: 12,
              fontFamily: app.urdu ? 'NotoUrdu' : 'Manrope',
              fontFamilyFallback: const ['NotoUrdu'],
              color: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected) ? teal : ink,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          ),
          dividerTheme: const DividerThemeData(color: Color(0xffe6eae1)),
          appBarTheme: const AppBarTheme(
            backgroundColor: paper,
            surfaceTintColor: Colors.transparent,
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class Workspace extends StatefulWidget {
  final AppController app;
  const Workspace(this.app, {super.key});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  late final TextEditingController searchField;
  @override
  void initState() {
    super.initState();
    searchField = TextEditingController(text: widget.app.search);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    searchField.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(widget.app.syncNow());
  }

  // The top bar and the page redraw whenever the data, the chosen page or
  // date, or the search text change.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) => _workspace(context),
  );

  Widget _workspace(BuildContext context) {
    final app = widget.app, size = MediaQuery.sizeOf(context);
    final section = destinations.indexWhere((d) => d.$1 == app.page);
    final desktop = size.width >= 850, rail = size.width >= 1150;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            NewEntryIntent(),
      },
      child: Actions(
        actions: {
          NewEntryIntent: CallbackAction<NewEntryIntent>(
            onInvoke: (_) {
              composeEntry(context, app);
              return null;
            },
          ),
        },
        child: Scaffold(
          body: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (desktop)
                  Container(
                    width: rail ? 228 : 84,
                    color: ink,
                    // Scrolls when the window is too short for every item.
                    child: LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: box.maxHeight),
                          child: IntrinsicHeight(
                            child: Column(
                              children: [
                                Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    rail ? 22 : 16,
                                    28,
                                    rail ? 18 : 16,
                                    30,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 43,
                                        height: 43,
                                        decoration: BoxDecoration(
                                          color: const Color(0xffd8e9b8),
                                          borderRadius: BorderRadius.circular(
                                            13,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.auto_stories_rounded,
                                          color: ink,
                                          size: 25,
                                        ),
                                      ),
                                      if (rail) ...[
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                context.t('Zubair Khata'),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                context.t(
                                                  'Business, in balance.',
                                                ),
                                                style: const TextStyle(
                                                  color: Color(0xff9eb7a8),
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                for (
                                  var index = 0;
                                  index < destinations.length;
                                  index++
                                )
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: rail ? 14 : 12,
                                      vertical: 4,
                                    ),
                                    child: Tooltip(
                                      message: context.t(
                                        destinations[index].$2,
                                      ),
                                      child: Material(
                                        color: section == index
                                            ? const Color(0xff31584a)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(12),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          onTap: () =>
                                              app.go(destinations[index].$1),
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: rail ? 14 : 16,
                                              vertical: 15,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  destinations[index].$3,
                                                  size: 21,
                                                  color: section == index
                                                      ? const Color(0xffdcebbd)
                                                      : const Color(0xff9fb7ab),
                                                ),
                                                if (rail) ...[
                                                  const SizedBox(width: 13),
                                                  Expanded(
                                                    child: Text(
                                                      context.t(
                                                        destinations[index].$2,
                                                      ),
                                                      style: TextStyle(
                                                        color: section == index
                                                            ? Colors.white
                                                            : const Color(
                                                                0xffadbfaf,
                                                              ),
                                                        fontWeight:
                                                            section == index
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                const Spacer(),
                                // The open organization. Tapping it lists the
                                // organizations on this device.
                                if (rail)
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Material(
                                      color: Colors.white.withValues(
                                        alpha: .05,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: app.organizations == null
                                            ? null
                                            : () => showOrganizations(
                                                context,
                                                app,
                                              ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: Row(
                                            children: [
                                              const CircleAvatar(
                                                radius: 16,
                                                backgroundColor: Color(
                                                  0xffd8e9b8,
                                                ),
                                                child: Icon(
                                                  Icons.person_outline,
                                                  size: 18,
                                                  color: ink,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      app.businessName,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                    Text(
                                                      'PKR · Asia/Karachi',
                                                      style: const TextStyle(
                                                        color: Color(
                                                          0xff9eb7a8,
                                                        ),
                                                        fontSize: 9,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (app.organizations != null)
                                                const Icon(
                                                  Icons.unfold_more_rounded,
                                                  size: 18,
                                                  color: Color(0xff9fb7ab),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                else if (app.organizations != null)
                                  IconButton(
                                    tooltip:
                                        '${context.t('Organizations')}: ${app.businessName}',
                                    onPressed: () =>
                                        showOrganizations(context, app),
                                    icon: const Icon(
                                      Icons.business_outlined,
                                      color: Color(0xff9fb7ab),
                                    ),
                                  ),
                                const SizedBox(height: 12),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: desktop ? 32 : 16,
                          vertical: 15,
                        ),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          border: Border(
                            bottom: BorderSide(color: Color(0xffe4e8df)),
                          ),
                        ),
                        child: Row(
                          children: [
                            if (size.width > 660)
                              Expanded(
                                child: SizedBox(
                                  height: 44,
                                  child: TextField(
                                    controller: searchField,
                                    onChanged: app.setSearch,
                                    onSubmitted: (_) {
                                      if (section != 1 && section != 2) {
                                        app.go('activity');
                                      }
                                    },
                                    decoration: InputDecoration(
                                      prefixIcon: const Icon(
                                        Icons.search,
                                        size: 21,
                                        color: muted,
                                      ),
                                      suffixIcon: searchField.text.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: context.t(
                                                'Clear search',
                                              ),
                                              icon: const Icon(
                                                Icons.close_rounded,
                                                size: 19,
                                                color: muted,
                                              ),
                                              onPressed: () {
                                                searchField.clear();
                                                app.setSearch('');
                                              },
                                            ),
                                      hintText: context.t(
                                        'Search transactions, parties…',
                                      ),
                                      hintStyle: const TextStyle(fontSize: 12),
                                      filled: true,
                                      fillColor: paper,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else ...[
                              const Icon(
                                Icons.auto_stories_outlined,
                                color: teal,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  context.t('Zubair Khata'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: 12),
                            if (size.width > 1050)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: 12,
                                ),
                                child: InkWell(
                                  onTap: () => app.syncNow(),
                                  child: Row(
                                    children: [
                                      Icon(
                                        app.sync?.running == true
                                            ? Icons.sync
                                            : app.signedIn
                                            ? Icons.cloud_done_outlined
                                            : Icons.cloud_off_outlined,
                                        size: 16,
                                        color: teal,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        context.t(app.syncMessage),
                                        style: const TextStyle(
                                          color: muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                      if (app.cloudLinked &&
                                          app.pendingCount > 0)
                                        Padding(
                                          padding:
                                              const EdgeInsetsDirectional.only(
                                                start: 5,
                                              ),
                                          child: Tag(
                                            '${app.pendingCount}',
                                            key: const ValueKey(
                                              'pending-count',
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 12,
                                ),
                              ),
                              onPressed: () async {
                                final date = await pickDate(
                                  context,
                                  app.selectedDate,
                                );
                                if (date != null) app.setDate(date);
                              },
                              icon: const Icon(
                                Icons.calendar_today_outlined,
                                size: 15,
                              ),
                              label: Text(
                                app.selectedDate,
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            const SizedBox(width: 5),
                            IconButton(
                              tooltip: app.urdu ? 'English' : 'اردو',
                              onPressed: () =>
                                  app.setLanguage(app.urdu ? 'en' : 'ur'),
                              icon: Text(
                                app.urdu ? 'EN' : 'اردو',
                                style: const TextStyle(
                                  color: teal,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (desktop)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 12,
                                ),
                                child: FilledButton.icon(
                                  onPressed: () => composeEntry(context, app),
                                  icon: const Icon(Icons.add, size: 18),
                                  label: Text(context.t('New entry')),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        // The Parties page scrolls its list and the chosen
                        // party's details separately, so it gets the height
                        // instead of the shared scroll view.
                        child: section == 2
                            ? Padding(
                                padding: EdgeInsets.fromLTRB(
                                  desktop ? 32 : 16,
                                  28,
                                  desktop ? 32 : 16,
                                  0,
                                ),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1520,
                                    ),
                                    child: SizedBox.expand(
                                      child: PartiesPage(app),
                                    ),
                                  ),
                                ),
                              )
                            : SingleChildScrollView(
                                // A new page starts at the top.
                                key: ValueKey(section),
                                padding: EdgeInsets.fromLTRB(
                                  desktop ? 32 : 16,
                                  28,
                                  desktop ? 32 : 16,
                                  100,
                                ),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1520,
                                    ),
                                    child: switch (section) {
                                      0 => RoznamchaPage(app),
                                      1 => ActivityPage(app),
                                      3 => MoneyPage(app),
                                      4 => StockPage(app),
                                      5 => ReportsPage(app),
                                      _ => SettingsPage(app),
                                    },
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: desktop
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => composeEntry(context, app),
                  backgroundColor: teal,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.add),
                  label: Text(context.t('New entry')),
                ),
          bottomNavigationBar: desktop
              ? null
              : NavigationBar(
                  selectedIndex: section < 4 ? section : 4,
                  onDestinationSelected: (i) async {
                    if (i < 4) {
                      app.go(destinations[i].$1);
                    } else {
                      await showModalBottomSheet<void>(
                        context: context,
                        showDragHandle: true,
                        builder: (ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var j = 4; j < destinations.length; j++)
                                ListTile(
                                  leading: Icon(destinations[j].$3),
                                  title: Text(ctx.t(destinations[j].$2)),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    app.go(destinations[j].$1);
                                  },
                                ),
                              if (app.organizations != null)
                                ListTile(
                                  leading: const Icon(Icons.business_outlined),
                                  title: Text(ctx.t('Organizations')),
                                  subtitle: Text(
                                    app.businessName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    showOrganizations(context, app);
                                  },
                                ),
                              ListTile(
                                leading: const Icon(Icons.search),
                                title: Text(ctx.t('Search')),
                                onTap: () async {
                                  Navigator.pop(ctx);
                                  final value = await askText(
                                    context,
                                    'Search',
                                    initial: app.search,
                                    required: false,
                                  );
                                  if (value != null) app.setSearch(value);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                  },
                  destinations: [
                    for (var i = 0; i < 4; i++)
                      NavigationDestination(
                        icon: Icon(destinations[i].$3),
                        label: context.t(destinations[i].$2),
                      ),
                    NavigationDestination(
                      icon: const Icon(Icons.grid_view_rounded),
                      label: context.t('More'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class NewEntryIntent extends Intent {
  const NewEntryIntent();
}
