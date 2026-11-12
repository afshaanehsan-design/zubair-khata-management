// The Money page: archiving, reconciliation, the top-bar date, bank-to-bank
// transfers and clickable balance cards.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/components.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';

String dayBefore(String date) =>
    DateTime.parse(date)
        .subtract(const Duration(days: 1))
        .toIso8601String()
        .substring(0, 10);

/// The app on the Money page with Cash Rs 111,000 and Faisal (Alfalah)
/// Rs 129,600, both entered as opening balances yesterday.
Future<(AppController, KhataDatabase)> openMoney(WidgetTester tester) async {
  await initializeDateFormatting('en');
  tester.view.physicalSize = const Size(1440, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  final today = app.selectedDate;
  app.setDate(dayBefore(today));
  await app.post({
    'type': 'adjustment',
    'date': app.selectedDate,
    'target': 'money:cash',
    'amount': 11100000,
    'note': 'Opening',
    'occurredAt': 0,
  });
  await app.saveMaster('account', {
    'name': 'Faisal',
    'bank': 'Alfalah',
  }, opening: 12960000);
  app.setDate(today);
  await tester.pumpWidget(KhataApp(app));
  await tester.pumpAndSettle();
  app.go('money');
  await tester.pumpAndSettle();
  return (app, db);
}

Future<void> close(
  WidgetTester tester,
  AppController app,
  KhataDatabase db,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  app.dispose();
  await db.close();
}

/// Lets a closing dialog finish, then waits past the short delay a text
/// dialog keeps before it hands back its answer.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Lets messages at the bottom of the screen time out.
Future<void> clearMessages(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

/// Picks [item] from the ••• menu of an account row.
Future<void> choose(WidgetTester tester, String account, String item) async {
  await tester.tap(
    find.descendant(
      of: find.ancestor(
        of: find.text(account),
        matching: find.byType(ListTile),
      ),
      matching: find.byIcon(Icons.more_horiz),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Archive needs Rs 0, asks first, and can be undone', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);
    final faisal = app.ofKind('account').firstWhere((a) => a.name == 'Faisal');

    // Money in the account: refused, so no money disappears from the page.
    await choose(tester, 'Faisal', 'Archive');
    expect(find.textContaining('Faisal still has Rs 129,600'), findsOneWidget);
    expect(find.text('Pakka?'), findsNothing);
    expect(app.record(faisal.id)!.archived, isFalse);
    await clearMessages(tester);

    await app.saveMaster('account', {'name': 'Old HBL', 'bank': 'HBL'});
    await tester.pumpAndSettle();
    final old = app.ofKind('account').firstWhere((a) => a.name == 'Old HBL');

    // An empty account: asks first, and "Nahi" keeps it.
    await choose(tester, 'Old HBL', 'Archive');
    expect(find.text('Pakka?'), findsOneWidget);
    await tester.tap(find.text('Nahi'));
    await tester.pumpAndSettle();
    expect(app.record(old.id)!.archived, isFalse);

    await choose(tester, 'Old HBL', 'Archive');
    await tester.tap(find.text('Haan'));
    await tester.pumpAndSettle();
    expect(app.record(old.id)!.archived, isTrue);
    expect(find.text('Account archived'), findsOneWidget);
    expect(find.text('Old HBL'), findsNothing);

    // It is listed under Archived and comes back with Restore.
    await tester.tap(find.text('Archived (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Old HBL'), findsOneWidget);
    await choose(tester, 'Old HBL', 'Restore');
    expect(app.record(old.id)!.archived, isFalse);
    expect(find.text('Archived (1)'), findsNothing);
    expect(find.text('Old HBL'), findsNWidgets(2)); // card and row
    await close(tester, app, db);
  });

  testWidgets('Reconciliation saves only a confirmed difference', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);
    int corrections() => app.book.documents
        .where(
          (d) =>
              d.type == EntryType.adjustment &&
              d.data['target'] == 'money:cash',
        )
        .length;
    final before = corrections();

    Future<void> count(String value) async {
      await choose(tester, 'Cash', 'Account reconciliation');
      expect(find.text('111000.00'), findsOneWidget); // the app's balance
      await tester.enterText(find.byType(TextField).last, value);
      await tester.tap(find.text('Confirm'));
      await settle(tester);
    }

    // The count matches: nothing to save.
    await count('111000');
    expect(find.text('Balance matches. Nothing to correct.'), findsOneWidget);
    expect(corrections(), before);
    await clearMessages(tester);

    // Cancelling the reason saves nothing and does not say "Saved".
    await count('110500');
    expect(find.text('Reason for correction (-Rs 500)'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text('Saved'), findsNothing);
    expect(corrections(), before);

    // A confirmed difference is saved as a correction.
    await count('110500');
    await tester.enterText(find.byType(TextField).last, 'Drawer counted');
    await tester.tap(find.text('Confirm'));
    await settle(tester);
    expect(find.text('Saved'), findsOneWidget);
    expect(corrections(), before + 1);
    expect(app.book.money('cash'), 11050000);
    await close(tester, app, db);
  });

  testWidgets('Every number follows the top-bar date', (tester) async {
    final (app, db) = await openMoney(tester);
    final today = app.selectedDate, yesterday = dayBefore(today);
    await app.saveMaster('party', {'name': 'Ali'});
    await app.post({
      'type': 'receipt',
      'date': today,
      'party': app.partyByName('Ali')!.id,
      'cash': 100000,
    });
    await tester.pumpAndSettle();

    // Today: the latest balance and today's change, with no stray "·".
    expect(find.text('Rs 112,000'), findsNWidgets(2)); // card and row
    expect(find.text('Change today: +Rs 1,000'), findsOneWidget);
    expect(find.text('Alfalah · Change today: Rs 0'), findsOneWidget);
    expect(find.textContaining('not today'), findsNothing);

    // Yesterday: balances at the end of yesterday, labelled with its date.
    app.setDate(yesterday);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, yesterday), findsOneWidget);
    expect(find.text('Rs 111,000'), findsNWidgets(2));
    expect(find.text('Change on $yesterday: +Rs 111,000'), findsOneWidget);
    expect(
      find.text('These balances are for the end of $yesterday, not today.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Go to today'));
    await tester.pumpAndSettle();
    expect(app.selectedDate, today);
    expect(find.text('Rs 112,000'), findsNWidgets(2));
    await close(tester, app, db);
  });

  testWidgets('Bank se bank transfer offers bank accounts only', (
    tester,
  ) async {
    final (app, db) = await openMoney(tester);

    // One bank account: nothing to transfer between.
    await tester.tap(find.text('Bank se bank transfer'));
    await tester.pumpAndSettle();
    expect(
      find.text('Add a second bank account to transfer between banks.'),
      findsOneWidget,
    );
    expect(find.byType(EntryComposer), findsNothing);

    await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank se bank transfer'));
    await tester.pumpAndSettle();
    expect(find.byType(EntryComposer), findsOneWidget);
    final banks = [
      for (final a in app.ofKind('account'))
        if (a.id != 'cash') a.id,
    ];
    for (final label in ['From account', 'To account']) {
      final dropdown = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(DropdownButtonFormField<String>),
          ),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(dropdown.value, isNull, reason: '$label starts empty, not Cash');
      expect([
        for (final i in dropdown.items!) i.value,
      ], unorderedEquals(banks));
    }
    await close(tester, app, db);
  });

  testWidgets('Only clickable cards show the arrow', (tester) async {
    final (app, db) = await openMoney(tester);
    final arrows = find.descendant(
      of: find.byType(Metric),
      matching: find.byIcon(Icons.north_east_rounded),
    );
    // Cash and Faisal: each card opens its statement.
    expect(arrows, findsNWidgets(2));
    for (final card in tester.widgetList<Metric>(find.byType(Metric))) {
      expect(card.onTap, isNotNull);
    }
    app.go('stock');
    await tester.pumpAndSettle();
    expect(find.byType(Metric), findsWidgets);
    expect(arrows, findsNothing);
    await close(tester, app, db);
  });
}
