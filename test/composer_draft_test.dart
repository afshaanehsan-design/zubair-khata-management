// The general composer keeps what was typed in a new entry when it is closed
// and opened again, but never the day it was begun on.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';

Finder inComposer(Finder f) =>
    find.descendant(of: find.byType(EntryComposer), matching: f);

Finder field(String key) => inComposer(find.byKey(ValueKey('field-$key')));

String text(WidgetTester tester, String key) =>
    tester.widget<TextField>(field(key)).controller!.text;

void main() {
  testWidgets('A draft keeps its values and goes on the page date', (
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
    await tester.pumpWidget(KhataApp(app));
    await tester.pumpAndSettle();
    BuildContext ctx() => tester.element(find.byType(Workspace));

    // Begun on the 10th and closed without saving.
    app.setDate('2026-11-10');
    await tester.pumpAndSettle();
    unawaited(composeEntry(ctx(), app, type: EntryType.stockAdjustment));
    await tester.pumpAndSettle();
    await tester.enterText(field('grams'), '50');
    await tester.pumpAndSettle();
    expect(
      app.composerDrafts['context:stockAdjustment']?['date'],
      '2026-11-10',
    );
    await tester.tap(inComposer(find.text('Cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(EntryComposer), findsNothing);

    // Opened again on the 12th: the weight is back, the date is the 12th.
    app.setDate('2026-11-12');
    await tester.pumpAndSettle();
    unawaited(composeEntry(ctx(), app, type: EntryType.stockAdjustment));
    await tester.pumpAndSettle();
    expect(text(tester, 'grams'), '50.000');
    expect(inComposer(find.text('2026-11-12')), findsOneWidget);
    expect(inComposer(find.text('2026-11-10')), findsNothing);
    await tester.enterText(field('note'), 'Stock count');
    await tester.tap(inComposer(find.text('Save')));
    await tester.pumpAndSettle();
    final posted = app.book.documents.single;
    expect(posted.type, EntryType.stockAdjustment);
    expect(posted.date, '2026-11-12');
    expect(posted.value('grams'), 50000);
    expect(app.composerDrafts, isEmpty);

    // Correcting an entry keeps no draft: it always starts from the entry.
    unawaited(composeEntry(ctx(), app, replace: posted));
    await tester.pumpAndSettle();
    await tester.enterText(field('grams'), '60');
    await tester.pumpAndSettle();
    await tester.tap(inComposer(find.text('Cancel')));
    await tester.pumpAndSettle();
    expect(app.composerDrafts, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await db.close();
  });
}
