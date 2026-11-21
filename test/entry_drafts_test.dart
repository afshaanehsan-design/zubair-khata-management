// Saved drafts: the Draft button beside Add / Save keeps an entry, complete
// or not, on this device; the Drafts tab of the New entry section lists them
// to open (in their own row of the list), finish and add, or delete. A
// finished draft keeps its own day.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/drafts.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

Finder field(String key) => key == 'party'
    ? find.byKey(const ValueKey('roz-party'))
    : find.descendant(
        of: find.byKey(ValueKey('roz-$key')),
        matching: find.byType(TextField),
      );
Finder tab(String name) => find.byKey(ValueKey('roz-tab-$name'));
final draftButton = find.byKey(const ValueKey('roz-draft'));
final addButton = find.byKey(const ValueKey('roz-save'));
final openBanner = find.byKey(const ValueKey('roz-draft-open'));
Finder openButton(EntryDraft d) => find.byKey(ValueKey('draft-open-${d.id}'));
String text(WidgetTester tester, String key) =>
    tester.widget<TextField>(field(key)).controller!.text;

/// [f] inside the list row of draft [d].
Finder inRow(EntryDraft d, Finder f) =>
    find.descendant(of: find.byKey(ValueKey('draft-${d.id}')), matching: f);

/// Whether the Open button of draft [d] can be pressed.
bool canOpen(WidgetTester tester, EntryDraft d) =>
    tester.widget<TextButton>(openButton(d)).onPressed != null;

Finder inComposer(Finder f) =>
    find.descendant(of: find.byType(EntryComposer), matching: f);
Finder composerField(String key) =>
    inComposer(find.byKey(ValueKey('field-$key')));
String composerText(WidgetTester tester, String key) =>
    tester.widget<TextField>(composerField(key)).controller!.text;

Future<(AppController, KhataDatabase)> start(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  return (app, db);
}

/// The form as the Roznamcha page shows it: redrawn whenever the
/// controller changes.
Future<void> pumpPage(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: app,
            builder: (context, _) => RoznamchaForm(app: app),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> finish(
  WidgetTester tester,
  AppController app,
  KhataDatabase db,
) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  app.dispose();
  await db.close();
}

