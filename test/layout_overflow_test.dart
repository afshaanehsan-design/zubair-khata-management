// Walks every page and the main dialogs at desktop, tablet and phone sizes,
// in English and Urdu, with the real fonts, and fails on any layout overflow
// ("BOTTOM OVERFLOWED BY …" stripes). Each problem is reported once with the
// source line that caused it and every screen/size where it shows up.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/core/models.dart';
import 'package:zubair_khata_management/core/organizations.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/components.dart';
import 'package:zubair_khata_management/ui/details.dart';
import 'package:zubair_khata_management/ui/entry_composer.dart';
import 'package:zubair_khata_management/ui/export_ui.dart';
import 'package:zubair_khata_management/ui/masters.dart';
import 'package:zubair_khata_management/ui/opening_balance.dart';
import 'package:zubair_khata_management/ui/organizations_ui.dart';
import 'package:zubair_khata_management/ui/pages.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';
import 'package:zubair_khata_management/ui/settings_page.dart';

const viewports = <String, Size>{
  'desktop 1366x720': Size(1366, 720),
  'desktop 1920x1080': Size(1920, 1080),
  'laptop 1024x700': Size(1024, 700),
  'tablet 820x1180': Size(820, 1180),
  'phone 390x844': Size(390, 844),
  'small phone 360x640': Size(360, 640),
};

