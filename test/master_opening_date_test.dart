// The date of the opening balance asked for when a party or account is added.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/masters.dart';

Future<(AppController, KhataDatabase)> open() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

/// The opening-balance entries made for [target] (a posting key).
List<Map<String, dynamic>> openings(AppController app, String target) => [
  for (final r in app.records)
    if (r.kind == 'document' && r.data['target'] == target) r.data,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Opening balances are dated on the chosen day, not the page date', () async {
    final (app, db) = await open();
    app.setDate('2026-11-10');
    await app.saveMaster(
      'party',
      {'name': 'Ali Raza', 'customer': true},
      opening: 500000,
      supplierOpening: 120000,
      openingDate: '2026-10-01',
    );
    final ali = app.partyByName('Ali Raza')!;

    final receivable = openings(app, 'ar:${ali.id}').single;
    final payable = openings(app, 'ap:${ali.id}').single;
    expect(receivable['date'], '2026-10-01');
    expect(payable['date'], '2026-10-01');
    expect(receivable['reference'], contains('-20261001-'));
    expect(app.bookAt('2026-09-30').receivable(ali.id), 0);
    // The two openings are set off against each other.
    expect(app.bookAt('2026-10-01').receivable(ali.id), 380000);
    expect(app.bookAt('2026-10-01').payable(ali.id), 0);

    // An account too.
    await app.saveMaster(
      'account',
      {'name': 'Faisal', 'bank': 'Alfalah'},
      opening: 900000,
      openingDate: '2026-09-15',
    );
    final faisal = app.ofKind('account').firstWhere((a) => a.name == 'Faisal');
    expect(openings(app, 'money:${faisal.id}').single['date'], '2026-09-15');

    app.dispose();
    await db.close();
  });

  test('Without a chosen day the page date is used, as before', () async {
    final (app, db) = await open();
    app.setDate('2026-11-10');
    await app.saveMaster('party', {
      'name': 'Mian Shahzad',
      'customer': true,
    }, opening: 100000);
    final shahzad = app.partyByName('Mian Shahzad')!;
    expect(openings(app, 'ar:${shahzad.id}').single['date'], '2026-11-10');

    app.dispose();
    await db.close();
  });

  test('A closed day still refuses an opening balance dated on it', () async {
    final (app, db) = await open();
    final closed = app.selectedDate;
    await app.commit([
      Change('close:$closed', 'close', {
        'date': closed,
        'closed': true,
      }, 0),
    ], action: 'close', reason: 'Day checked');
    await expectLater(
      app.saveMaster('party', {
        'name': 'Late Party',
      }, opening: 100000, openingDate: closed),
      throwsA(anything),
    );
    expect(app.partyByName('Late Party'), isNull, reason: 'nothing half-saved');

    app.dispose();
    await db.close();
  });

  testWidgets('The Add party dialog lets you pick the opening balance date', (
    tester,
  ) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1366, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, db) = await open();
    app.setDate('2026-11-10');
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    BuildContext ctx() => tester.element(find.byType(Workspace));
    app.go('parties');
    await tester.pumpAndSettle();

    unawaited(editMaster(ctx(), app, 'party'));
    await tester.pumpAndSettle();

    // It starts on the page's date.
    final dateField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('2026-11-10'),
    );
    expect(find.text('Opening balance date'), findsOneWidget);
    expect(dateField, findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Mian Tariq',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Opening receivable'),
      '5000',
    );

    // Pick the 3rd of the month in the calendar.
    await tester.tap(dateField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('2026-11-03'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final tariq = app.partyByName('Mian Tariq')!;
    final opening = openings(app, 'ar:${tariq.id}').single;
    expect(opening['date'], '2026-11-03');
    expect(opening['amount'], 500000);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });
}
