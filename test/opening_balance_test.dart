import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';
import 'package:zubair_khata_management/ui/roznamcha_page.dart';

Finder input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

String text(WidgetTester tester, String key) =>
    tester.widget<TextField>(input(key)).controller!.text;

final saveButton = find.byKey(const ValueKey('opening-save'));

Future<void> tapRow(WidgetTester tester, String title, IconData icon) async {
  final row = find
      .ancestor(of: find.text(title), matching: find.byType(InkWell))
      .first;
  await tester.ensureVisible(row);
  await tester.tap(find.descendant(of: row, matching: find.byIcon(icon)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Starting cash is entered once; opening rows are corrected with edit',
    (tester) async {
      await initializeDateFormatting('en');
      tester.view.physicalSize = const Size(1440, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      // A customer and a company with their old balances, before any cash.
      await app.saveMaster('party', {'name': 'Ali'}, opening: 500000);
      await app.saveMaster('party', {
        'name': 'PSO',
        'customer': false,
        'supplier': true,
      }, supplierOpening: 300000);
      final ali = app.partyByName('Ali')!.id;
      final pso = app.partyByName('PSO')!.id;
      await tester.pumpWidget(KhataApp(app));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Theek karo'), findsNothing);
      expect(find.text('Opening Theek Karo'), findsNothing);
      expect(find.text('Opening balance — Ali (Customer)'), findsOneWidget);
      expect(find.text('Opening balance — PSO (Company)'), findsOneWidget);

      // Starting cash: no reason needed, and the button goes away afterwards.
      final cashButton = find.byKey(const ValueKey('roz-opening-cash'));
      expect(cashButton, findsOneWidget);
      await tester.tap(cashButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('opening-reason')), findsNothing);
      await tester.enterText(input('opening-amount'), '25000');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(app.book.money('cash'), 2500000);
      final cash = app.book.documents.singleWhere(
        (d) => d.data['target'] == 'money:cash',
      );
      expect(isOpeningBalance(cash), isTrue);
      expect(cash.date, app.selectedDate);
      expect(cash.note, openingBalanceNote);
      expect(cash.reference, startsWith('OP-'));
      expect(cashButton, findsNothing);
      expect(find.text('Opening balance — Cash'), findsOneWidget);
      // The default note is not repeated next to the label.
      expect(find.text('· $openingBalanceNote'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('roz-safi')),
          matching: find.text('Rs 25,000'),
        ),
        findsOneWidget,
      );

      // ✏️ on a customer opening: a reason is required and the original
      // stays in the audit trail.
      final aliOpening = app.book.documents.singleWhere(
        (d) => d.data['target'] == 'ar:$ali',
      );
      await tapRow(
        tester,
        'Opening balance — Ali (Customer)',
        Icons.edit_outlined,
      );
      expect(find.text('Opening receivable'), findsOneWidget);
      expect(text(tester, 'opening-amount'), '5000');
      await tester.enterText(input('opening-amount'), '4500');
      await tester.tap(saveButton);
      await tester.pump();
      expect(find.text('A reason is required'), findsOneWidget);
      expect(app.book.receivable(ali), 500000);
      await tester.enterText(input('opening-reason'), 'Purana hisab galat');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(app.book.receivable(ali), 450000);
      expect(app.record(aliOpening.id)!.data['voided'], isTrue);
      expect(
        app.record(aliOpening.id)!.data['voidReason'],
        'Purana hisab galat',
      );
      final aliNew = app.book.documents.singleWhere(
        (d) => d.data['target'] == 'ar:$ali',
      );
      expect(isOpeningBalance(aliNew), isTrue);
      expect(aliNew.reference, aliOpening.reference);
      expect(app.book.money('cash'), 2500000);

      // A company opening is shown as what we owe (a positive figure).
      await tapRow(
        tester,
        'Opening balance — PSO (Company)',
        Icons.edit_outlined,
      );
      expect(find.text('Opening payable'), findsOneWidget);
      expect(text(tester, 'opening-amount'), '3000');
      await tester.enterText(input('opening-amount'), '3500');
      await tester.enterText(input('opening-reason'), 'Ek bill reh gaya tha');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(app.book.payable(pso), 350000);

      // "Correct entry" from the transaction details opens the same dialog.
      final psoOpening = app.book.documents.singleWhere(
        (d) => d.data['target'] == 'ap:$pso',
      );
      unawaited(
        composeEntry(
          tester.element(find.byType(RoznamchaPage)),
          app,
          replace: psoOpening,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Opening payable'), findsOneWidget);
      expect(text(tester, 'opening-amount'), '3500');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(app.book.payable(pso), 350000);

      // 🗑️ removes the starting cash; then it can be entered again.
      await tapRow(
        tester,
        'Opening balance — Cash',
        Icons.delete_outline_rounded,
      );
      expect(find.text('Yeh Opening balance delete karein?'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Ghalat raqam');
      await tester.pump();
      await tester.tap(find.text('Haan, delete'));
      await tester.pumpAndSettle();
      expect(app.book.money('cash'), 0);
      expect(cashButton, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );
}
