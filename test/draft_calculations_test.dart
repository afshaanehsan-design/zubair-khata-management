import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';
import 'package:zubair_khata_management/features/ledger/roznamcha.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';

const day = '2026-11-15', next = '2026-11-16';

Future<AppController> setup() async {
  final db = KhataDatabase(NativeDatabase.memory());
  await db.initialize();
  final app = AppController(db);
  await app.initialize();
  app.setDate(day);
  await app.saveMaster('party', {'name': 'Ali', 'customer': true});
  await app.saveMaster('party', {'name': 'PSO', 'supplier': true});
  await app.saveMaster('account', {'name': 'HBL', 'category': 'Bank'});
  addTearDown(() async {
    app.dispose();
    await db.close();
  });
  return app;
}

Future<EntryDraft> roz(
  AppController app,
  String tab,
  Json data, {
  String? id,
  String date = day,
}) => app.saveEntryDraft(
  id: id,
  source: EntryDraft.roznamcha,
  tab: tab,
  date: date,
  data: data,
);
Future<EntryDraft> composer(
  AppController app,
  String type,
  Json data, {
  String? id,
}) => app.saveEntryDraft(
  id: id,
  source: EntryDraft.composer,
  tab: type,
  date: day,
  data: {'type': type, 'date': day, ...data},
);
RoznamchaDay cashbook(AppController app, String date) {
  final book = app.bookAt(date);
  final previous = DateTime.parse(date)
      .subtract(const Duration(days: 1))
      .toIso8601String()
      .substring(0, 10);
  return RoznamchaDay(
    date,
    app.bookAt(previous).money('cash'),
    book.documents.where((d) => d.date == date),
  );
}

