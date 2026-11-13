// Restoring a backup keeps a backup of what it replaced, which can be
// exported from Settings and restored to undo the restore.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';

Future<AppController> open() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return app;
}

void main() {
  test('Restoring the backup kept before a restore undoes it', () async {
    final app = await open();
    await app.saveMaster('party', {'name': 'Ali', 'customer': true});
    final older = await app.backup();
    expect(app.preRestoreSaved, isFalse);
    expect(await app.preRestoreCopy(), isNull);

    await app.saveMaster('party', {'name': 'Bilal', 'customer': true});
    await app.restoreBackup(older);
    expect(app.partyByName('Ali'), isNotNull);
    expect(app.partyByName('Bilal'), isNull);
    expect(app.preRestoreSaved, isTrue);

    final replaced = (await app.preRestoreCopy())!;
    await app.restoreBackup(replaced);
    expect(app.partyByName('Ali'), isNotNull);
    expect(app.partyByName('Bilal'), isNotNull);
    await app.db.close();
  });

  testWidgets('Settings offers that backup only when there is one', (
    tester,
  ) async {
    await initializeDateFormatting('en');
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await open();
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    app.go('settings');
    await tester.pumpAndSettle();
    final export = find.byKey(const ValueKey('export-pre-restore'));
    expect(export, findsNothing);

    await app.restoreBackup(await app.backup());
    await tester.pumpAndSettle();
    expect(export, findsOneWidget);
    expect(
      find.text('Export the backup from before the last restore'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await app.db.close();
  });
}