Future<void> seed(AppController app) async {
  final date = app.selectedDate;
  await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
  final bank = app
      .ofKind('account')
      .firstWhere((a) => a.data['bank'] == 'HBL')
      .id;
  await app.saveMaster('party', {
    'name': 'abdul rehman',
    'customer': true,
  }, opening: 500000);
  await app.saveMaster('party', {'name': 'رضوان', 'customer': true});
  await app.saveMaster('party', {
    'name': 'Muhammad Abdul Rehman Traders and Sons Gas Agency',
    'customer': true,
    'phone': '0300-1234567',
  }, opening: 1234567800);
  await app.saveMaster('party', {
    'name': 'PSO',
    'customer': false,
    'supplier': true,
  }, supplierOpening: 300000);
  await app.saveMaster('party', {
    'name': 'استاد عثمان صاحب لاہور والے',
    'customer': false,
    'udhari': true,
  }, supplierOpening: 322500000);
  final abdul = app.partyByName('abdul rehman')!.id;
  final rizwan = app.partyByName('رضوان')!.id;
  final pso = app.partyByName('PSO')!.id;
  final usman = app.partyByName('استاد عثمان صاحب لاہور والے')!.id;
  await app.post({
    'type': 'purchase',
    'date': date,
    'occurredAt': 0,
    'party': pso,
    'grams': 1000000,
    'rate': 30000,
    'rateUnit': 1000,
  });
  await app.post({
    'type': 'sale',
    'date': date,
    'occurredAt': 1,
    'party': abdul,
    'quantities': <String, int>{},
    'extraGrams': 10000,
    'bulkAtCost': true,
    // Taken from the purchase above, so the "Share from" picker and the
    // supplier on the entry are laid out too.
    'sharePurchase': app.book.documents
        .lastWhere((d) => d.type == EntryType.purchase)
        .reference,
    'cash': 12345,
    'note': 'Shared purchase at original FIFO cost',
  });
  await app.post({
    'type': 'sale',
    'date': date,
    'party': abdul,
    'quantities': {'11800': 20, '45000': 1},
    'returned': {'11800': 5},
    'rate': 460000,
    'cash': 100000,
  });
  await app.post({
    'type': 'sale',
    'date': date,
    'party': rizwan,
    'quantities': {'15000': 3},
    'rate': 4750000,
    'bank': 2000000,
    'bankAccount': bank,
  });
  await app.post({
    'type': 'receipt',
    'date': date,
    'party': abdul,
    'cash': 9999999900,
  });
  await app.post({
    'type': 'expense',
    'date': date,
    'category': 'Generator diesel and staff lunch for the whole week',
    'amount': 250000,
  });
  await app.post({
    'type': 'transfer',
    'date': date,
    'account': 'cash',
    'toAccount': bank,
    'amount': 800000,
  });
  // One more of every other kind of entry, for the details dialog.
  final longName = app
      .partyByName('Muhammad Abdul Rehman Traders and Sons Gas Agency')!
      .id;
  final firstSale = app.book.documents.firstWhere(
    (d) => d.type == EntryType.sale && !d.purchaseShare,
  );
  await app.post({
    'type': 'sale',
    'date': date,
    'party': longName,
    'quantities': {'11800': 120, '15000': 40, '45000': 12},
    'returned': {'11800': 100},
    'rate': 460000,
    'extraGrams': 12500,
    'depositCharge': 500000,
    'cash': 100000,
    'bank': 2500000,
    'bankAccount': bank,
    'vehicle': 'LEB-1234 / parchi 98765',
    'dueDate': date,
    'note': 'Delivered to the godown behind the main market, second gate',
  });
  // Direct to Party: adds a column to the Aamad table and rows to B.
  await app.post({
    'type': 'sale',
    'date': date,
    'party': rizwan,
    'quantities': {'11800': 4},
    'rate': 460000,
    'cash': 40000,
    'direct': 1800000,
    'directParty': pso,
    'form': 'aamad',
  });
  await app.post({
    'type': 'receipt',
    'date': date,
    'party': longName,
    'direct': 4500000000,
    'directParty': usman,
    'form': 'aamad',
    'note': 'Customer ne online seedha company ke account mein bheje',
  });
  await app.post({
    'type': 'receipt',
    'date': date,
    'party': longName,
    'form': 'aamad',
    'bankLines': [
      {'amount': 1234567800, 'account': bank},
      {
        'amount': 4500000000,
        'party': usman,
        'bankName': 'United Bank Limited Main Branch Lahore Company Account',
      },
      {'amount': 1800000, 'party': pso, 'bankName': 'UBL'},
    ],
  });
  for (final entry in <Json>[
    {
      'type': 'cylinder',
      'party': abdul,
      'size': 11800,
      'cylinderMode': 'Issue',
      'count': 2,
      'fullDelta': -2,
      'emptyDelta': 0,
      'heldDelta': 2,
      'note': 'Loan',
    },
    {'type': 'stockAdjustment', 'grams': 5000, 'note': 'Found in the store'},
    {
      'type': 'creditNote',
      'party': abdul,
      'sourceInvoice': firstSale.id,
      'stockReturned': true,
      'quantities': {'11800': 20, '45000': 1},
      'rate': 460000,
      'note': 'One cylinder came back',
    },
    {'type': 'discount', 'party': abdul, 'amount': 10000},
    {'type': 'deposit', 'party': abdul, 'amount': 300000, 'account': 'cash'},
    {
      'type': 'payment',
      'party': pso,
      'amount': 50000,
      'account': bank,
      'supplierPayment': true,
      'branch': 'Lahore',
    },
    {
      'type': 'payment',
      'party': usman,
      'amount': 150000000,
      'account': 'cash',
      'supplierPayment': true,
      'form': 'udharWapsi',
      'note': 'ملک عباس 15 لاکھ لے کر گیا۔',
    },
    {
      'type': 'adjustment',
      'target': 'money:cash',
      'amount': -5000,
      'note': 'Cash count',
    },
  ]) {
    await app.post({'date': date, ...entry});
  }
  // Settings then also offers the backup made before a restore.
  await app.db.setMeta('pre_restore', jsonEncode(await app.backup()));
  await app.reload();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'No page or dialog overflows at any size or language',
    (tester) async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('ur');
      for (final (family, asset) in [
        ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
        ('Manrope', 'assets/fonts/Manrope.ttf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
      }
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Two organizations, so the switcher and "Remove from this device" are
      // drawn too. Their databases are files in a temporary folder.
      final folder = Directory.systemTemp.createTempSync('khata-layout-');
      final orgs = await Organizations.open(
        directory: folder,
        opener: (file) async {
          final db = KhataDatabase(NativeDatabase(file));
          await db.initialize();
          return db;
        },
      );
      await orgs.create('Muhammad Abdul Rehman Traders and Sons Gas Agency');
      final app = orgs.app;
      await seed(app);

      // problem (message + source line) -> screens where it happened
      final problems = <String, Set<String>>{};
      var where = '';
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        final text = details.toString();
        final first = details.exceptionAsString().split('\n').first.trim();
        final source = RegExp(r'file:///\S*?/lib/\S+?\.dart:\d+')
            .allMatches(text)
            .map((m) => m.group(0)!.split('/lib/').last)
            .toSet();
        final key =
            '$first\n      at ${source.isEmpty ? '?' : source.join(', ')}';
        problems.putIfAbsent(key, () => {}).add(where);
      };

      try {
        tester.view.physicalSize = viewports.values.first;
        await tester.pumpWidget(KhataRoot(orgs));
        await tester.pumpAndSettle();

        BuildContext ctx() => tester.element(find.byType(Workspace));
        Future<void> check(String screen) async {
          where = screen;
          await tester.pumpAndSettle();
        }

        Future<void> dialog(
          String screen,
          void Function(BuildContext) open,
        ) async {
          where = screen;
          open(ctx());
          await tester.pumpAndSettle();
          // Close everything above the page again.
          Navigator.of(ctx(), rootNavigator: true).popUntil((r) => r.isFirst);
          await tester.pumpAndSettle();
        }

        final sale = app.book.documents.firstWhere(
          (d) => d.type == EntryType.sale,
        );
        final entries = <Document>[];
        for (final type in EntryType.values) {
          final ofType = app.book.documents
              .where((d) => d.type == type)
              .toList();
          if (ofType.isEmpty) continue;
          entries.add(ofType.first);
          if (ofType.length > 1) entries.add(ofType.last);
        }
        final abdul = app.partyByName('abdul rehman')!;
        final longName = app.partyByName(
          'Muhammad Abdul Rehman Traders and Sons Gas Agency',
        )!;
        final usman = app.partyByName('استاد عثمان صاحب لاہور والے')!;

        for (final language in ['en', 'ur']) {
          await app.setLanguage(language);
          for (final MapEntry(key: size, value: physical)
              in viewports.entries) {
            tester.view.physicalSize = physical;
            await tester.pumpAndSettle();
            final tag = '$language · $size';
            for (final d in destinations) {
              if (d.$1 == 'roznamcha') {
                app.rozDrafts['page:aamad'] = {
                  'party': longName.name,
                  'bank': '12345678',
                  'account': app
                      .ofKind('account')
                      .firstWhere((a) => a.id != 'cash')
                      .id,
                  'extraBanks': [
                    {
                      'amount': '54321',
                      'account': app
                          .ofKind('account')
                          .firstWhere((a) => a.id != 'cash')
                          .id,
                      'direct': false,
                      'company': '',
                      'bankName': '',
                    },
                    {
                      'amount': '12345678',
                      'account': '',
                      'direct': true,
                      'company': usman.name,
                      'bankName': 'United Bank Limited Main Branch Lahore Company Account',
                    },
                  ],
                };
              }
              app.go(d.$1);
              await check('$tag · ${d.$2} page');
            }
            app.go('parties');
            await tester.pumpAndSettle();
            await dialog(
              '$tag · Customer details (abdul rehman)',
              (c) => unawaited(showParty(c, app, abdul)),
            );
            await dialog(
              '$tag · Customer details (long name)',
              (c) => unawaited(showParty(c, app, longName)),
            );
            await dialog(
              '$tag · Udhari khata (Udhar wapsi button)',
              (c) => unawaited(showParty(c, app, usman)),
            );
            await dialog(
              '$tag · Udhar wapsi from the khata',
              (c) => unawaited(
                openRoznamchaForm(c, app, tab: RozTab.kharcha, party: usman.id),
              ),
            );
            await dialog(
              '$tag · Khata form on a tab without a party (warning)',
              (c) => unawaited(
                openRoznamchaForm(c, app, tab: RozTab.nikali, party: usman.id),
              ),
            );
            await dialog(
              '$tag · Transaction details (sale)',
              (c) => unawaited(showTransaction(c, app, sale)),
            );
            // The first and the last entry of every type (a long sale, a
            // bank-only sale, opening balances, credit note, cylinders…).
            for (final d in entries) {
              await dialog(
                '$tag · Transaction details (${d.type.name} ${d.reference})',
                (c) => unawaited(showTransaction(c, app, d)),
              );
            }
            await dialog(
              '$tag · Edit party',
              (c) => unawaited(editMaster(c, app, 'party', existing: abdul)),
            );
            await dialog(
              '$tag · New party',
              (c) => unawaited(editMaster(c, app, 'party')),
            );
            await dialog(
              '$tag · New bank account',
              (c) => unawaited(editMaster(c, app, 'account')),
            );
            await dialog(
              '$tag · Opening balance',
              (c) => unawaited(editOpeningBalance(c, app)),
            );
            await dialog(
              '$tag · Business profile',
              (c) => unawaited(editProfile(c, app)),
            );
            await dialog(
              '$tag · Day history',
              (c) => unawaited(showHistory(c, app)),
            );
            // The PDF preview's title bar and size slider (the PDF itself is
            // built in the background, which a widget test cannot wait for).
            for (final (label, size) in [
              (null, 150.0),
              ('Compact', 100.0),
              ('Details', 50.0),
            ]) {
              await dialog(
                '$tag · PDF preview (${label ?? 'no switch'}, $size%)',
                (c) => unawaited(
                  showDialog<void>(
                    context: c,
                    builder: (ctx) => Dialog.fullscreen(
                      child: Scaffold(
                        appBar: pdfPreviewBar(
                          ctx,
                          title:
                              '${ctx.t('Cash and bank statement')} — ${longName.name}',
                          switchLabel: label,
                          compact: true,
                          onCompact: (_) {},
                          size: size,
                          onSliding: (_) {},
                          onSize: (_) {},
                          onClose: () {},
                        ),
                        body: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            }
            app.owner = 'layout-check'; // adds the "cloud copy" warning line
            await dialog(
              '$tag · Reset all data',
              (c) => unawaited(confirmReset(c, app)),
            );
            // Cloud-linked with unsent changes: every warning line shows.
            await dialog(
              '$tag · Remove organization (cloud)',
              (c) => unawaited(confirmRemoveOrganization(c, app)),
            );
            app.owner = null;
            await dialog(
              '$tag · Remove organization (local)',
              (c) => unawaited(confirmRemoveOrganization(c, app)),
            );
            await dialog(
              '$tag · Organizations',
              (c) => unawaited(showOrganizations(c, app)),
            );
            await dialog(
              '$tag · New organization',
              (c) => unawaited(
                askText(
                  c,
                  'New organization',
                  label: 'Organization name',
                  keyboard: TextInputType.name,
                ),
              ),
            );
            await dialog(
              '$tag · Backup of another organization',
              (c) => unawaited(
                confirmOtherBackup(
                  c,
                  from: 'استاد عثمان صاحب لاہور والے گیس ایجنسی',
                  into: app.businessName,
                ),
              ),
            );
            for (final t in RozTab.values) {
              await dialog(
                '$tag · Naya entry: ${t.name}',
                (c) => unawaited(openRoznamchaForm(c, app, tab: t)),
              );
            }
            for (final type in [
              EntryType.sale,
              EntryType.purchase,
              EntryType.expense,
              EntryType.transfer,
              EntryType.adjustment,
              EntryType.stockAdjustment,
              EntryType.cylinder,
              EntryType.deposit,
            ]) {
              await dialog(
                '$tag · Composer: ${type.name}',
                (c) => unawaited(composeEntry(c, app, type: type)),
              );
            }
            await dialog(
              '$tag · Correct sale',
              (c) => unawaited(composeEntry(c, app, replace: sale)),
            );
            // A share from a chosen purchase: switch, "Share from" picker
            // with the purchase's long label, in both entry forms.
            final share = app.book.documents.firstWhere(
              (d) => d.sharePurchase.isNotEmpty,
            );
            await dialog(
              '$tag · Correct purchase share (composer)',
              (c) => unawaited(composeEntry(c, app, replace: share)),
            );
            await dialog(
              '$tag · Correct purchase share (daily form)',
              (c) => unawaited(openRoznamchaForm(c, app, replace: share)),
            );
            app.go('roznamcha');
            await check('$tag · Roznamcha page (after correcting a sale)');
          }
        }
      } finally {
        FlutterError.onError = original;
      }

      final report = StringBuffer();
      for (final MapEntry(key: problem, value: screens) in problems.entries) {
        report.writeln('\n• $problem');
        for (final s in screens.take(12)) {
          report.writeln('      - $s');
        }
        if (screens.length > 12) {
          report.writeln('      … and ${screens.length - 12} more');
        }
      }
      // ignore: avoid_print
      print(
        problems.isEmpty
            ? 'No layout problems found.'
            : '${problems.length} layout problem(s):$report',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await orgs.close();
      try {
        folder.deleteSync(recursive: true);
      } catch (_) {}
      expect(problems, isEmpty, reason: report.toString());
      // Windows uses compact visual density (shorter list tiles, buttons and
      // fields) — the original 3px overflow only showed there — so check it as
      // well as Android.
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