void main() {
  test('A composer draft keeps a party first named in another draft when that draft is deleted', () async {
    final app = await setup();
    final original = await roz(app, 'aamad', {
      'party': 'Draft company',
      'cash': '50',
    });
    final party = app
        .ofKind('party')
        .singleWhere((r) => r.name == 'Draft company');
    final purchase = await composer(app, 'purchase', {
      'party': party.id,
      'grams': 1000,
      'rate': 10000,
      'rateUnit': 1000,
    });
    expect(app.book.partyBalance(party.id), -15000);
    await app.deleteEntryDraft(original.id);
    expect(app.name(Document(app.record(purchase.id)!).party), 'Draft company');
    expect(app.book.partyBalance(party.id), -10000);
    await expectLater(
      app.saveMaster('party', {'name': 'Renamed'}, existing: party),
      throwsStateError,
    );
    await app.post(purchase.data, draftId: purchase.id);
    expect(app.partyByName('Draft company')!.id, party.id);
    expect(app.book.partyBalance(party.id), -10000);
  });

  test('Updating and finishing a draft preserves its FIFO position', () async {
    final app = await setup();
    final ali = app.partyByName('Ali')!.id, pso = app.partyByName('PSO')!.id;
    for (final (time, rate) in [(1000, 10000), (1001, 20000)]) {
      await app.post({
        'type': 'purchase',
        'date': day,
        'occurredAt': time,
        'party': pso,
        'grams': 11800,
        'rate': rate,
        'rateUnit': 11800,
      });
    }
    final draft = await roz(app, 'aamad', {
      'party': 'Ali',
      'q11800': '1',
      'rate': '300',
      'occurredAt': 2000,
    });
    await app.post({
      'type': 'sale',
      'date': day,
      'occurredAt': 3000,
      'party': ali,
      'quantities': {'11800': 1},
      'rate': 30000,
    });
    int cost() => app.book.allocations
        .where((a) => a.sale == draft.id)
        .fold(0, (v, a) => v + a.cost);
    expect(cost(), 10000);
    await roz(app, 'aamad', {
      'party': 'Ali',
      'q11800': '1',
      'rate': '300',
      'occurredAt': 9000,
    }, id: draft.id);
    expect(Document(app.record(draft.id)!).value('occurredAt'), 2000);
    expect(cost(), 10000);
    final before = app.book.partyBalance(ali);
    await app.post(
      Document(app.record(draft.id)!).data,
      replace: Document(app.record(draft.id)!),
    );
    expect(cost(), 10000);
    expect(app.book.gasGrams, 0);
    expect(app.book.partyBalance(ali), before);
  });

  test('Draft credit notes use their source invoice and leave collections unchanged', () async {
    final app = await setup();
    final ali = app.partyByName('Ali')!.id;
    await app.post({
      'type': 'sale',
      'date': day,
      'party': ali,
      'quantities': {'11800': 1},
      'rate': 50000,
      'cash': 10000,
    });
    final sale = app.book.documents.single;
    final credit = await composer(app, 'creditNote', {
      'sourceInvoice': sale.id,
    });
    expect(Document(app.record(credit.id)!).party, ali);
    expect(Document(app.record(credit.id)!).bill, sale.bill);
    expect(app.book.partyBalance(ali), -10000);
    expect(app.book.money('cash'), 10000);
    await app.deleteEntryDraft(credit.id);
    expect(app.book.partyBalance(ali), 40000);
  });

  test('Incomplete saved sale counts known cash, bank, direct, bill and stock in every balance', () async {
    final app = await setup();
    final bank = app.ofKind('account').firstWhere((r) => r.name == 'HBL').id;
    final ali = app.partyByName('Ali')!.id, pso = app.partyByName('PSO')!.id;
    final queued = app.commands.length;
    await roz(app, 'aamad', {
      'party': 'Ali',
      'q11800': '2',
      'cash': '100',
      'bank': '50',
      'account': bank,
      'extraBanks': [
        {'amount': '25', 'direct': true, 'company': 'PSO'},
      ],
    });
    final book = app.book, sheet = cashbook(app, day);
    expect(sheet.left, 17500);
    expect(sheet.rightTotal, 7500);
    expect(sheet.safi, 10000);
    expect(sheet.safi, book.money('cash'));
    expect(book.money(bank), 5000);
    expect(book.partyBalance(ali), -17500);
    expect(book.partyBalance(pso), 2500);
    expect(book.gasGrams, -23600);
    expect(book.full['11800'], -2);
    expect(sheet.bill, 0); // No invented selling rate.
    expect(book.profitIncomplete, isTrue);
    expect(cashbook(app, next).opening, 10000);
    expect(app.commands.length, queued); // Drafts stay local.
    expect(
      (await app.db.effective()).where((r) => r.kind == 'document'),
      isEmpty,
    );
    final report = buildReport(app, 'Cash book', day, day);
    expect(invoiceReport(app, book.documents.single).title, contains('Draft'));
    expect(
      report.rows.expand((r) => r).any((c) => c.text.contains('Draft')),
      isTrue,
    );
  });

  test(
    'All six Roznamcha tabs use the same A, B, safi and bank rules as entries',
    () async {
      final app = await setup();
      final bank = app.ofKind('account').firstWhere((r) => r.name == 'HBL').id;
      await roz(app, 'aamad', {'party': 'Ali', 'cash': '1000'});
      await roz(app, 'kharcha', {
        'kind': 'cash',
        'amount': '100',
      }); // No note yet.
      await roz(app, 'office', {'amount': '50'});
      await roz(app, 'kharcha', {
        'kind': 'bankJama',
        'amount': '200',
        'account': bank,
      });
      await roz(app, 'nikali', {'amount': '80', 'account': bank});
      await roz(app, 'less', {'lessMode': 'cashOut', 'amount': '10'});
      await roz(app, 'less', {
        'lessMode': 'bank',
        'party': 'Ali',
        'amount': '30',
        'account': bank,
      });
      await roz(app, 'less', {'party': 'Ali', 'amount': '20'});
      await roz(app, 'companyIn', {
        'party': 'PSO',
        'cash': '40',
        'bank': '60',
        'account': bank,
      });
      final sheet = cashbook(app, day);
      expect(sheet.left, 117000);
      expect(sheet.rightTotal, 41000);
      expect(sheet.safi, 76000);
      expect(app.book.money('cash'), sheet.safi);
      expect(app.book.money(bank), 21000);
      expect(sheet.bankNet, app.book.bankMoney);
      expect(app.book.partyBalance(app.partyByName('Ali')!.id), -105000);
      expect(app.book.partyBalance(app.partyByName('PSO')!.id), -10000);
      expect(app.book.postings.fold(0, (v, p) => v + p.debit), 0);
    },
  );

  test('Editing, moving and deleting a draft invalidate dated balances and survive restart', () async {
    final app = await setup();
    final draft = await roz(app, 'aamad', {
      'party': 'New party',
      'cash': '100',
    });
    expect(app.bookAt(day).money('cash'), 10000);
    expect(
      app.ofKind('party').where((r) => r.name == 'New party'),
      hasLength(1),
    );
    await roz(
      app,
      'aamad',
      {'party': 'New party', 'cash': '250'},
      id: draft.id,
      date: next,
    );
    expect(app.bookAt(day).money('cash'), 0);
    expect(app.bookAt(next).money('cash'), 25000);
    final restarted = AppController(app.db);
    await restarted.initialize();
    expect(restarted.bookAt(day).money('cash'), 0);
    expect(restarted.bookAt(next).money('cash'), 25000);
    await restarted.deleteEntryDraft(draft.id);
    expect(restarted.book.money('cash'), 0);
    expect(
      restarted.ofKind('party').where((r) => r.name == 'New party'),
      isEmpty,
    );
    restarted.dispose();
  });

  test('Finishing a draft replaces its contribution atomically without counting it twice', () async {
    final app = await setup();
    final draft = await roz(app, 'aamad', {'party': 'Ali', 'cash': '100'});
    final seen = <int>[];
    app.addListener(() => seen.add(app.book.money('cash')));
    await app.post({
      'type': 'receipt',
      'date': day,
      'party': app.partyByName('Ali')!.id,
      'cash': 10000,
    }, draftId: draft.id);
    expect(app.entryDrafts, isEmpty);
    expect(app.book.documents, hasLength(1));
    expect(app.book.documents.single.id, draft.id);
    expect(app.book.documents.single.isDraft, isFalse);
    expect(seen, isNotEmpty);
    expect(seen.every((n) => n == 10000), isTrue);
    expect(jsonDecode((await app.db.meta('entry_drafts'))!), isEmpty);
    final reopened = AppController(app.db);
    await reopened.initialize();
    expect(reopened.book.money('cash'), 10000);
    expect(reopened.entryDrafts, isEmpty);
    reopened.dispose();
  });

  test('Failed posting keeps the draft and its balances, including a database rollback', () async {
    final app = await setup();
    final draft = await roz(app, 'aamad', {'party': 'Ali', 'cash': '100'});
    final count = app.commands.length;
    await expectLater(
      app.post({
        'type': 'receipt',
        'date': day,
        'cash': 10000,
      }, draftId: draft.id),
      throwsFormatException,
    );
    expect(app.book.money('cash'), 10000);
    expect(app.entryDraft(draft.id), isNotNull);
    await app.db.customStatement(
      "CREATE TRIGGER fail_draft_finish BEFORE UPDATE ON metadata WHEN NEW.key = 'entry_drafts' BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
    );
    await expectLater(
      app.post({
        'type': 'receipt',
        'date': day,
        'party': app.partyByName('Ali')!.id,
        'cash': 10000,
      }, draftId: draft.id),
      throwsA(anything),
    );
    expect((await app.db.commands()).length, count);
    expect(app.entryDraft(draft.id), isNotNull);
    expect(app.book.money('cash'), 10000);
    expect(
      (await app.db.effective()).where((r) => r.kind == 'document'),
      isEmpty,
    );
  });

  test('Draft purchase, shares and quoting an open draft keep FIFO and balances consistent', () async {
    final app = await setup();
    final pso = app.partyByName('PSO')!.id;
    final purchase = await composer(app, 'purchase', {
      'party': pso,
      'grams': 100000,
      'rate': 20000,
      'rateUnit': 1000,
      'amount': 100000,
      'account': 'cash',
    });
    final reference = app.book.documents.single.reference;
    final share = await roz(app, 'aamad', {
      'party': 'Ali',
      'bulk': '25',
      'bulkAtCost': true,
      'sharePurchase': reference,
      'cash': '100',
    });
    final doc = Document(app.record(share.id)!);
    expect(doc.shareCharge, 500000);
    expect(app.book.gasGrams, 75000);
    expect(app.book.money('cash'), -90000);
    expect(app.quoteBulkCost(doc.data, draftId: share.id), 500000);
    expect(
      app
          .sharePurchaseOptions(day, selected: reference, draftId: share.id)
          .single
          .$2,
      100000,
    );
    // Finish the source first. Its reference survives, so the draft share
    // keeps the same source and price.
    await app.post(purchase.data, draftId: purchase.id);
    expect(app.record(purchase.id)!.draftId, isNull);
    expect(Document(app.record(share.id)!).shareCharge, 500000);
    final before = app.book.money('cash');
    await app.post(doc.data, draftId: share.id);
    expect(app.book.money('cash'), before);
    expect(app.book.gasGrams, 75000);
    expect(app.book.documents.every((d) => !d.isDraft), isTrue);
  });

  test('Missing purchase price stays unknown and incomplete composer types do not break the book', () async {
    final app = await setup();
    await composer(app, 'purchase', {
      'party': app.partyByName('PSO')!.id,
      'grams': 100000,
    });
    await roz(app, 'aamad', {'party': 'Ali', 'q11800': '1', 'rate': '500'});
    expect(app.book.gasGrams, 88200);
    expect(app.book.uncostedSales, isNotEmpty);
    expect(app.book.lots.single.cost, isNull);
    await composer(app, 'creditNote', {
      'sourceInvoice': 'missing',
      'stockReturned': true,
    });
    await composer(app, 'cylinder', {});
    await composer(app, 'adjustment', {});
    expect(app.book.gasGrams, 88200);
    expect(app.book.money('cash'), 0);
    await roz(app, 'aamad', {
      'cash': '123.45',
      'bank': 'oops',
      'q11800': '-2',
      'rate': 'oops',
    });
    expect(app.book.money('cash'), 12345);
    expect(app.book.gasGrams, 88200);
  });

  test(
    'Snapshots contain posted entries, and closing refuses outstanding drafts',
    () async {
      final app = await setup();
      await app.post({
        'type': 'receipt',
        'date': day,
        'party': app.partyByName('Ali')!.id,
        'cash': 10000,
      });
      final draft = await roz(app, 'aamad', {'party': 'Ali', 'cash': '25'});
      await app.saveSnapshot();
      final snapshot = app.ofKind('snapshot').single;
      expect(snapshot.data['documents'] as List, hasLength(1));
      await app.restoreSnapshot(snapshot, 'restore test');
      expect(app.entryDraft(draft.id), isNotNull);
      expect(app.book.money('cash'), 12500);
      expect(app.book.documents, hasLength(2));
      await expectLater(
        app.closeDay(reason: 'close'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('drafts'),
          ),
        ),
      );
      final state = [for (final r in app.records) r];
      state.add(const Record('close', 'close', {'date': day, 'closed': true}));
      app.records = state;
      await expectLater(
        roz(app, 'aamad', {'cash': '10'}, id: draft.id),
        throwsStateError,
      );
      await expectLater(app.deleteEntryDraft(draft.id), throwsStateError);
    },
  );

  test('Named parties shared by drafts are visible locally and materialize only when posting', () async {
    final app = await setup();
    await roz(app, 'aamad', {'party': 'New company', 'cash': '50'});
    await roz(app, 'kharcha', {
      'kind': 'company',
      'party': ' new   company ',
      'amount': '20',
    });
    final party = app
        .ofKind('party')
        .singleWhere((r) => r.name == 'New company');
    expect(party.data['customer'], isTrue);
    expect(party.data['supplier'], isTrue);
    expect(app.book.partyBalance(party.id), -3000);
    expect(app.records.any((r) => r.id == party.id), isFalse);
    await app.post({
      'type': 'purchase',
      'date': day,
      'party': party.id,
      'grams': 1000,
      'rate': 10000,
      'rateUnit': 1000,
    });
    expect(app.records.any((r) => r.id == party.id), isTrue);
    expect(app.book.partyBalance(party.id), -13000);
    expect(Book(await app.db.effective()).partyBalance(party.id), -10000);
  });
}