void main() {
  test('Drafts are kept on the device, updated in place and come back with '
      'a backup', () async {
    final db = KhataDatabase(NativeDatabase.memory());
    await db.initialize();
    final app = AppController(db);
    await app.initialize();
    expect(app.entryDrafts, isEmpty);

    final sale = await app.saveEntryDraft(
      source: EntryDraft.roznamcha,
      tab: 'aamad',
      date: '2026-11-15',
      data: {'party': 'Ali Traders', 'q11800': '2'},
      missing: 'Rate likhein (11.8 KG ka)',
    );
    final purchase = await app.saveEntryDraft(
      source: EntryDraft.composer,
      tab: 'purchase',
      date: '2026-11-16',
      data: {'type': 'purchase', 'date': '2026-11-16'},
    );
    expect(app.entryDrafts.map((d) => d.id), [purchase.id, sale.id]);

    // The same id replaces that draft and moves it to the top.
    await app.saveEntryDraft(
      id: sale.id,
      source: EntryDraft.roznamcha,
      tab: 'aamad',
      date: '2026-11-15',
      data: {'party': 'Ali Traders', 'q11800': '3'},
    );
    expect(app.entryDrafts.map((d) => d.id), [sale.id, purchase.id]);
    expect(app.entryDrafts.first.data['q11800'], '3');
    expect(app.entryDrafts.first.missing, '');
    // Saved drafts count locally without entering the posting queue.
    expect(app.book.documents, hasLength(2));
    expect(app.book.documents.every((d) => d.isDraft), isTrue);
    expect(app.records.where((r) => r.kind == 'document'), isEmpty);
    expect(app.pendingCount, 0);
    final backup = await app.backup();

    // Another controller on the same file (the app opened again) has them.
    app.dispose();
    final again = AppController(db);
    await again.initialize();
    expect(again.entryDrafts.map((d) => d.id), [sale.id, purchase.id]);
    expect(again.entryDraft(sale.id)!.date, '2026-11-15');
    expect(again.entryDraft(purchase.id)!.source, EntryDraft.composer);

    await again.deleteEntryDraft(purchase.id);
    expect(again.entryDrafts.map((d) => d.id), [sale.id]);
    expect(again.entryDraft(purchase.id), isNull);

    // A restored backup brings its drafts back.
    await again.restoreBackup(backup);
    expect(again.entryDrafts.map((d) => d.id), [sale.id, purchase.id]);
    again.dispose();

    // A damaged value loses only the drafts; a damaged item only itself.
    await db.setMeta('entry_drafts', '{not json');
    final damaged = AppController(db);
    await damaged.initialize();
    expect(damaged.entryDrafts, isEmpty);
    damaged.dispose();
    await db.setMeta(
      'entry_drafts',
      jsonEncode([
        {'id': 'x', 'source': 'roznamcha', 'tab': 'aamad'},
        {'id': 'y', 'source': 'other', 'tab': 'aamad', 'data': {}},
        sale.toJson(),
      ]),
    );
    final partly = AppController(db);
    await partly.initialize();
    expect(partly.entryDrafts.map((d) => d.id), [sale.id]);
    partly.dispose();
    await db.close();
  });

  testWidgets('Roznamcha form: Draft, the Drafts tab, and a draft finished in '
      'its own row of the list: Draft again, Cancel, its day, Add', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    app.setDate('2026-11-15');
    await pumpPage(tester, app);
    expect(tab('drafts'), findsOneWidget);
    expect(find.text('Drafts'), findsOneWidget);

    // Nothing typed: refused.
    await tap(tester, draftButton);
    expect(find.text('Draft ke liye kuch likhein'), findsOneWidget);
    expect(app.entryDrafts, isEmpty);

    // A sale with the customer and cylinders but no rate yet.
    await tester.enterText(field('party'), 'Ali Traders');
    await tester.enterText(field('q11800'), '2');
    await tester.pumpAndSettle();
    await tap(tester, draftButton);
    expect(app.entryDrafts, hasLength(1));
    final draft = app.entryDrafts.single;
    expect(draft.source, EntryDraft.roznamcha);
    expect(draft.tab, 'aamad');
    expect(draft.date, '2026-11-15');
    expect(draft.missing, 'Rate likhein (11.8 KG ka)');
    expect(draft.data['party'], 'Ali Traders');
    expect(draft.data['q11800'], '2');
    expect(app.book.documents.single.isDraft, isTrue);
    expect(app.book.gasGrams, -23600);
    // The form is clear for the next entry.
    expect(text(tester, 'party'), '');
    expect(text(tester, 'q11800'), '');
    expect(find.textContaining('Draft mein save ho gaya'), findsOneWidget);
    expect(find.text('Drafts (1)'), findsOneWidget);

    // Something typed on the tab meanwhile stays there.
    await tester.enterText(field('party'), 'Bilal');
    await tester.pumpAndSettle();

    // The Drafts tab lists it: who, what, and what is missing.
    await tap(tester, tab('drafts'));
    expect(find.byKey(ValueKey('draft-${draft.id}')), findsOneWidget);
    expect(find.text('Ali Traders'), findsOneWidget);
    expect(find.textContaining('11.8 KG × 2'), findsOneWidget);
    expect(find.byKey(ValueKey('draft-missing-${draft.id}')), findsOneWidget);
    expect(find.textContaining('15-11-2026'), findsOneWidget);
    expect(addButton, findsNothing);

    // A second draft, to see that one opens at a time.
    final other = await app.saveEntryDraft(
      source: EntryDraft.roznamcha,
      tab: 'kharcha',
      date: '2026-11-16',
      data: {'kind': 'cash', 'amount': '500'},
      missing: 'Tafseel likhna zaroori hai',
    );
    await tester.pumpAndSettle();

    // Opened on another day: its fields open in its own row of the list,
    // on its own day. The top bar's day and the Drafts tab stay.
    app.setDate('2026-11-17');
    await tester.pumpAndSettle();
    await tap(tester, openButton(draft));
    expect(app.selectedDate, '2026-11-17');
    expect(inRow(draft, field('party')), findsOneWidget);
    expect(text(tester, 'party'), 'Ali Traders');
    expect(text(tester, 'q11800'), '2');
    expect(
      inRow(draft, find.byKey(const ValueKey('roz-draft-date'))),
      findsOneWidget,
    );
    expect(inRow(draft, find.text('15-11-2026')), findsOneWidget);
    expect(inRow(draft, addButton), findsOneWidget);
    expect(inRow(draft, draftButton), findsOneWidget);
    expect(openBanner, findsNothing);
    // Only the Drafts tab while it is open, and no other draft opens.
    expect(tab('drafts'), findsOneWidget);
    expect(tab('aamad'), findsNothing);
    expect(tab('kharcha'), findsNothing);
    expect(openButton(draft), findsNothing);
    expect(canOpen(tester, other), isFalse);

    // Leaving the page and coming back keeps it open with what was added.
    await tester.enterText(field('vehicle'), '92');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPage(tester, app);
    expect(inRow(draft, field('vehicle')), findsOneWidget);
    expect(text(tester, 'vehicle'), '92');
    expect(text(tester, 'party'), 'Ali Traders');

    // Draft again updates the same draft, which closes in the list.
    await tap(tester, draftButton);
    expect(app.entryDrafts.map((d) => d.id), [draft.id, other.id]);
    expect(app.entryDraft(draft.id)!.data['vehicle'], '92');
    expect(app.entryDraft(draft.id)!.date, '2026-11-15');
    expect(field('party'), findsNothing);
    expect(canOpen(tester, draft), isTrue);
    expect(canOpen(tester, other), isTrue);
    expect(find.textContaining('Draft mein save ho gaya'), findsOneWidget);
    expect(app.rozDrafts['page:open'], isNull);
    expect(app.selectedDate, '2026-11-17');

    // Cancel puts it back unchanged.
    await tap(tester, openButton(draft));
    await tester.enterText(field('q11800'), '5');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('roz-draft-cancel')));
    expect(field('party'), findsNothing);
    expect(canOpen(tester, draft), isTrue);
    expect(app.entryDraft(draft.id)!.data['q11800'], '2');
    expect(app.rozDrafts['page:open'], isNull);

    // Its day can be changed while it is open; Draft keeps the new day.
    await tap(tester, openButton(draft));
    expect(text(tester, 'q11800'), '2');
    await tap(tester, find.byKey(const ValueKey('roz-draft-date')));
    await tap(
      tester,
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('16'),
      ),
    );
    await tap(tester, find.text('OK'));
    expect(inRow(draft, find.text('16-11-2026')), findsOneWidget);
    await tap(tester, draftButton);
    expect(app.entryDraft(draft.id)!.date, '2026-11-16');

    // Finished: added on its own day, it leaves the list.
    await tap(tester, openButton(draft));
    await tester.enterText(field('rate'), '4640');
    await tester.pumpAndSettle();
    await tap(tester, addButton);
    final sale = app.book.documents.firstWhere((d) => !d.isDraft);
    expect(sale.type, EntryType.sale);
    expect(sale.date, '2026-11-16');
    expect(sale.party, app.partyByName('Ali Traders')!.id);
    expect(sale.data['vehicle'], '92');
    expect(sale.rate, 464000);
    expect(app.entryDrafts.map((d) => d.id), [other.id]);
    expect(find.byKey(ValueKey('draft-${draft.id}')), findsNothing);
    expect(find.textContaining('Save ho gaya'), findsOneWidget);
    expect(canOpen(tester, other), isTrue);
    expect(app.selectedDate, '2026-11-17');
    expect(find.text('Drafts (1)'), findsOneWidget);

    // What was typed on the tab is still there.
    await tap(tester, tab('aamad'));
    expect(text(tester, 'party'), 'Bilal');

    // A correction has no Draft button.
    tester.state<RoznamchaFormState>(find.byType(RoznamchaForm)).edit(sale);
    await tester.pumpAndSettle();
    expect(draftButton, findsNothing);
    expect(tab('drafts'), findsNothing);
    await finish(tester, app, db);
  });

  testWidgets('Deleting a draft asks first', (tester) async {
    final (app, db) = await start(tester);
    final draft = await app.saveEntryDraft(
      source: EntryDraft.roznamcha,
      tab: 'kharcha',
      date: app.selectedDate,
      data: {'kind': 'cash', 'amount': '500'},
      missing: 'Tafseel likhna zaroori hai',
    );
    await pumpPage(tester, app);
    await tap(tester, tab('drafts'));
    expect(find.textContaining('Cash kharcha'), findsOneWidget);
    expect(find.text('Rs 500'), findsOneWidget);
    await tap(tester, find.byKey(ValueKey('draft-delete-${draft.id}')));
    await tap(tester, find.text('Nahi'));
    expect(app.entryDrafts, hasLength(1));
    await tap(tester, find.byKey(ValueKey('draft-delete-${draft.id}')));
    await tap(tester, find.text('Haan'));
    expect(app.entryDrafts, isEmpty);
    expect(find.byKey(const ValueKey('drafts-empty')), findsOneWidget);
    await finish(tester, app, db);
  });

  testWidgets('Composer: Draft, then finished in its own row of the Drafts '
      'tab on its own date: Cancel, Draft again and Add', (tester) async {
    final (app, db) = await start(tester);
    await app.saveMaster('party', {
      'name': 'PSO',
      'customer': false,
      'supplier': true,
    });
    final pso = app.partyByName('PSO')!.id;
    app.setDate('2026-11-16');
    await pumpPage(tester, app);
    BuildContext ctx() => tester.element(find.byType(RoznamchaForm));

    unawaited(composeEntry(ctx(), app, type: EntryType.purchase, party: pso));
    await tester.pumpAndSettle();
    await tester.enterText(composerField('grams'), '1000');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('composer-draft')));
    expect(find.byType(EntryComposer), findsNothing);
    expect(app.entryDrafts, hasLength(1));
    final draft = app.entryDrafts.single;
    expect(draft.source, EntryDraft.composer);
    expect(draft.tab, 'purchase');
    expect(draft.date, '2026-11-16');
    expect(draft.data['party'], pso);
    expect(draft.data['grams'], 1000000);
    expect(app.composerDrafts, isEmpty);
    expect(app.book.documents.single.isDraft, isTrue);
    expect(app.book.gasGrams, 1000000);

    // Listed with the company and the weight, opened on another day: the
    // composer opens in its row of the list, on the draft's date, with Add.
    app.setDate('2026-11-17');
    await tester.pumpAndSettle();
    await tap(tester, tab('drafts'));
    expect(find.text('PSO'), findsOneWidget);
    expect(find.textContaining('1,000 KG'), findsOneWidget);
    await tap(tester, openButton(draft));
    expect(inRow(draft, find.byType(EntryComposer)), findsOneWidget);
    expect(app.selectedDate, '2026-11-17');
    expect(tab('drafts'), findsOneWidget);
    expect(tab('aamad'), findsNothing);
    expect(
      inComposer(find.byKey(const ValueKey('composer-draft-open'))),
      findsOneWidget,
    );
    expect(inComposer(find.text('2026-11-16')), findsOneWidget);
    expect(inComposer(find.text('Save & next')), findsNothing);
    expect(inComposer(find.text('New entry')), findsNothing);
    expect(inComposer(find.text('Add')), findsOneWidget);
    expect(composerText(tester, 'grams'), '1000.000');

    // Cancel closes it unchanged, and what was typed goes.
    final rate = draft.data['rate'];
    await tester.enterText(composerField('rate'), '150');
    await tester.pumpAndSettle();
    await tap(
      tester,
      inComposer(find.byKey(const ValueKey('composer-cancel'))),
    );
    expect(find.byType(EntryComposer), findsNothing);
    expect(canOpen(tester, draft), isTrue);
    expect(app.entryDraft(draft.id)!.data['rate'], rate);
    expect(app.composerDrafts, isEmpty);
    expect(app.rozDrafts['page:open'], isNull);

    // Leaving the page and coming back keeps it open with what was typed.
    await tap(tester, openButton(draft));
    expect(composerText(tester, 'rate'), isNot('150'));
    await tester.enterText(composerField('rate'), '180');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPage(tester, app);
    expect(inRow(draft, find.byType(EntryComposer)), findsOneWidget);
    expect(composerText(tester, 'rate'), '180.00');

    // Draft again updates it on its own date; the list shows again.
    await tap(tester, inComposer(find.byKey(const ValueKey('composer-draft'))));
    expect(find.byType(EntryComposer), findsNothing);
    expect(app.entryDrafts.single.id, draft.id);
    expect(app.entryDrafts.single.data['rate'], 18000);
    expect(app.entryDrafts.single.date, '2026-11-16');
    expect(find.textContaining('Saved to drafts'), findsOneWidget);
    expect(app.composerDrafts, isEmpty);
    expect(app.rozDrafts['page:open'], isNull);

    // Add posts it on its own date; the list is empty.
    await tap(tester, openButton(draft));
    expect(composerText(tester, 'rate'), '180.00');
    await tester.enterText(composerField('rate'), '200');
    await tester.pumpAndSettle();
    await tap(tester, inComposer(find.byKey(const ValueKey('composer-save'))));
    expect(find.byType(EntryComposer), findsNothing);
    final purchase = app.book.documents.single;
    expect(purchase.type, EntryType.purchase);
    expect(purchase.date, '2026-11-16');
    expect(purchase.party, pso);
    expect(purchase.value('rate'), 20000);
    expect(app.entryDrafts, isEmpty);
    expect(app.composerDrafts, isEmpty);
    expect(find.byKey(const ValueKey('drafts-empty')), findsOneWidget);
    expect(find.textContaining('Saved locally'), findsOneWidget);
    expect(app.selectedDate, '2026-11-17');

    // A correction has no Draft button.
    unawaited(composeEntry(ctx(), app, replace: purchase));
    await tester.pumpAndSettle();
    expect(
      inComposer(find.byKey(const ValueKey('composer-draft'))),
      findsNothing,
    );
    await tap(tester, inComposer(find.text('Cancel')));
    await finish(tester, app, db);
  });

  testWidgets('The ✏️ of a draft row still opens it on its own tab in the '
      'New entry dialog; finished there, it closes in the Drafts list', (
    tester,
  ) async {
    final (app, db) = await start(tester);
    final draft = await app.saveEntryDraft(
      source: EntryDraft.roznamcha,
      tab: 'kharcha',
      date: app.selectedDate,
      data: {'kind': 'cash', 'amount': '500'},
      missing: 'Tafseel likhna zaroori hai',
    );
    await pumpPage(tester, app);
    await tap(tester, tab('drafts'));
    await tap(tester, openButton(draft));
    expect(inRow(draft, field('amount')), findsOneWidget);

    // What the ✏️ of the draft's row in the day's table calls.
    final row = app.book.documents.single;
    expect(row.isDraft, isTrue);
    unawaited(
      composeEntry(
        tester.element(find.byType(RoznamchaForm)),
        app,
        replace: row,
      ),
    );
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
    expect(inDialog(openBanner), findsOneWidget);
    expect(inDialog(find.byType(DraftList)), findsNothing);
    expect(inDialog(tab('kharcha')), findsOneWidget);
    expect(inDialog(tab('drafts')), findsNothing);
    await tester.enterText(
      inDialog(
        find.descendant(
          of: find.byKey(const ValueKey('roz-note')),
          matching: find.byType(TextField),
        ),
      ),
      'Chai',
    );
    await tester.pumpAndSettle();
    await tap(tester, inDialog(addButton));
    expect(app.entryDrafts, isEmpty);
    expect(app.book.documents.single.isDraft, isFalse);
    expect(app.book.documents.single.note, 'Chai');
    await tap(tester, inDialog(find.byTooltip('Close')));
    expect(dialog, findsNothing);

    // The page's Drafts tab no longer holds it open: its tabs are back.
    expect(tab('aamad'), findsOneWidget);
    expect(find.byKey(const ValueKey('drafts-empty')), findsOneWidget);
    expect(app.rozDrafts['page:open'], isNull);
    await finish(tester, app, db);
  });
}
