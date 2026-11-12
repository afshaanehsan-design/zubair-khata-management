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
      amounts['cogs'] == '354000' &&
          amounts['revenue:gas'] == '-460000' &&
          amounts['revenue:bulk'] == '-46000',
      'Server FIFO and extra-KG billing equal Dart',
    );
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
