import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zubair_khata_management/core/controller.dart';
import 'package:zubair_khata_management/data/database.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

Future<void> shot(WidgetTester tester, GlobalKey boundary, String file) =>
    tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(file).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Roznamcha page shows A / B tables, Safi Baqaya and edits rows in place',
    (tester) async {
      await initializeDateFormatting('en');
      for (final (family, asset) in [
        ('Manrope', 'assets/fonts/Manrope.ttf'),
        ('NotoUrdu', 'assets/fonts/NotoNastaliqUrdu.ttf'),
        ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
      }
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      final date = app.selectedDate;
      await app.saveMaster('account', {'name': 'Zubair', 'bank': 'HBL'});
      final hbl = app.ofKind('account').firstWhere((a) => a.id != 'cash').id;
      await app.saveMaster('party', {'name': 'Ali Traders'});
      await app.saveMaster('party', {
        'name': 'PSO',
        'customer': false,
        'supplier': true,
      });
      final ali = app.partyByName('Ali Traders')!.id;
      final pso = app.partyByName('PSO')!.id;
      Future<void> post(Map<String, dynamic> data) =>
          app.post({'date': date, ...data});
      await post({
        'type': 'adjustment',
        'target': 'money:cash',
        'amount': 5000000,
        'note': 'Opening',
        'occurredAt': 0,
        'form': 'opening',
      });
      await post({
        'type': 'sale',
        'party': ali,
        'quantities': {'11800': 3, '45000': 1},
        'returned': {'11800': 3, '45000': 1},
        'rate': 464000,
        'cash': 1000000,
        'bank': 500000,
        'bankAccount': hbl,
        'vehicle': '92',
        'form': 'aamad',
      });
      await post({
        'type': 'transfer',
        'account': hbl,
        'toAccount': 'cash',
        'amount': 200000,
        'form': 'nikali',
      });
      await post({
        'type': 'discount',
        'party': ali,
        'amount': 28000,
        'form': 'less',
      });
      await post({
        'type': 'expense',
        'account': 'cash',
        'amount': 50000,
        'category': 'General',
        'note': 'Chai pani',
        'form': 'kharcha',
      });
      await post({
        'type': 'payment',
        'party': pso,
        'supplierPayment': true,
        'account': 'cash',
        'amount': 2000000,
        'branch': 'Lahore',
        'form': 'companyPay',
      });
      final boundary = GlobalKey();
      tester.view.physicalSize = const Size(1440, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: KhataApp(app)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Opening 50,000 + cash 10,000 + nikali 2,000 − 500 − 20,000 = 41,500
      expect(app.book.money('cash'), 4150000);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('roz-safi')),
          matching: find.text('Rs 41,500'),
        ),
        findsOneWidget,
      );
      expect(find.text('Ali Traders'), findsWidgets);
      expect(find.text('Bank se Nikali (cash mein aaya)'), findsOneWidget);
      expect(find.textContaining('Less / Kami — Ali Traders'), findsOneWidget);
      expect(find.text('auto (Aamad se)'), findsOneWidget);
      expect(find.text('Company ko payment'), findsWidgets);
      // The company payment shows its branch, without an empty "Customer: —".
      expect(find.text('Branch: Lahore'), findsOneWidget);
      expect(find.textContaining('Customer: —'), findsNothing);
      expect(find.text('Hisab Mel (Safi Baqaya kaise bana)'), findsOneWidget);
      // No "fix the opening" button: the starting cash is an ordinary row.
      expect(find.text('Theek karo'), findsNothing);
      expect(find.byKey(const ValueKey('roz-opening-cash')), findsNothing);
      expect(find.text('Opening balance — Cash'), findsOneWidget);
      await shot(tester, boundary, 'build/preview-roznamcha.png');

      // Print / PDF uses the same A → B → Safi Baqaya layout.
      final report = buildReport(app, 'Daily roznamcha', date, date);
      num? line(String label) =>
          report.rows.firstWhere((r) => r[2].text == label)[4].numeric;
      expect(line('A: Aamad / Wasooli'), isNull);
      expect(line('Kul Aamad (Wasooli + Opening + Nikali)'), 67000);
      expect(line('Kul Kharcha + Bank Jama'), 25500);
      expect(line('Safi Baqaya = A − B (Cash in Hand)'), 41500);
      expect(report.rows.any((r) => r[2].text.contains('Parchi 92')), isTrue);

      // Edit (pencil) on the sale row loads it into the Naya Entry form.
      final saleRow = find.ancestor(
        of: find.text('92'),
        matching: find.byType(InkWell),
      );
      await tester.tap(
        find.descendant(
          of: saleRow.first,
          matching: find.byIcon(Icons.edit_outlined),
        ),
      );
      await tester.pumpAndSettle();
      final form = tester.state<RoznamchaFormState>(find.byType(RoznamchaForm));
      expect(form.editing?.party, ali);
      expect(form.tab, RozTab.aamad);
      expect(find.text('Update'), findsOneWidget);
      form.cancelEdit();
      await tester.pumpAndSettle();

      // Delete (bin) on the Kharcha row voids it with a reason.
      final teaRow = find.ancestor(
        of: find.text('Chai pani'),
        matching: find.byType(InkWell),
      );
      await tester.tap(
        find.descendant(
          of: teaRow.first,
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Ghalat entry');
      await tester.pump();
      await tester.tap(find.text('Haan, delete'));
      await tester.pumpAndSettle();
      expect(app.book.money('cash'), 4200000);
      expect(find.text('Chai pani'), findsNothing);

      // ✏️ on the starting cash corrects it in its own dialog, with a reason.
      final opening = app.book.documents.firstWhere(
        (d) => d.data['target'] == 'money:cash',
      );
      final openingRow = find
          .ancestor(
            of: find.text('Opening balance — Cash'),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.ensureVisible(openingRow);
      await tester.tap(
        find.descendant(
          of: openingRow,
          matching: find.byIcon(Icons.edit_outlined),
        ),
      );
      await tester.pumpAndSettle();
      Finder input(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(input('opening-amount')).controller!.text,
        '50000',
      );
      await tester.enterText(input('opening-amount'), '60000');
      await tester.enterText(input('opening-reason'), 'Galat ginti');
      await tester.tap(find.byKey(const ValueKey('opening-save')));
      await tester.pumpAndSettle();
      expect(app.book.money('cash'), 5200000);
      expect(app.record(opening.id)!.data['voidReason'], 'Galat ginti');
      expect(find.text('Opening balance — Cash'), findsOneWidget);

      // Phone layout: cards instead of wide tables, no overflow.
      tester.view.physicalSize = const Size(390, 2600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await shot(tester, boundary, 'build/preview-roznamcha-phone.png');
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );
}
