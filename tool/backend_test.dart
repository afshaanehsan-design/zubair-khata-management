// Local PostgreSQL integration test. Only connects to the isolated test port.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/features/ledger/book.dart';

class Pg {
  final Socket socket;
  final List<int> buffer = [];
  Completer<List<List<String?>>>? pending;
  List<List<String?>> rows = [];
  String? error;
  Pg(this.socket) {
    socket.listen(_read);
  }
  static Future<Pg> connect() async {
    final pg = Pg(await Socket.connect('127.0.0.1', 55439));
    final payload = [
      0,
      3,
      0,
      0,
      ...utf8.encode(
        'user\u0000postgres\u0000database\u0000postgres\u0000client_encoding\u0000UTF8\u0000\u0000',
      ),
    ];
    pg.pending = Completer();
    pg.socket.add([..._int(payload.length + 4), ...payload]);
    await pg.pending!.future;
    return pg;
  }

  static List<int> _int(int n) =>
      (ByteData(4)..setInt32(0, n)).buffer.asUint8List();
  Future<List<List<String?>>> query(String sql) async {
    if (pending != null) throw StateError('Query already running');
    rows = [];
    error = null;
    final done = Completer<List<List<String?>>>();
    pending = done;
    final text = utf8.encode('$sql\u0000');
    socket.add([81, ..._int(text.length + 4), ...text]);
    return done.future.timeout(const Duration(seconds: 60));
  }

  void _read(List<int> data) {
    buffer.addAll(data);
    while (buffer.length >= 5) {
      final length = ByteData.sublistView(
        Uint8List.fromList(buffer.sublist(1, 5)),
      ).getInt32(0);
      if (buffer.length < length + 1) return;
      final type = buffer.first,
          body = Uint8List.fromList(buffer.sublist(5, length + 1));
      buffer.removeRange(0, length + 1);
      if (type == 69) {
        error = utf8
            .decode(body)
            .split('\u0000')
            .where((s) => s.startsWith('M') || s.startsWith('C'))
            .join(' ');
      }
      if (type == 68) {
        final row = <String?>[];
        final view = ByteData.sublistView(body);
        var offset = 2;
        for (var i = 0; i < view.getInt16(0); i++) {
          final len = view.getInt32(offset);
          offset += 4;
          row.add(
            len < 0 ? null : utf8.decode(body.sublist(offset, offset + len)),
          );
          if (len > 0) offset += len;
        }
        rows.add(row);
      }
      if (type == 90) {
        final done = pending;
        pending = null;
        if (error == null) {
          done?.complete(rows);
        } else {
          done?.completeError(StateError(error!));
        }
      }
    }
  }

  Future<void> close() async {
    await socket.close();
  }
}

void check(bool condition, String label) {
  if (!condition) throw StateError('FAILED: $label');
  stdout.writeln('PASS $label');
}

