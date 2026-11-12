// Deleting a party: only while it has no live entries, hidden everywhere
// afterwards, its name free again, and the icon in the party dialog.
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
import 'package:zubair_khata_management/ui/pages.dart';

Future<(AppController, KhataDatabase)> open() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

Document entryOf(AppController app, String party) => Document(
  app.records.firstWhere(
    (r) => r.kind == 'document' && r.data['party'] == party,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'A party without entries is deleted, hidden and its name is free',
    () async {
      final (app, db) = await open();
      await app.saveMaster('party', {'name': 'Mian Tariq', 'customer': true});
      final tariq = app.partyByName('Mian Tariq')!;
      expect(app.partyHasEntries(tariq.id), isFalse);

      await app.deleteParty(tariq);

      expect(app.record(tariq.id)!.deleted, isTrue, reason: 'row is kept');
      expect(app.ofKind('party'), isEmpty);
      expect(app.ofKind('party', archived: true), isEmpty);
      expect(app.partyByName('Mian Tariq'), isNull);

      // Still gone after the app reads its records again.
      await app.reload();
      expect(app.ofKind('party', archived: true), isEmpty);

      // The same name can be used again, as a new party.
      await app.saveMaster('party', {'name': 'mian  tariq', 'customer': true});
      final again = app.partyByName('Mian Tariq')!;
      expect(again.id, isNot(tariq.id));
      expect(app.ofKind('party').map((p) => p.id), [again.id]);

      app.dispose();
      await db.close();
    },
  );

  test(
    'A party with entries cannot be deleted until they are voided',
    () async {
      final (app, db) = await open();
      await app.saveMaster('party', {
        'name': 'Ali Raza',
        'customer': true,
      }, opening: 500000);
      final ali = app.partyByName('Ali Raza')!;
      await app.post({
        'type': 'receipt',
        'date': app.selectedDate,
        'party': ali.id,
        'cash': 100000,
      });
      expect(app.partyHasEntries(ali.id), isTrue);
      await expectLater(app.deleteParty(ali), throwsA(isA<FormatException>()));
      expect(app.record(ali.id)!.deleted, isFalse);

      // A voided entry no longer counts; the opening balance is an entry too.
      final receipt = app.records.firstWhere(
        (r) => r.kind == 'document' && r.data['type'] == 'receipt',
      );
      await app.voidDocument(Document(receipt), 'Wrong customer');
      expect(app.partyHasEntries(ali.id), isTrue, reason: 'opening balance');
      final opening = app.records.firstWhere(
        (r) =>
            r.kind == 'document' &&
            r.data['voided'] != true &&
            r.data['party'] == ali.id,
      );
      await app.voidDocument(Document(opening), 'Entered by mistake');
      expect(app.partyHasEntries(ali.id), isFalse);

      await app.deleteParty(app.record(ali.id)!);
      expect(app.ofKind('party'), isEmpty);

      app.dispose();
      await db.close();
    },
  );

  test('A deleted party takes no new entries and cannot come back', () async {
    final (app, db) = await open();
    await app.saveMaster('party', {'name': 'Mian Tariq', 'customer': true});
    final tariq = app.partyByName('Mian Tariq')!;
    await app.deleteParty(tariq);

    await expectLater(
      app.post({
        'type': 'receipt',
        'date': app.selectedDate,
        'party': tariq.id,
        'cash': 100000,
      }),
      throwsA(isA<FormatException>()),
    );
    expect(app.partyHasEntries(tariq.id), isFalse);

    final deleted = app.record(tariq.id)!;
    await expectLater(
      app.saveMaster('party', {
        ...deleted.data,
        'deleted': false,
      }, existing: deleted),
      throwsA(isA<FormatException>()),
    );
    expect(app.record(tariq.id)!.deleted, isTrue);

    // Only parties can be deleted.
    final cash = app.record('cash')!;
    await expectLater(
      app.commit([
        Change('cash', 'account', {
          ...cash.data,
          'deleted': true,
        }, cash.version),
      ]),
      throwsA(isA<FormatException>()),
    );

    app.dispose();
    await db.close();
  });

  group('Party dialog', () {
    Future<(AppController, KhataDatabase, BuildContext Function())> show(
      WidgetTester tester,
    ) async {
      await initializeDateFormatting('en');
      tester.view.physicalSize = const Size(1366, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (app, db) = await open();
      await app.saveMaster('party', {'name': 'Mian Tariq', 'customer': true});
      await app.saveMaster('party', {
        'name': 'Ali Raza',
        'customer': true,
      }, opening: 500000);
      await tester.pumpWidget(KhataApp(app));
      await tester.pumpAndSettle();
      BuildContext ctx() => tester.element(find.byType(Workspace));
      app.go('parties');
      await tester.pumpAndSettle();
      return (app, db, ctx);
    }

    // Scoped to the dialog: on a wide screen the Parties page also shows a
    // party's details (with the same icons) beside the list.
    Finder inDialog(IconData icon) =>
        find.descendant(of: find.byType(Dialog), matching: find.byIcon(icon));
    final bin = inDialog(Icons.delete_outline);

    testWidgets('The bin sits beside Edit and deletes an empty party', (
      tester,
    ) async {
      final (app, db, ctx) = await show(tester);
      final tariq = app.partyByName('Mian Tariq')!;
      unawaited(showParty(ctx(), app, tariq));
      await tester.pumpAndSettle();

      // Same row as the edit icon, just before the close icon.
      final edit = tester.getCenter(inDialog(Icons.edit_outlined));
      final remove = tester.getCenter(bin);
      expect(remove.dy, edit.dy);
      expect(remove.dx, greaterThan(edit.dx));
      expect(remove.dx, lessThan(tester.getCenter(inDialog(Icons.close)).dx));

      await tester.tap(bin);
      await tester.pumpAndSettle();
      expect(find.text('Pakka?'), findsOneWidget);
      await tester.tap(find.text('Haan'));
      await tester.pumpAndSettle();

      expect(app.ofKind('party').map((p) => p.name), ['Ali Raza']);
      expect(find.byType(Dialog), findsNothing, reason: 'dialog closes');
      expect(find.text('Party deleted'), findsOneWidget);
      expect(find.text('Mian Tariq'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    });

    testWidgets('Saying no keeps the party', (tester) async {
      final (app, db, ctx) = await show(tester);
      final tariq = app.partyByName('Mian Tariq')!;
      unawaited(showParty(ctx(), app, tariq));
      await tester.pumpAndSettle();

      await tester.tap(bin);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nahi'));
      await tester.pumpAndSettle();

      expect(app.record(tariq.id)!.deleted, isFalse);
      expect(find.text('Mian Tariq'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    });

    testWidgets('A party with entries explains why it stays', (tester) async {
      final (app, db, ctx) = await show(tester);
      final ali = app.partyByName('Ali Raza')!;
      unawaited(showParty(ctx(), app, ali));
      await tester.pumpAndSettle();

      await tester.tap(bin);
      await tester.pumpAndSettle();
      expect(find.text('Pakka?'), findsNothing);
      expect(
        find.textContaining('Ali Raza has entries, so it cannot be deleted'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      expect(app.record(ali.id)!.deleted, isFalse);
      expect(find.byType(Dialog), findsOneWidget, reason: 'party dialog open');
      expect(entryOf(app, ali.id).voided, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    });

    testWidgets('Deleting from the details beside the list keeps the page', (
      tester,
    ) async {
      final (app, db, ctx) = await show(tester);
      Finder pane(Finder f) =>
          find.descendant(of: find.byType(PartyDetails), matching: f);
      // Ali Raza is the newest, so it is shown first; pick Mian Tariq.
      expect(pane(find.text('Ali Raza')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(PartiesPage.listKey),
          matching: find.text('Mian Tariq'),
        ),
      );
      await tester.pumpAndSettle();
      expect(pane(find.text('Mian Tariq')), findsOneWidget);

      await tester.tap(pane(find.byIcon(Icons.delete_outline)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Haan'));
      await tester.pumpAndSettle();

      expect(app.ofKind('party').map((p) => p.name), ['Ali Raza']);
      expect(find.byType(PartiesPage), findsOneWidget, reason: 'still here');
      expect(pane(find.text('Ali Raza')), findsOneWidget);
      expect(find.text('Mian Tariq'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    });
  });
}
