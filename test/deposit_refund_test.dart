// A refundable deposit (taken with a sale or on its own) can be paid back
// from the party's details.
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

void main() {
  testWidgets('A party holding a deposit can be paid it back', (tester) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    await app.saveMaster('party', {'name': 'Ali', 'customer': true});
    await app.saveMaster('party', {'name': 'Bilal', 'customer': true});
    final ali = app.partyByName('Ali')!, bilal = app.partyByName('Bilal')!;
    await app.post({
      'type': 'deposit',
      'date': app.selectedDate,
      'party': ali.id,
      'amount': 300000,
      'account': 'cash',
    });
    expect(app.book.deposits(ali.id), 300000);
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    BuildContext ctx() => tester.element(find.byType(Workspace));
    final refund = find.byKey(const ValueKey('party-deposit-refund'));

    unawaited(showParty(ctx(), app, ali));
    await tester.pumpAndSettle();
    expect(refund, findsOneWidget);
    await tester.tap(refund);
    await tester.pumpAndSettle();
    expect(find.byType(EntryComposer), findsOneWidget);
    expect(inComposer(find.text('Ali')), findsOneWidget);
    final amount = inComposer(find.byKey(const ValueKey('field-amount')));

    // More than the deposit held is refused and nothing is saved.
    await tester.enterText(amount, '5000');
    await tester.tap(inComposer(find.text('Save')));
    await tester.pumpAndSettle();
    expect(find.text('Refund exceeds the refundable deposit'), findsOneWidget);
    expect(app.book.deposits(ali.id), 300000);

    await tester.enterText(amount, '1000');
    await tester.tap(inComposer(find.text('Save')));
    await tester.pumpAndSettle();
    expect(app.book.deposits(ali.id), 200000);
    final paid = app.book.documents.singleWhere(
      (d) => d.type == EntryType.depositRefund,
    );
    expect(paid.party, ali.id);
    expect(paid.account, 'cash');
    expect(paid.value('amount'), 100000);
    expect(app.book.money('cash'), 200000);
    Navigator.of(ctx(), rootNavigator: true).popUntil((r) => r.isFirst);
    await tester.pumpAndSettle();

    // A party without a deposit has nothing to refund.
    unawaited(showParty(ctx(), app, bilal));
    await tester.pumpAndSettle();
    expect(refund, findsNothing);
    Navigator.of(ctx(), rootNavigator: true).popUntil((r) => r.isFirst);
    await tester.pumpAndSettle();

    // A refund begun for Ali and left unsaved does not carry Ali into a
    // refund opened for someone else.
    unawaited(
      composeEntry(ctx(), app, type: EntryType.depositRefund, party: ali.id),
    );
    await tester.pumpAndSettle();
    await tester.enterText(amount, '500');
    await tester.tap(inComposer(find.text('Cancel')));
    await tester.pumpAndSettle();
    unawaited(
      composeEntry(ctx(), app, type: EntryType.depositRefund, party: bilal.id),
    );
    await tester.pumpAndSettle();
    expect(inComposer(find.text('Bilal')), findsOneWidget);
    expect(inComposer(find.text('Ali')), findsNothing);
    expect(tester.widget<TextField>(amount).controller!.text, isEmpty);
    await tester.tap(inComposer(find.text('Cancel')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });
}