String quote(String s) => "'${s.replaceAll("'", "''")}'";
Future<void> main() async {
  final sentinel = File('build/tooling/pgdata/postmaster.opts');
  if (!await sentinel.exists() ||
      !(await sentinel.readAsString()).contains('55439')) {
    throw StateError(
      'Start the isolated workspace PostgreSQL test instance first.',
    );
  }
  final pg = await Pg.connect();
  try {
    final actual = (await pg.query("select current_setting('data_directory')"))
        .single
        .single!
        .replaceAll('\\', '/')
        .toLowerCase();
    final expected = Directory('build/tooling/pgdata').absolute.path
        .replaceAll('\\', '/')
        .toLowerCase();
    if (actual != expected) {
      throw StateError(
        'Refusing to reset a database outside this workspace test cluster',
      );
    }
    await pg.query(
      "drop schema if exists khata_private cascade; drop schema if exists extensions cascade; drop schema if exists public cascade; create schema public; drop schema if exists auth cascade; create schema auth; do \$\$ begin if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if; if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$; create table auth.users(id uuid primary key); create function auth.uid() returns uuid language sql stable as \$\$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid\$\$; grant usage on schema auth to authenticated,anon; grant execute on function auth.uid() to authenticated,anon;",
    );
    final migrations =
        Directory('supabase/migrations')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.sql'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in migrations) {
      await pg.query('begin; ${await file.readAsString()} commit;');
    }
    check(true, 'Migrations apply on PostgreSQL');
    check(
      (await pg.query(
            "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='lookup_command'",
          )).single.single ==
          '0',
      'The unused lookup_command RPC is gone',
    );
    const owner = '11111111-1111-4111-8111-111111111111';
    await pg.query(
      "insert into auth.users values('$owner'),('22222222-2222-4222-8222-222222222222'); set request.jwt.claim.sub='$owner';",
    );
    final status = jsonDecode(
      (await pg.query('select public.sync_status()::text')).single.single!,
    ) as Map;
    check(status['sequence'] == 1, 'Bootstrap has one durable change bundle');
    final epoch = status['epoch'];
    var counter = 0;
    Map<String, dynamic> command(
      List<Map<String, dynamic>> changes, {
      String action = 'save',
      String reason = '',
    }) => {
      'command_id':
          'aaaaaaaa-aaaa-4aaa-8aaa-${(++counter).toString().padLeft(12, '0')}',
      'device_id': 'test',
      'epoch': epoch,
      'action': action,
      'reason': reason,
      'changes': changes,
    };
    Map<String, dynamic> change(
      String id,
      String kind,
      Map<String, dynamic> data, [
      int version = 0,
    ]) => {'id': id, 'kind': kind, 'data': data, 'expected_version': version};
    Future<Map> apply(Map c) async => jsonDecode(
      (await pg.query(
        'select public.apply_command(${quote(jsonEncode(c))}::jsonb)::text',
      )).single.single!,
    ) as Map;
    final setup = command([
      change('p', 'party', {
        'name': 'محمد علی',
        'customer': true,
        'supplier': true,
      }),
      change('b', 'account', {'name': 'HBL'}),
    ]);
    check(
      (await apply(setup))['status'] == 'accepted',
      'Party and account creation',
    );
    final fixture = command([
      change('lot', 'document', {
        'type': 'stockAdjustment',
        'date': '2026-11-07',
        'occurredAt': 0,
        'grams': 20000,
        'cost': 600000,
        'costKnown': true,
        'note': 'Opening stock',
      }),
      change('sale', 'document', {
        'type': 'sale',
        'date': '2026-11-07',
        'occurredAt': 1,
        'party': 'p',
        'quantities': {'11800': 1},
        'returned': {'11800': 1},
        'extraGrams': 1180,
        'rate': 460000,
        'cash': 100000,
        'bank': 200000,
        'bankAccount': 'b',
      }),
    ]);
    final saved = await apply(fixture);
    check(
      saved['status'] == 'accepted',
      'Financial fixture posts atomically: $saved',
    );
    final balances = await pg.query(
      "select account,sum(debit)::text from public.khata_postings where owner_id='$owner' group by account order by account",
    );
    final amounts = {for (final row in balances) row.first: row.last};
    check(
      amounts['ar:p'] == '206000' &&
          amounts['money:cash'] == '100000' &&
          amounts['money:b'] == '200000',
      'Customer, cash and bank equal the Dart fixture',
    );
    check(
      amounts['cogs'] == '389400' &&
          amounts['revenue:gas'] == '-460000' &&
          amounts['revenue:bulk'] == '-46000',
      'Server FIFO consumes cylinder and bulk KG, with separate billing',
    );
    check(
      (await pg.query(
            "select grams::text from public.khata_lots where owner_id='$owner' and id='lot'",
          )).single.single ==
          '7020',
      'Mixed sale deducts 11.8 cylinder KG plus 1.18 bulk KG',
    );
    // Exercise the upgrade with an existing owner, not just an empty schema.
    final legacy = await File('supabase/migrations/202611110002_bank_lines.sql')
        .readAsString();
    final legacyStart = legacy.indexOf(
      'create or replace function khata_private.rebuild',
    );
    final legacyEnd = legacy.indexOf('-- apply_command:', legacyStart);
    await pg.query(legacy.substring(legacyStart, legacyEnd));
    await pg.query("select khata_private.rebuild('$owner')");
    check(
      (await pg.query(
            "select grams::text from public.khata_lots where owner_id='$owner' and id='lot'",
          )).single.single ==
          '8200',
      'Upgrade fixture starts with the previous cylinder-only stock rule',
    );
    await pg.query(
      await File('supabase/migrations/202611120001_bulk_stock.sql')
          .readAsString(),
    );
    check(
      (await pg.query(
                "select grams::text from public.khata_lots where owner_id='$owner' and id='lot'",
              )).single.single ==
              '7020' &&
          (await pg.query(
                "select sequence::text from public.khata_sync where owner_id='$owner'",
              )).single.single ==
              '${saved['sequence']}',
      'Migration recalculates old bulk stock without changing documents or sync sequence',
    );
    // Restore the latest projection after exercising the earlier upgrade:
    // every later migration again, in order.
    for (final file in migrations.where(
      (f) =>
          f.uri.pathSegments.last.compareTo('202611120001_bulk_stock.sql') > 0,
    )) {
      await pg.query(await file.readAsString());
    }
    check(
      (await apply(fixture))['sequence'] == saved['sequence'],
      'Identical retry returns original receipt',
    );
    check(
      (await pg.query(
            "select count(*) from public.khata_records where id='sale'",
          )).single.single ==
          '1',
      'Retry creates no duplicate document',
    );
    final conflicting = command([
      change('p', 'party', {'name': 'Wrong overwrite'}, 0),
    ]);
    check(
      (await apply(conflicting))['status'] == 'conflict',
      'Stale master edit becomes conflict',
    );
    final invalid = command([
      change('never', 'party', {'name': 'Must rollback'}),
      change('bad', 'document', {
        'type': 'depositRefund',
        'date': '2026-11-07',
        'party': 'p',
        'amount': 999999,
        'account': 'cash',
      }),
    ]);
    check(
      (await apply(invalid))['status'] == 'rejected',
      'Invalid deposit refund rejected',
    );
    check(
      (await pg.query(
            "select count(*) from public.khata_records where id='never'",
          )).single.single ==
          '0',
      'Rejected compound command leaves no partial master record',
    );
    final credit = command([
      change('credit', 'document', {
        'type': 'creditNote',
        'date': '2026-11-07',
        'occurredAt': 2,
        'party': 'p',
        'sourceInvoice': 'sale',
        'quantities': {'11800': 1},
        'rate': 460000,
        'extraGrams': 1180,
        'stockReturned': true,
        'note': 'Full gas return',
      }),
    ]);
    final credited = await apply(credit);
    check(
      credited['status'] == 'accepted',
      'Credit note posts original FIFO return: $credited',
    );
    final refunded = await pg.query(
      "select account,sum(debit)::text from public.khata_postings where owner_id='$owner' group by account",
    );
    final afterCredit = {for (final row in refunded) row.first: row.last};
    check(
      afterCredit['money:cash'] == '100000' &&
          afterCredit['money:b'] == '200000' &&
          afterCredit['ar:p'] == '-300000' &&
          afterCredit['cogs'] == '0',
      'Credit note keeps collections and reverses known cost',
    );
    check(
      (await pg.query(
            "select sum(grams)::text from public.khata_lots where owner_id='$owner'",
          )).single.single ==
          '20000',
      'Physical credit restores cylinder and bulk stock',
    );
    final bulkOnly = <String, dynamic>{
      'type': 'sale',
      'date': '2026-11-07',
      'occurredAt': 3,
      'party': 'p',
      'quantities': <String, dynamic>{},
      'extraGrams': 1180,
      'rate': 460000,
      'cash': 10000,
    };
    check(
      (await apply(
                command([change('bulk-only', 'document', bulkOnly)]),
              ))['status'] ==
              'accepted' &&
          (await pg.query(
                "select sum(grams)::text from public.khata_fifo where owner_id='$owner' and sale='bulk-only'",
              )).single.single ==
              '1180' &&
          (await pg.query(
                "select sum(debit)::text from public.khata_postings where owner_id='$owner' and document_id='bulk-only' and account='cogs'",
              )).single.single ==
              '35400',
      'Bulk-only sale consumes and costs stock without any cylinder quantities',
    );
    final bulkCredit = {
      ...bulkOnly,
      'type': 'creditNote',
      'occurredAt': 4,
      'sourceInvoice': 'bulk-only',
      'stockReturned': true,
      'note': 'Bulk returned',
    };
    check(
      (await apply(
                command([change('bulk-credit', 'document', bulkCredit)]),
              ))['status'] ==
              'accepted' &&
          (await pg.query(
                "select sum(grams)::text from public.khata_lots where owner_id='$owner'",
              )).single.single ==
              '20000',
      'A bulk-only physical credit restores stock even with zero cylinder KG',
    );
    final less = await apply(
      command([
        change('less-bank', 'document', {
          'type': 'receipt',
          'date': '2026-11-07',
          'occurredAt': 9,
          'party': 'p',
          'bank': 5000,
          'bankAccount': 'b',
          'vehicle': '93',
          'form': 'less',
          'junk': 'dropped',
        }),
      ]),
    );
    final stored = jsonDecode(
      (await pg.query(
        "select data::text from public.khata_records where owner_id='$owner' and id='less-bank'",
      )).single.single!,
    ) as Map;
    check(
      less['status'] == 'accepted' &&
          stored['form'] == 'less' &&
          stored['vehicle'] == '93' &&
          !stored.containsKey('junk'),
      'Roznamcha form and receipt parchi survive canonicalisation',
    );
    // Udhar wapsi: a payment that reduces what is owed to the party (ap:),
    // exactly like the client's Book; its form is display-only.
    final wapsi = await apply(
      command([
        change('udhar-wapsi', 'document', {
          'type': 'payment',
          'date': '2026-11-07',
          'occurredAt': 10,
          'party': 'p',
          'amount': 7000,
          'account': 'cash',
          'supplierPayment': true,
          'form': 'udharWapsi',
        }),
      ]),
    );
    final wapsiStored = jsonDecode(
      (await pg.query(
        "select data::text from public.khata_records where owner_id='$owner' and id='udhar-wapsi'",
      )).single.single!,
    ) as Map;
    final wapsiPostings = {
      for (final row in await pg.query(
        "select account,sum(debit)::text from public.khata_postings where owner_id='$owner' and document_id='udhar-wapsi' group by account",
      ))
        row.first: row.last,
    };
    check(
      wapsi['status'] == 'accepted' &&
          wapsiStored['form'] == 'udharWapsi' &&
          wapsiStored['supplierPayment'] == true &&
          wapsiPostings['ap:p'] == '7000' &&
          wapsiPostings['money:cash'] == '-7000',
      'Udhar wapsi keeps its form and reduces the payable like the client: $wapsiPostings',
    );

    // Direct to Party: a customer pays a company itself. The amount moves
    // from the customer's khata to the company's and no money account moves,
    // exactly like the client's Book (test/direct_to_party_test.dart).
    await apply(
      command([
        change('co', 'party', {
          'name': 'Supreme Petroleum',
          'customer': false,
          'supplier': true,
        }),
      ]),
    );
    final direct = await apply(
      command([
        change('direct', 'document', {
          'type': 'receipt',
          'date': '2026-11-07',
          'occurredAt': 11,
          'party': 'p',
          'direct': 40000,
          'directParty': 'co',
          'form': 'aamad',
        }),
        change('direct-sale', 'document', {
          'type': 'sale',
          'date': '2026-11-07',
          'occurredAt': 12,
          'party': 'p',
          'quantities': {'11800': 1},
          'rate': 460000,
          'customerOwned': true,
          'cash': 100000,
          'direct': 360000,
          'directParty': 'co',
        }),
      ]),
    );
    Future<Map<String?, String?>> postingsOf(String id) async => {
      for (final row in await pg.query(
        "select account,sum(debit)::text from public.khata_postings where owner_id='$owner' and document_id='$id' and (account like 'ar:%' or account like 'ap:%' or account like 'money:%') group by account",
      ))
        row.first: row.last,
    };
    final directPostings = await postingsOf('direct');
    final directSale = await postingsOf('direct-sale');
    final directStored = jsonDecode(
      (await pg.query(
        "select data::text from public.khata_records where owner_id='$owner' and id='direct'",
      )).single.single!,
    ) as Map;
    check(
      direct['status'] == 'accepted' &&
          directStored['direct'] == 40000 &&
          directStored['directParty'] == 'co' &&
          directPostings.length == 2 &&
          directPostings['ap:co'] == '40000' &&
          directPostings['ar:p'] == '-40000',
      'Direct to Party moves the amount from the customer to the company: $direct $directPostings',
    );
    check(
      directSale['ar:p'] == '0' &&
          directSale['ap:co'] == '360000' &&
          directSale['money:cash'] == '100000' &&
          directSale.length == 3,
      'A sale can be paid in cash and directly to the company: $directSale',
    );
    var directCase = 0;
    Future<Map> directReceipt(Map<String, dynamic> data) => apply(
      command([
        change('direct-bad-${++directCase}', 'document', {
          'type': 'receipt',
          'date': '2026-11-07',
          'party': 'p',
          ...data,
        }),
      ]),
    );
    final noParty = await directReceipt({'direct': 100});
    final sameParty = await directReceipt({'direct': 100, 'directParty': 'p'});
    final refund = await directReceipt({
      'direct': 100,
      'directParty': 'co',
      'supplierRefund': true,
    });
    final negative = await directReceipt({'direct': -100, 'directParty': 'co'});
    check(
      [noParty, sameParty, refund].every(
            (r) =>
                r['status'] == 'rejected' &&
                '${r['message']}'.contains('paid directly'),
          ) &&
          negative['status'] == 'rejected',
      'Direct to Party needs another, existing party and a customer receipt: $noParty $sameParty $refund $negative',
    );
    final coDelete = await apply(
      command([
        change('co', 'party', {
          'name': 'Supreme Petroleum',
          'customer': false,
          'supplier': true,
          'deleted': true,
        }, 1),
      ]),
    );
    check(
      coDelete['status'] == 'rejected' &&
          '${coDelete['message']}'.contains('has entries'),
      'A party that was paid directly cannot be deleted: $coDelete',
    );
    await apply(
      command([
        change('direct-payment', 'document', {
          'type': 'payment',
          'date': '2026-11-07',
          'party': 'p',
          'amount': 100,
          'account': 'cash',
          'direct': 100,
          'directParty': 'co',
        }),
      ]),
    );
    check(
      (await pg.query(
            "select (data ? 'direct' or data ? 'directParty')::text from public.khata_records where owner_id='$owner' and id='direct-payment'",
          )).single.single ==
          'false',
      'Other kinds of entry do not keep the direct fields',
    );

    // Multiple destinations, canonical fields and the same postings as Book.
    await apply(
      command([
        change('b2', 'account', {'name': 'Meezan'}),
        change('line-co', 'party', {'name': 'Line Company', 'supplier': true}),
        change('line-deleted', 'party', {
          'name': 'Deleted Line Company',
          'deleted': true,
        }),
      ]),
    );
    final lineData = <String, dynamic>{
      'type': 'receipt',
      'date': '2026-11-07',
      'party': 'p',
      'directBank': 'Legacy label',
      'bankLines': [
        {'amount': 1100, 'account': 'b'},
        {'amount': 2200, 'account': 'b2'},
        {'amount': 3300, 'party': 'line-co', 'bankName': 'UBL'},
      ],
      'allocations': {'sale': 6600},
    };
    final lineResult = await apply(
      command([change('bank-lines', 'document', lineData)]),
    );
    final client = Book([Record('bank-lines', 'document', lineData)]);
    final expectedLines = <String, String>{};
    for (final p in client.postings) {
      expectedLines[p.account] =
          '${integer(expectedLines[p.account]) + p.debit}';
    }
    final serverLines = await postingsOf('bank-lines');
    check(
      lineResult['status'] == 'accepted' &&
          canonicalJson(serverLines) == canonicalJson(expectedLines),
      'Two bank accounts and a named direct line match client postings: $lineResult $serverLines',
    );
    final lineStored = jsonDecode(
      (await pg.query(
        "select data::text from public.khata_records where owner_id='$owner' and id='bank-lines'",
      )).single.single!,
    ) as Map;
    check(
      canonicalJson(lineStored['bankLines']) ==
              canonicalJson(lineData['bankLines']) &&
          lineStored['directBank'] == 'Legacy label',
      'bankLines and directBank survive receipt canonicalisation',
    );
    final canonicalSale = jsonDecode(
      (await pg.query(
        'select khata_private.canonical_document(${quote(jsonEncode({...lineData, 'type': 'sale'}))}::jsonb)::text',
      )).single.single!,
    ) as Map;
    check(
      canonicalJson(canonicalSale['bankLines']) ==
              canonicalJson(lineData['bankLines']) &&
          canonicalSale['directBank'] == 'Legacy label',
      'bankLines and directBank survive sale canonicalisation',
    );
    for (final (data, message) in <(Map<String, dynamic>, String)>[
      ({'bankLines': {}}, 'Invalid bank lines'),
      (
        {
          'bankLines': [
            {'amount': 1, 'account': 'b', 'party': 'co'},
          ],
        },
        'Invalid bank lines',
      ),
      (
        {
          'bankLines': [
            {'amount': 0, 'account': 'b'},
          ],
        },
        'Invalid bank lines',
      ),
      (
        {
          'bankLines': [
            {'amount': 1, 'account': 'cash'},
          ],
        },
        'Choose a bank account',
      ),
      (
        {
          'bankLines': [
            {'amount': 1, 'account': 'b', 'extra': true},
          ],
        },
        'Invalid bank lines',
      ),
      (
        {
          'bankLines': [
            {'amount': 1, 'account': 'b'},
          ],
          'type': 'payment',
          'amount': 1,
        },
        'Invalid bank lines',
      ),
      (
        {
          'bankLines': [
            {'amount': 1, 'account': 'b'},
          ],
          'supplierRefund': true,
        },
        'Invalid bank lines',
      ),
      (
        {
          'bankLines': [
            {'amount': 1, 'party': 'p'},
          ],
        },
        'Choose the party that was paid directly',
      ),
      (
        {
          'bankLines': [
            {'amount': 1, 'party': 'line-deleted'},
          ],
        },
        'Choose the party that was paid directly',
      ),
      ({'directBank': 'x' * 121}, 'Invalid bank lines'),
      (
        {
          'allocations': {'sale': 6601},
        },
        'Allocation exceeds collection',
      ),
    ]) {
      // Call validation on raw data too: canonicalisation deliberately drops
      // customer collection fields from other entry types, including payments.
      Object? failure;
      try {
        await pg.query(
          "select khata_private.validate_document('$owner',${quote(jsonEncode({...lineData, ...data}))}::jsonb,'bank-lines-bad')",
        );
      } catch (e) {
        failure = e;
      }
      check(
        failure != null && '$failure'.contains(message),
        'Bank line rejection: $data → $message ($failure)',
      );
    }
    final lineDelete = await apply(
      command([
        change('line-co', 'party', {
          'name': 'Line Company',
          'supplier': true,
          'deleted': true,
        }, 1),
      ]),
    );
    check(
      lineDelete['status'] == 'rejected' &&
          '${lineDelete['message']}'.contains('has entries'),
      'A party referenced only inside bankLines cannot be deleted',
    );
    await apply(
      command(
        [
          change('bank-lines', 'document', {
            ...lineStored.cast<String, dynamic>(),
            'voided': true,
            'voidReason': 'Test complete',
          }, 1),
        ],
        action: 'void',
        reason: 'Test complete',
      ),
    );

    // Deleting a party: only without live entries, final, and the name is free.
    final blockedDelete = await apply(
      command([
        change('p', 'party', {
          'name': 'محمد علی',
          'customer': true,
          'supplier': true,
          'deleted': true,
        }, 1),
      ]),
    );
    check(
      blockedDelete['status'] == 'rejected' &&
          '${blockedDelete['message']}'.contains('has entries'),
      'A party with entries cannot be deleted: $blockedDelete',
    );
    await apply(
      command([
        change('gone', 'party', {'name': 'Mian Tariq', 'customer': true}),
      ]),
    );
    check(
      (await apply(
            command([
              change('gone', 'party', {
                'name': 'Mian Tariq',
                'customer': true,
                'deleted': true,
              }, 1),
            ]),
          ))['status'] ==
          'accepted',
      'A party without entries can be deleted',
    );
    check(
      (await apply(
            command([
              change('gone2', 'party', {'name': 'mian  tariq'}),
            ]),
          ))['status'] ==
          'accepted',
      'A deleted party\'s name can be used again',
    );
    check(
      (await apply(
            command([
              change('gone-receipt', 'document', {
                'type': 'receipt',
                'date': '2026-11-08',
                'party': 'gone',
                'cash': 100,
              }),
            ]),
          ))['status'] ==
          'rejected',
      'A deleted party takes no new entries',
    );
    check(
      (await pg.query(
            "select count(*) from public.khata_records where id='gone-receipt'",
          )).single.single ==
          '0',
      'The refused entry left nothing behind',
    );
    check(
      (await apply(
            command([
              change('gone', 'party', {
                'name': 'Mian Tariq',
                'customer': true,
                'deleted': false,
              }, 2),
            ]),
          ))['status'] ==
          'rejected',
      'A deleted party cannot be restored',
    );
    check(
      (await apply(
            command([
              change('b', 'account', {'name': 'HBL', 'deleted': true}, 1),
            ]),
          ))['status'] ==
          'rejected',
      'Only a party can be deleted',
    );
    await apply(
      command([
        change('v', 'party', {'name': 'Voided only'}),
        change('vdoc', 'document', {
          'type': 'receipt',
          'date': '2026-11-08',
          'party': 'v',
          'cash': 100,
        }),
      ]),
    );
    final vdoc = jsonDecode(
      (await pg.query(
        "select data::text from public.khata_records where owner_id='$owner' and id='vdoc'",
      )).single.single!,
    ) as Map<String, dynamic>;
    await apply(
      command(
        [
          change('vdoc', 'document', {
            ...vdoc,
            'voided': true,
            'voidReason': 'Wrong customer',
          }, 1),
        ],
        action: 'void',
        reason: 'Wrong customer',
      ),
    );
    check(
      (await apply(
            command([
              change('v', 'party', {'name': 'Voided only', 'deleted': true}, 1),
            ]),
          ))['status'] ==
          'accepted',
      'Voided entries do not block deleting a party',
    );
    final peer = await Pg.connect();
    await peer.query("set request.jwt.claim.sub='$owner'");
    await pg.query(
      "begin; select sequence from public.khata_sync where owner_id='$owner' for update;",
    );
    final waiting = peer.query(
      'select public.apply_command(${quote(jsonEncode(command([
        change('peer', 'party', {'name': 'Peer device'}),
      ])))}::jsonb)::text',
    );
    final first = await apply(
      command([
        change('locked', 'party', {'name': 'First commit'}),
      ]),
    );
    await pg.query('commit;');
    final second = jsonDecode((await waiting).single.single!) as Map;
    check(
      second['sequence'] == (first['sequence'] as int) + 1,
      'Owner lock orders concurrent device commits',
    );
    await peer.close();
    // Shared purchases recover actual stock cost without sales or COGS.
    final stockBeforeSharing = integer(
      (await pg.query(
        "select coalesce(sum(grams),0)::text from public.khata_lots where owner_id='$owner'",
      )).single.single,
    );
    check(
      (await apply(
            command([
              change('sharing-stock', 'document', {
                'type': 'stockAdjustment',
                'date': '2026-11-09',
                'occurredAt': 0,
                'grams': 50000,
                'cost': 1500000,
                'costKnown': true,
                'note': 'Sharing purchase',
              }),
            ]),
          ))['status'] ==
          'accepted',
      'Dated purchase stock is available for sharing',
    );
    final shared = <String, dynamic>{
      'type': 'sale',
      'date': '2026-11-09',
      'occurredAt': 1,
      'party': 'p',
      'quantities': <String, int>{},
      'extraGrams': 1000,
      'bulkAtCost': true,
      'bulkCost': 30000,
      'cash': 10000,
      'bank': 5000,
      'bankAccount': 'b',
    };
    final sharedResult = await apply(
      command([change('shared-pure', 'document', shared)]),
    );
    final sharedPostings = {
      for (final row in await pg.query(
        "select account,sum(debit)::text from public.khata_postings where owner_id='$owner' and document_id='shared-pure' group by account",
      ))
        row.first: row.last,
    };
    check(
      sharedResult['status'] == 'accepted' &&
          sharedPostings['ar:p'] == '15000' &&
          sharedPostings['inventory'] == '-30000' &&
          sharedPostings['purchase-share:cost'] == '0' &&
          !sharedPostings.containsKey('cogs') &&
          !sharedPostings.containsKey('revenue:bulk'),
      'Pure purchase share charges exact cost and posts neither sales nor COGS: $sharedResult $sharedPostings',
    );
    final mixedShare = <String, dynamic>{
      ...shared,
      'occurredAt': 2,
      'quantities': {'11800': 1},
      'customerOwned': true,
      'rate': 460000,
      'extraGrams': 1180,
      'bulkCost': 35400,
      'cash': 0,
      'bank': 0,
    };
    final mixedResult = await apply(
      command([change('shared-mixed', 'document', mixedShare)]),
    );
    final allClientRecords = [
      for (final row in await pg.query(
        "select id,kind,data::text from public.khata_records where owner_id='$owner'",
      ))
        Record(
          row[0]!,
          row[1]!,
          Map<String, dynamic>.from(jsonDecode(row[2]!) as Map),
        ),
    ];
    final sharedClient = Book(allClientRecords);
    final expectedMixed = <String, String>{};
    for (final posting in sharedClient.postings.where(
      (p) => p.document == 'shared-mixed',
    )) {
      expectedMixed[posting.account] =
          '${integer(expectedMixed[posting.account]) + posting.debit}';
    }
    final actualMixed = {
      for (final row in await pg.query(
        "select account,sum(debit)::text from public.khata_postings where owner_id='$owner' and document_id='shared-mixed' group by account",
      ))
        row.first: row.last,
    };
    check(
      mixedResult['status'] == 'accepted' &&
          canonicalJson(actualMixed) == canonicalJson(expectedMixed) &&
          actualMixed['cogs'] == '354000' &&
          actualMixed['purchase-share:cost'] == '0' &&
          actualMixed['revenue:gas'] == '-460000' &&
          !actualMixed.containsKey('revenue:bulk'),
      'Mixed cylinder sale and purchase share agree exactly with client FIFO postings: $mixedResult $actualMixed',
    );
    final staleShare = await apply(
      command([
        change('stale-share', 'document', {
          ...shared,
          'occurredAt': 3,
          'bulkCost': 40000,
        }),
      ]),
    );
    final missingShare = await apply(
      command([
        change('unavailable-share', 'document', {
          ...shared,
          'occurredAt': 3,
          'extraGrams': 1000000,
        }),
      ]),
    );
    check(
      staleShare['status'] == 'rejected' &&
          staleShare['message'] ==
              'Purchase-share cost changed; refresh the entry' &&
          missingShare['status'] == 'rejected' &&
          missingShare['message'] ==
              'Enter dated stock and purchase cost before sharing gas',
      'Cloud refuses stale at-cost quotes and uncosted or unavailable shared stock: $staleShare $missingShare',
    );
    final changedPurchase = await apply(
      command(
        [
          change('sharing-stock', 'document', {
            'type': 'stockAdjustment',
            'date': '2026-11-09',
            'occurredAt': 0,
            'grams': 50000,
            'cost': 1500000,
            'costKnown': true,
            'note': 'Sharing purchase',
            'voided': true,
            'voidReason': 'Correct supplier cost',
            'replacement': 'sharing-stock-corrected',
          }, 1),
          change('sharing-stock-corrected', 'document', {
            'type': 'stockAdjustment',
            'date': '2026-11-09',
            'occurredAt': 0,
            'grams': 50000,
            'cost': 2000000,
            'costKnown': true,
            'note': 'Sharing purchase',
            'replaces': 'sharing-stock',
          }),
        ],
        action: 'correct',
        reason: 'Correct supplier cost',
      ),
    );
    check(
      changedPurchase['status'] == 'accepted' &&
          (await pg.query(
                "select sum(debit)::text from public.khata_postings where owner_id='$owner' and account='purchase-share:cost'",
              )).single.single ==
              '11800' &&
          (await pg.query(
                "select data->>'bulkCost' from public.khata_records where owner_id='$owner' and id='shared-mixed'",
              )).single.single ==
              '35400',
      'Backdated cost corrections expose recovery differences while preserving recorded party charges: $changedPurchase',
    );
    final shareReturns = await apply(
      command([
        change('shared-mixed-return', 'document', {
          ...mixedShare,
          'type': 'creditNote',
          'occurredAt': 4,
          'sourceInvoice': 'shared-mixed',
          'stockReturned': true,
          'note': 'Mixed gas returned',
        }),
        change('shared-pure-return', 'document', {
          ...shared,
          'type': 'creditNote',
          'occurredAt': 5,
          'sourceInvoice': 'shared-pure',
          'stockReturned': true,
          'note': 'Shared gas returned',
        }),
      ]),
    );
    check(
      shareReturns['status'] == 'accepted' &&
          integer(
                (await pg.query(
                  "select sum(grams)::text from public.khata_lots where owner_id='$owner'",
                )).single.single,
              ) ==
              stockBeforeSharing + 50000 &&
          (await pg.query(
                "select sum(debit)::text from public.khata_postings where owner_id='$owner' and account='purchase-share:cost'",
              )).single.single ==
              '0',
      'Pure and mixed sharing returns restore all stock and clear cost recovery: $shareReturns',
    );
    for (final badShare in <Map<String, dynamic>>[
      {...shared, 'bulkAtCost': 'true'},
      {...shared, 'bulkCost': -1},
      {...shared, 'bulkCost': 1.5},
      {...shared}..remove('bulkCost'),
      {...shared, 'extraGrams': 0},
      {...shared, 'depositCharge': 100},
    ]) {
      String? message;
      try {
        await pg.query(
          'select khata_private.validate_document(\'$owner\',${quote(jsonEncode(badShare))}::jsonb,\'share-validation\')',
        );
      } catch (e) {
        message = '$e';
      }
      check(
        message?.contains('Choose a valid purchase-share quantity and cost') ==
            true,
        'Purchase-sharing field validation matches the client: $badShare',
      );
    }
    // Sales entered before their purchase wait for it and take its cost, on
    // their own date; the server must post exactly what the client does.
    Future<List<Record>> serverRecords() async => [
      for (final row in await pg.query(
        "select id,kind,data::text from public.khata_records where owner_id='$owner'",
      ))
        Record(
          row[0]!,
          row[1]!,
          Map<String, dynamic>.from(jsonDecode(row[2]!) as Map),
        ),
    ];
    Future<void> sameAsClient(String label) async {
      final client = Book(await serverRecords());
      final expected = <String, int>{};
      for (final p in client.postings) {
        final key = '${p.document}|${p.date}|${p.account}';
        expected[key] = (expected[key] ?? 0) + p.debit;
      }
      expected.removeWhere((k, v) => v == 0);
      final actual = <String, int>{
        for (final row in await pg.query(
          "select document_id,date::text,account,sum(debit)::text from public.khata_postings where owner_id='$owner' group by 1,2,3 having sum(debit)<>0",
        ))
          '${row[0]}|${row[1]}|${row[2]}': integer(row[3]),
      };
      final diff = {
        for (final k in {...expected.keys, ...actual.keys})
          if (expected[k] != actual[k]) k: '${expected[k]} vs ${actual[k]}',
      };
      final serverLots = {
        for (final row in await pg.query(
          "select id,grams::text,coalesce(cost::text,'?') from public.khata_lots where owner_id='$owner'",
        ))
          row[0]!: '${row[1]}/${row[2]}',
      };
      final clientLots = {
        for (final l in client.lots) l.id: '${l.grams}/${l.cost ?? '?'}',
      };
      check(
        diff.isEmpty && canonicalJson(serverLots) == canonicalJson(clientLots),
        '$label: $diff ${canonicalJson(serverLots)} vs ${canonicalJson(clientLots)}',
      );
    }

    final stockLeft = integer(
      (await pg.query(
        "select coalesce(sum(grams),0)::text from public.khata_lots where owner_id='$owner'",
      )).single.single,
    );
    Map<String, dynamic> backorderDoc(
      String type,
      int time,
      Map<String, dynamic> data, {
      String date = '2026-11-20',
    }) => {
      'type': type,
      'date': date,
      'occurredAt': time,
      'party': 'p',
      ...data,
    };
    final shareLater = backorderDoc('sale', 3, {
      'quantities': <String, int>{},
      'extraGrams': 20000,
      'bulkAtCost': true,
    });
    check(
      (await apply(
            command([
              if (stockLeft > 0)
                change(
                  'bo-count',
                  'document',
                  backorderDoc('stockAdjustment', 0, {
                    'grams': -stockLeft,
                    'cost': 0,
                    'costKnown': false,
                    'note': 'Counted empty',
                  }),
                ),
              change(
                'bo-sale-1',
                'document',
                backorderDoc('sale', 1, {
                  'quantities': {'45000': 2},
                  'customerOwned': true,
                  'rate': 577000,
                }),
              ),
              change(
                'bo-loss',
                'document',
                backorderDoc('stockAdjustment', 2, {
                  'grams': -5000,
                  'cost': 0,
                  'costKnown': false,
                  'note': 'Leak',
                }),
              ),
            ]),
          ))['status'] ==
          'accepted',
      'A sale and a stock loss with no stock are accepted and wait',
    );
    final noStockShare = await apply(
      command([
        change('bo-share-early', 'document', {...shareLater, 'bulkCost': 0}),
      ]),
    );
    check(
      noStockShare['status'] == 'rejected' &&
          noStockShare['message'] ==
              'Enter dated stock and purchase cost before sharing gas',
      'A share with no stock now or later is refused: $noStockShare',
    );
    final laterPurchase = await apply(
      command([
        change(
          'bo-purchase',
          'document',
          backorderDoc('purchase', 9, {
            'grams': 200000,
            'rate': 572000,
            'rateUnit': 11800,
            'amount': 0,
            'account': 'cash',
          }),
        ),
      ]),
    );
    check(
      laterPurchase['status'] == 'accepted',
      'The purchase entered after its sales is accepted: $laterPurchase',
    );
    await sameAsClient('A later purchase costs the waiting sale and stock loss');
    final waitingCosts = {
      for (final row in await pg.query(
        "select document_id,date::text,account,debit::text from public.khata_postings where owner_id='$owner' and document_id in ('bo-sale-1','bo-loss','bo-purchase') and account in ('cogs','expense:Stock loss','cogs:shortage')",
      ))
        '${row[0]}|${row[1]}|${row[2]}': row[3],
    };
    check(
      waitingCosts.keys.toSet().containsAll({
            'bo-sale-1|2026-11-20|cogs',
            'bo-loss|2026-11-20|expense:Stock loss',
          }) &&
          !waitingCosts.keys.any((k) => k.startsWith('bo-purchase')) &&
          !waitingCosts.keys.any((k) => k.endsWith('cogs:shortage')),
      'Waiting gas is costed on its own documents, not as a shortage on the purchase: $waitingCosts',
    );
    Future<int> clientCharge(String id, Map<String, dynamic> data) async {
      final candidate = Record(id, 'document', {...data, 'bulkCost': 0});
      return Book([
        ...await serverRecords(),
        candidate,
      ]).shareChargeFor(Document(candidate));
    }

    final quoted = await clientCharge('bo-share', shareLater);
    final staleLater = await apply(
      command([
        change('bo-share-stale', 'document', {
          ...shareLater,
          'bulkCost': quoted + 1,
        }),
      ]),
    );
    final pricedLater = await apply(
      command([
        change('bo-share', 'document', {...shareLater, 'bulkCost': quoted}),
      ]),
    );
    check(
      quoted > 0 &&
          staleLater['status'] == 'rejected' &&
          staleLater['message'] ==
              'Purchase-share cost changed; refresh the entry' &&
          pricedLater['status'] == 'accepted',
      'A share entered before its purchase is priced from it at the client quote: $quoted $staleLater $pricedLater',
    );
    await sameAsClient('A share before its purchase posts like the client');
    check(
      (await apply(
            command([
              change(
                'bo-sale-0',
                'document',
                backorderDoc('sale', 1, {
                  'quantities': {'45000': 4},
                  'customerOwned': true,
                  'rate': 577000,
                }, date: '2026-11-19'),
              ),
            ]),
          ))['status'] ==
          'accepted',
      'A back-entered earlier sale is accepted although it moves an existing share',
    );
    await sameAsClient('Back-entered sale reorders waiting gas like the client');
    final purchaseRow = (await pg.query(
      "select data::text,version::text from public.khata_records where owner_id='$owner' and id='bo-purchase'",
    )).single;
    final voided = await apply(
      command(
        [
          change('bo-purchase', 'document', {
            ...Map<String, dynamic>.from(jsonDecode(purchaseRow[0]!) as Map),
            'voided': true,
            'voidReason': 'Wrong supplier',
          }, integer(purchaseRow[1])),
        ],
        action: 'void',
        reason: 'Wrong supplier',
      ),
    );
    check(
      voided['status'] == 'accepted',
      'Voiding the purchase under an existing share is accepted: $voided',
    );
    await sameAsClient('With the purchase voided the share waits like the client');
    final waitingSale = backorderDoc('sale', 1, {
      'quantities': {'45000': 1},
      'customerOwned': true,
      'rate': 577000,
    }, date: '2026-11-21');
    check(
      (await apply(
            command([
              change('bo-sale-2', 'document', waitingSale),
              change('bo-return', 'document', {
                ...waitingSale,
                'type': 'creditNote',
                'occurredAt': 2,
                'sourceInvoice': 'bo-sale-2',
                'stockReturned': true,
                'note': 'Returned before any stock',
              }),
            ]),
          ))['status'] ==
          'accepted',
      'Returning an invoice whose gas still waits is accepted',
    );
    await sameAsClient('A return cancels waiting gas like the client');
    check(
      (await apply(
            command([
              change(
                'bo-purchase-2',
                'document',
                backorderDoc('purchase', 1, {
                  'grams': 300000,
                  'rate': 571000,
                  'rateUnit': 11800,
                  'amount': 0,
                  'account': 'cash',
                }, date: '2026-11-22'),
              ),
            ]),
          ))['status'] ==
          'accepted',
      'A new purchase covers everything still waiting',
    );
    await sameAsClient('The new purchase covers waiting gas like the client');
    final secondShare = backorderDoc('sale', 2, {
      'quantities': <String, int>{},
      'extraGrams': 3000,
      'bulkAtCost': true,
    }, date: '2026-11-22');
    final secondQuote = await clientCharge('bo-share-2', secondShare);
    check(
      (await apply(
                command([
                  change('bo-share-2', 'document', {
                    ...secondShare,
                    'bulkCost': secondQuote,
                  }),
                ]),
              ))['status'] ==
              'accepted' &&
          (await apply(
                command([
                  change('bo-share-2-credit', 'document', {
                    ...secondShare,
                    'bulkCost': secondQuote,
                    'type': 'creditNote',
                    'occurredAt': 3,
                    'sourceInvoice': 'bo-share-2',
                    'stockReturned': false,
                    'note': 'Charge forgiven',
                  }),
                ]),
              ))['status'] ==
              'accepted',
      'A share and its financial-only credit note are accepted',
    );
    await sameAsClient('A forgiven share books its gas as cost like the client');
    check(
      (await pg.query(
            "select coalesce(sum(debit),0)::text from public.khata_postings where owner_id='$owner' and document_id='bo-share-2-credit' and account='cogs'",
          )).single.single ==
          '${Book(await serverRecords()).shareCosts['bo-share-2']}',
      'The forgiven share\'s gas is cost of gas sold',
    );
    // A share from a chosen purchase (by reference): its KG come out of that
    // purchase whatever the entry order, charged the purchase's own rate.
    Map<String, dynamic> juPurchase({int rate = 572000, int grams = 29695000}) =>
        backorderDoc('purchase', 9, {
          'grams': grams,
          'rate': rate,
          'rateUnit': 11800,
          'amount': 0,
          'account': 'cash',
          'reference': 'TX-SP-JU',
        }, date: '2026-11-25');
    final chosenShare = backorderDoc('sale', 5, {
      'quantities': <String, int>{},
      'extraGrams': 14500000,
      'bulkAtCost': true,
      'sharePurchase': 'TX-SP-JU',
    }, date: '2026-11-25');
    check(
      (await apply(
            command([
              change(
                'sp-sale',
                'document',
                backorderDoc('sale', 1, {
                  'quantities': {'45000': 2},
                  'customerOwned': true,
                  'rate': 577000,
                }, date: '2026-11-25'),
              ),
              change('sp-ju', 'document', juPurchase()),
            ]),
          ))['status'] ==
          'accepted',
      'Sales and the JU purchase are accepted',
    );
    final juCharge = await clientCharge('sp-share', chosenShare);
    final exactCost = await apply(
      command([
        change('sp-share-exact', 'document', {
          ...chosenShare,
          'bulkCost': 702881335,
        }),
      ]),
    );
    final tooMuch = await apply(
      command([
        change('sp-share-over', 'document', {
          ...chosenShare,
          'extraGrams': 29695001,
          'bulkCost': 0,
        }),
      ]),
    );
    final unknown = await apply(
      command([
        change('sp-share-unknown', 'document', {
          ...chosenShare,
          'sharePurchase': 'TX-NOWHERE',
          'bulkCost': juCharge,
        }),
      ]),
    );
    final chosen = await apply(
      command([
        change('sp-share', 'document', {...chosenShare, 'bulkCost': juCharge}),
      ]),
    );
    check(
      juCharge == 702881400 &&
          exactCost['message'] ==
              'Purchase-share cost changed; refresh the entry' &&
          tooMuch['message'] == 'Shared KG exceed the selected purchase' &&
          unknown['message'] == 'Choose a purchase to share from' &&
          chosen['status'] == 'accepted',
      'A share before its chosen purchase is charged JU\'s rate in rupees, and bad ones are refused: $juCharge $exactCost $tooMuch $unknown $chosen',
    );
    await sameAsClient('A share from a chosen purchase posts like the client');
    check(
      (await pg.query(
            "select lot||':'||grams from public.khata_fifo where owner_id='$owner' and sale='sp-share'",
          )).single.single ==
          'sp-ju:14500000',
      'The share\'s KG come out of the chosen purchase',
    );
    Future<Map> correctPurchase(Map<String, dynamic> next, String id) async {
      final row = (await pg.query(
        "select id,data::text,version::text from public.khata_records where owner_id='$owner' and data->>'reference'='TX-SP-JU' and coalesce((data->>'voided')::boolean,false)=false",
      )).single;
      return apply(
        command(
          [
            change(row[0]!, 'document', {
              ...Map<String, dynamic>.from(jsonDecode(row[1]!) as Map),
              'voided': true,
              'voidReason': 'Corrected',
              'replacement': id,
            }, integer(row[2])),
            change(id, 'document', {...next, 'replaces': row[0]}),
          ],
          action: 'correct',
          reason: 'Corrected',
        ),
      );
    }

    final shrunk = await correctPurchase(juPurchase(grams: 14000000), 'sp-ju-2');
    final repriced = await correctPurchase(juPurchase(rate: 600000), 'sp-ju-3');
    check(
      shrunk['message'] == 'Shared KG exceed the selected purchase' &&
          repriced['status'] == 'accepted',
      'A purchase correction keeps its shares by reference but cannot drop below them: $shrunk $repriced',
    );
    await sameAsClient('A repriced chosen purchase posts like the client');
    final juRow = (await pg.query(
      "select data::text,version::text from public.khata_records where owner_id='$owner' and id='sp-ju-3'",
    )).single;
    final deleted = await apply(
      command(
        [
          change('sp-ju-3', 'document', {
            ...Map<String, dynamic>.from(jsonDecode(juRow[0]!) as Map),
            'voided': true,
            'voidReason': 'Entered twice',
          }, integer(juRow[1])),
        ],
        action: 'void',
        reason: 'Entered twice',
      ),
    );
    check(
      deleted['message'] == 'Change the shares of this purchase first',
      'A purchase with shares cannot be deleted: $deleted',
    );
    check(
      (await apply(
            command([
              change('sp-share-return', 'document', {
                ...chosenShare,
                'bulkCost': juCharge,
                'type': 'creditNote',
                'occurredAt': 20,
                'sourceInvoice': 'sp-share',
                'stockReturned': true,
                'note': 'Gas came back',
              }),
            ]),
          ))['status'] ==
          'accepted',
      'A chosen share\'s gas can be returned',
    );
    await sameAsClient('A returned chosen share gives the purchase back like the client');
    final head = jsonDecode(
      (await pg.query('select public.sync_status()::text')).single.single!,
    ) as Map;
    final close = command(
      [
        change('close:2026-11-07', 'close', {
          'date': '2026-11-07',
          'closed': true,
          'expected_sequence': head['sequence'],
        }),
      ],
      action: 'close',
      reason: 'Day checked',
    );
    check(
      (await apply(close))['status'] == 'accepted',
      'Online close uses authoritative sequence',
    );
    final late = command([
      change('late', 'document', {
        'type': 'receipt',
        'date': '2026-11-07',
        'party': 'p',
        'cash': 100,
      }),
    ]);
    check(
      (await apply(late))['status'] == 'rejected',
      'Late offline entry cannot alter a closed date',
    );
    final changes = jsonDecode(
      (await pg.query("select public.pull_changes('$epoch',0,100)::text"))
          .single
          .single!,
    ) as List;
    check(
      List.generate(changes.length, (i) => i + 1).toString() ==
          changes.map((b) => b['sequence']).toList().toString(),
      'Durable feed remains contiguous after rejections',
    );
    await pg.query(
      "set request.jwt.claim.sub='22222222-2222-4222-8222-222222222222'; set role authenticated;",
    );
    check(
      (await pg.query('select count(*) from public.khata_records'))
              .single
              .single ==
          '0',
      'RLS isolates another owner',
    );
    await pg.query('reset role; set role anon;');
    var denied = false;
    try {
      await pg.query('select public.sync_status()');
    } catch (_) {
      denied = true;
    }
    check(denied, 'Anonymous callers cannot execute sync RPC');
    await pg.query('reset role;');

    // Settings → Reset all data.
    const other = '22222222-2222-4222-8222-222222222222';
    Future<String> count(String table, String who) async => (await pg.query(
      "select count(*) from public.$table where owner_id='$who'",
    )).single.single!;
    await pg.query(
      "set request.jwt.claim.sub='$other'; select public.sync_status();",
    );
    await pg.query("set request.jwt.claim.sub='$owner'");
    await pg.query('set role anon;');
    denied = false;
    try {
      await pg.query("select public.reset_dataset('$epoch')");
    } catch (_) {
      denied = true;
    }
    await pg.query('reset role;');
    check(denied, 'Anonymous callers cannot reset a dataset');
    var stale = false;
    try {
      await pg.query(
        "select public.reset_dataset('00000000-0000-4000-8000-000000000000')",
      );
    } catch (_) {
      stale = true;
    }
    check(
      stale && await count('khata_records', owner) != '0',
      'Reset with a stale epoch changes nothing',
    );
    final wiped = jsonDecode(
      (await pg.query("select public.reset_dataset('$epoch')::text"))
          .single
          .single!,
    ) as Map;
    check(
      wiped['epoch'] != epoch && wiped['sequence'] == 0,
      'Reset rotates the epoch and restarts the feed',
    );
    final tables = [
      for (final row in await pg.query(
        "select table_name from information_schema.columns where table_schema='public' and column_name='owner_id' and table_name<>'khata_sync' order by 1",
      ))
        row.single!,
    ];
    final left = [
      for (final t in tables)
        if (await count(t, owner) != '0') t,
    ];
    check(
      tables.length >= 7 && left.isEmpty,
      'Reset erases the owner\'s rows in every table (${tables.length}) $left',
    );
    check(
      await count('khata_records', other) == '2',
      'Reset leaves other owners untouched',
    );
    check(
      (await apply(
            command([
              change('ghost', 'party', {'name': 'Old epoch'}),
            ]),
          ))['status'] ==
          'rejected',
      'Writes with the old epoch are rejected after reset',
    );
    var oldPull = false;
    try {
      await pg.query("select public.pull_changes('$epoch',0,100)");
    } catch (_) {
      oldPull = true;
    }
    check(oldPull, 'The old epoch cannot pull after reset');
    final fresh = jsonDecode(
      (await pg.query('select public.sync_status()::text')).single.single!,
    ) as Map;
    final boot = jsonDecode(
      (await pg.query(
        "select public.pull_changes('${wiped['epoch']}',0,100)::text",
      )).single.single!,
    ) as List;
    check(
      fresh['epoch'] == wiped['epoch'] &&
          fresh['sequence'] == 1 &&
          boot.length == 1 &&
          (boot.single['records'] as List)
              .map((r) => r['id'])
              .toSet()
              .containsAll(['cash', 'business']) &&
          await count('khata_records', owner) == '2',
      'The next sync starts a fresh dataset with the defaults',
    );
  } finally {
    await pg.close();
  }
}
