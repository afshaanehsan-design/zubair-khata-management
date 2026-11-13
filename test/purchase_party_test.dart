// A purchase is bought from a company: its party list starts with companies
// only, a party bought from is marked as a company, and a company's page
// opens a purchase with the company filled in.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/details.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';

Finder inComposer(Finder f) =>
    find.descendant(of: find.byType(EntryComposer), matching: f);

Finder inPicker(Finder f) =>
    find.descendant(of: find.byType(AlertDialog), matching: f);

Future<(KhataDatabase, AppController)> open() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  await app.saveMaster('party', {'name': 'Kashif', 'customer': true});
  await app.saveMaster('party', {
    'name': 'Supreme',
    'customer': false,
    'supplier': true,
  });
  return (db, app);
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  testWidgets('The purchase party list starts with companies only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (db, app) = await open();
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    BuildContext ctx() => tester.element(find.byType(Workspace));

    unawaited(composeEntry(ctx(), app, type: EntryType.purchase));
    await tester.pumpAndSettle();
    await tester.tap(inComposer(find.text('Choose a party')));
    await tester.pumpAndSettle();
    expect(inPicker(find.text('Choose a company')), findsOneWidget);
    expect(inPicker(find.text('Supreme')), findsOneWidget);
    expect(inPicker(find.text('Kashif')), findsNothing);

    // A supplier never marked as a company can still be chosen.
    await tester.tap(find.byKey(const ValueKey('pick-show-all')));
    await tester.pumpAndSettle();
    expect(inPicker(find.text('Choose a party')), findsOneWidget);
    expect(inPicker(find.text('Kashif')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-show-all')));
    await tester.pumpAndSettle();
    await tester.enterText(inPicker(find.byType(TextField)), 'kas');
    await tester.pumpAndSettle();
    expect(inPicker(find.text('No company found')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-show-all')));
    await tester.pumpAndSettle();
    await tester.tap(inPicker(find.text('Kashif')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(inComposer(find.text('Kashif')), findsOneWidget);

    // Saving the purchase marks Kashif as a company, still a customer too.
    await tester.enterText(
      inComposer(find.byKey(const ValueKey('field-grams'))),
      '100',
    );
    await tester.enterText(
      inComposer(find.byKey(const ValueKey('field-rate'))),
      '250',
    );
    await tester.pumpAndSettle();
    await tester.tap(inComposer(find.text('Save')));
    await tester.pumpAndSettle();
    expect(find.byType(EntryComposer), findsNothing);
    final kashif = app.partyByName('Kashif')!;
    expect(kashif.data['supplier'], true);
    expect(kashif.data['customer'], true);
    final purchase = app.book.documents.single;
    expect(purchase.type, EntryType.purchase);
    expect(purchase.party, kashif.id);
    expect(purchase.value('grams'), 100000);

    // A purchase from a party already a company changes no party.
    final supreme = app.partyByName('Supreme')!;
    unawaited(composeEntry(ctx(), app, type: EntryType.purchase));
    await tester.pumpAndSettle();
    await tester.tap(inComposer(find.text('Choose a party')));
    await tester.pumpAndSettle();
    await tester.tap(inPicker(find.text('Supreme')));
    await tester.pumpAndSettle();
    await tester.enterText(
      inComposer(find.byKey(const ValueKey('field-grams'))),
      '50',
    );
    await tester.enterText(
      inComposer(find.byKey(const ValueKey('field-rate'))),
      '250',
    );
    await tester.pumpAndSettle();
    await tester.tap(inComposer(find.text('Save')));
    await tester.pumpAndSettle();
    expect(app.partyByName('Supreme')!.version, supreme.version);
    expect(app.book.documents, hasLength(2));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });

  testWidgets('A company page opens a purchase for that company', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (db, app) = await open();

    // A customer's page has no Purchase button.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PartyDetails(app, app.partyByName('Kashif')!)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('party-purchase')), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PartyDetails(app, app.partyByName('Supreme')!)),
      ),
    );
    await tester.pumpAndSettle();
    final purchase = find.byKey(const ValueKey('party-purchase'));
    expect(
      find.descendant(of: purchase, matching: find.text('Purchase')),
      findsOneWidget,
    );
    await tester.tap(purchase);
    await tester.pumpAndSettle();
    expect(find.byType(EntryComposer), findsOneWidget);
    expect(inComposer(find.text('Supreme')), findsOneWidget);
    expect(inComposer(find.text('Choose a party')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });
}
