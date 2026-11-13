// On a device that has never signed in to a cloud account every entry stays
// in the queue for good, so there is no "pending" count to show.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';

void main() {
  testWidgets('A local device shows no pending count; a linked one does', (
    tester,
  ) async {
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
    await app.post({
      'type': 'receipt',
      'date': app.selectedDate,
      'party': app.partyByName('Ali')!.id,
      'cash': 10000,
    });
    expect(app.pendingCount, 2);
    expect(app.cloudLinked, isFalse);

    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    expect(find.text('Local device'), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-count')), findsNothing);
    app.go('settings');
    await tester.pumpAndSettle();
    expect(find.text('Sync & recovery'), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-tag')), findsNothing);

    // Linked to an account (signed out at the moment), the same two changes
    // are waiting to reach the cloud.
    app.owner = 'owner-1';
    expect(app.cloudLinked, isTrue);
    app.go('roznamcha');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pending-count')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    app.go('settings');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pending-tag')),
        matching: find.text('2 Pending'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });
}
