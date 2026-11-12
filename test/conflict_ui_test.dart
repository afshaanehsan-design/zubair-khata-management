import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';

void main() {
  testWidgets(
    'Reviewing a conflicting correction replaces the source and keeps money counted once',
    (tester) async {
      await initializeDateFormatting('en');
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      await app.saveMaster('party', {'name': 'Ali'});
      final party = app.ofKind('party').single.id;
      await app.post({
        'type': 'receipt',
        'date': app.selectedDate,
        'party': party,
        'cash': 10000,
      });
      final original = app.book.documents.single;
      await app.post(
        {...original.data, 'cash': 20000},
        replace: original,
        reason: 'Correct cash',
      );
      final failed = app.commands.last;
      await db.commandState(failed.id, 'conflict', 'Version conflict');
      await app.reload();
      expect(app.book.money('cash'), 10000);
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(KhataApp(app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final review = find.text('Review changes').last;
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review my change'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Correct entry'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('field-cash')))
            .controller!
            .text,
        '200.00',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
        find.byType(TextField).last,
        'Reviewed correction',
      );
      await tester.tap(find.text('Confirm'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await app.reload();
      await tester.pumpAndSettle();
      expect(app.book.money('cash'), 20000);
      expect(app.book.documents.length, 1);
      expect(app.conflictCount, 0);
      expect(app.record(original.id)!.data['voided'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );
}
