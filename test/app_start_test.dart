// Starting the app and moving between its pages. There is no router: the page
// is `AppController.page`.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/organizations.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/pages.dart';
import 'package:zubair_khata_management/ui/reports_page.dart';
import 'package:zubair_khata_management/ui/roznamcha_page.dart';
import 'package:zubair_khata_management/ui/settings_page.dart';

const pages = <String, Type>{
  'roznamcha': RoznamchaPage,
  'activity': ActivityPage,
  'parties': PartiesPage,
  'money': MoneyPage,
  'stock': StockPage,
  'reports': ReportsPage,
  'settings': SettingsPage,
};

Future<(AppController, KhataDatabase)> start(
  WidgetTester tester, {
  Size size = const Size(1440, 1080),
}) async {
  await initializeDateFormatting('en');
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  await tester.pumpWidget(KhataApp(app));
  await tester.pumpAndSettle();
  return (app, db);
}

Future<void> stop(
  WidgetTester tester,
  AppController app,
  KhataDatabase db,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  app.dispose();
  await db.close();
}

/// The vertical scroll position of a page of the workspace.
ScrollPosition pagePosition(WidgetTester tester, String id) {
  final page = find.byKey(ValueKey(destinations.indexWhere((d) => d.$1 == id)));
  return tester
      .state<ScrollableState>(
        find.descendant(of: page, matching: find.byType(Scrollable)).first,
      )
      .position;
}

void expectOnlyPage(String id) {
  for (final entry in pages.entries) {
    expect(
      find.byType(entry.value),
      entry.key == id ? findsOneWidget : findsNothing,
      reason: '${entry.key} while on $id',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Every destination has a page here', () {
    expect({for (final d in destinations) d.$1}, pages.keys.toSet());
  });

  for (final route in ['/', 'com.zubairtraders.khata://auth']) {
    testWidgets('Opens on the Roznamcha when the launch route is $route', (
      tester,
    ) async {
      // The Android manifest keeps Flutter from routing the sign-in link, but
      // if a platform ever reports it as the launch route, the app must open.
      tester.platformDispatcher.defaultRouteNameTestValue = route;
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      final (app, db) = await start(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Workspace), findsOneWidget);
      expect(app.page, 'roznamcha');
      expectOnlyPage('roznamcha');
      expect(find.text('A: Aamad / Wasooli'), findsOneWidget);
      await stop(tester, app, db);
    });
  }

  testWidgets('app.go shows each page, and a new page starts at the top', (
    tester,
  ) async {
    final (app, db) = await start(tester, size: const Size(1440, 500));
    for (final id in pages.keys) {
      app.go(id);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(app.page, id);
      expectOnlyPage(id);
    }
    // Scroll a long page down, leave it and come back: both pages start at
    // the top, as they did when each page was its own route.
    app.go('roznamcha');
    await tester.pumpAndSettle();
    pagePosition(tester, 'roznamcha').jumpTo(300);
    await tester.pump();
    expect(pagePosition(tester, 'roznamcha').pixels, 300);
    app.go('activity');
    await tester.pumpAndSettle();
    expect(pagePosition(tester, 'activity').pixels, 0);
    app.go('roznamcha');
    await tester.pumpAndSettle();
    expect(pagePosition(tester, 'roznamcha').pixels, 0);
    // Going to the page already shown changes nothing.
    var notified = 0;
    app.addListener(() => notified++);
    app.go('roznamcha');
    expect(notified, 0);
    await stop(tester, app, db);
  });

  testWidgets('The side rail and the search box change the page', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(app.page, 'settings');
    expectOnlyPage('settings');
    // Submitting a search on any other page lists the matches in Activity.
    await tester.enterText(find.byType(TextField).first, 'ali');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.search, 'ali');
    expect(app.page, 'activity');
    expectOnlyPage('activity');
    await stop(tester, app, db);
  });

  testWidgets('Adding and opening organizations rebuilds the app for each', (
    tester,
  ) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1440, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final folder = Directory.systemTemp.createTempSync('khata-start-');
    final orgs = await Organizations.open(
      directory: folder,
      opener: (file) async {
        final db = KhataDatabase(NativeDatabase(file));
        await db.initialize();
        return db;
      },
    );
    addTearDown(() async {
      await orgs.close();
      try {
        folder.deleteSync(recursive: true);
      } catch (_) {}
    });
    await orgs.app.saveMaster('party', {'name': 'First customer'});
    await tester.pumpWidget(KhataRoot(orgs));
    await tester.pumpAndSettle();
    final first = orgs.app;

    // Settings → Switch or add organization → New organization.
    first.go('settings');
    first.setSearch('first');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch or add organization'));
    await tester.pumpAndSettle();
    expect(find.text('Open now'), findsOneWidget);
    await tester.tap(find.text('New organization'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Organization name'),
      'Ali Gas',
    );
    await tester.tap(find.text('Confirm'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(orgs.current.name, 'Ali Gas');
    expect(orgs.app, isNot(first));
    // A fresh app: first page, no search text, nothing of the other khata.
    expect(orgs.app.page, 'roznamcha');
    expect(orgs.app.search, '');
    expectOnlyPage('roznamcha');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Ali Gas'), findsOneWidget); // the side rail card
    expect(orgs.app.ofKind('party'), isEmpty);

    // The side rail card lists them; tapping the other one opens it.
    await tester.tap(find.text('Ali Gas'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Local device'),
      ),
      findsNWidgets(2),
    );
    await tester.tap(find.text(AppController.defaultBusinessName));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(orgs.current.id, Organization.main);
    expect(orgs.app.ofKind('party').single.name, 'First customer');
    expectOnlyPage('roznamcha');

    // Settings → Remove from this device needs the name typed.
    orgs.app.go('settings');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from this device'));
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(FilledButton, 'Remove organization');
    expect(tester.widget<FilledButton>(remove).onPressed, isNull);
    await tester.enterText(
      find.widgetWithText(TextField, 'Type the organization name to confirm'),
      'zubair traders',
    );
    await tester.pump();
    await tester.tap(remove);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(orgs.list.single.name, 'Ali Gas');
    expect(orgs.app.businessName, 'Ali Gas');
    expectOnlyPage('roznamcha');
    // The last organization cannot be removed.
    orgs.app.go('settings');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Remove from this device'),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('The phone bottom bar and its More sheet change the page', (
    tester,
  ) async {
    final (app, db) = await start(tester, size: const Size(390, 844));
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Money'),
      ),
    );
    await tester.pumpAndSettle();
    expect(app.page, 'money');
    expectOnlyPage('money');
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Reports'));
    await tester.pumpAndSettle();
    expect(app.page, 'reports');
    expectOnlyPage('reports');
    await stop(tester, app, db);
  });
}
