// Saved drafts: the Draft button beside Add / Save keeps an entry, complete
// or not, on this device; the Drafts tab of the New entry section lists them
// to open, finish and add, or delete. A finished draft keeps its own day.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
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

Finder inComposer(Finder f) =>
    find.descendant(of: find.byType(EntryComposer), matching: f);
Finder composerField(String key) =>
    inComposer(find.byKey(ValueKey('field-$key')));

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

  testWidgets('Roznamcha form: Draft, the Drafts tab, Open on its own day, '
      'Cancel, Draft again and Add', (tester) async {
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

    // Opened on another day: the top bar goes back to the draft's day.
    app.setDate('2026-11-17');
    await tester.pumpAndSettle();
    await tap(tester, openButton(draft));
    expect(app.selectedDate, '2026-11-15');
    expect(openBanner, findsOneWidget);
    expect(text(tester, 'party'), 'Ali Traders');
    expect(text(tester, 'q11800'), '2');
    // Only its own tab, like a correction.
    expect(tab('kharcha'), findsNothing);
    expect(tab('drafts'), findsNothing);

    // Leaving the page and coming back keeps what was added to it.
    await tester.enterText(field('vehicle'), '92');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPage(tester, app);
    expect(openBanner, findsOneWidget);
    expect(text(tester, 'vehicle'), '92');
    expect(text(tester, 'party'), 'Ali Traders');

    // Draft again updates the same draft and returns to the tab's values.
    await tap(tester, draftButton);
    expect(app.entryDrafts, hasLength(1));
    expect(app.entryDrafts.single.id, draft.id);
    expect(app.entryDrafts.single.data['vehicle'], '92');
    expect(openBanner, findsNothing);
    expect(text(tester, 'party'), 'Bilal');
    expect(app.rozDrafts['page:open'], isNull);

    // Cancel puts it back unchanged.
    await tap(tester, tab('drafts'));
    await tap(tester, openButton(app.entryDrafts.single));
    await tester.enterText(field('q11800'), '5');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('roz-draft-cancel')));
    expect(openBanner, findsNothing);
    expect(app.entryDrafts.single.data['q11800'], '2');
    expect(text(tester, 'party'), 'Bilal');

    // Finished on another day: it is added on its own day and goes.
    app.setDate('2026-11-17');
    await tester.pumpAndSettle();
    await tap(tester, tab('drafts'));
    await tap(tester, openButton(app.entryDrafts.single));
    expect(app.selectedDate, '2026-11-15');
    await tester.enterText(field('rate'), '4640');
    await tester.pumpAndSettle();
    await tap(tester, addButton);
    final sale = app.book.documents.single;
    expect(sale.type, EntryType.sale);
    expect(sale.date, '2026-11-15');
    expect(sale.party, app.partyByName('Ali Traders')!.id);
    expect(sale.data['vehicle'], '92');
    expect(sale.rate, 464000);
    expect(app.entryDrafts, isEmpty);
    expect(openBanner, findsNothing);
    expect(text(tester, 'party'), 'Bilal');
    expect(find.text('Drafts'), findsOneWidget);

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

  testWidgets('Composer: Draft, then finished from the Drafts tab on its own '
      'date', (tester) async {
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

    // Listed with the company and the weight, opened on another day.
    app.setDate('2026-11-17');
    await tester.pumpAndSettle();
    await tap(tester, tab('drafts'));
    expect(find.text('PSO'), findsOneWidget);
    expect(find.textContaining('1,000 KG'), findsOneWidget);
    await tap(tester, openButton(draft));
    expect(find.byType(EntryComposer), findsOneWidget);
    expect(
      inComposer(find.byKey(const ValueKey('composer-draft-open'))),
      findsOneWidget,
    );
    expect(inComposer(find.text('2026-11-16')), findsOneWidget);
    expect(inComposer(find.text('Save & next')), findsNothing);
    expect(
      tester.widget<TextField>(composerField('grams')).controller!.text,
      '1000.000',
    );
    await tester.enterText(composerField('rate'), '200');
    await tester.pumpAndSettle();
    await tap(tester, inComposer(find.byKey(const ValueKey('composer-save'))));
    expect(find.byType(EntryComposer), findsNothing);
    final purchase = app.book.documents.single;
    expect(purchase.type, EntryType.purchase);
    expect(purchase.date, '2026-11-16');
    expect(purchase.party, pso);
    expect(app.entryDrafts, isEmpty);
    expect(app.composerDrafts, isEmpty);

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
}
