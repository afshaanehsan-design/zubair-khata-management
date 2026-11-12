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
import 'package:zubair_khata_management/ui/app.dart';
import 'package:zubair_khata_management/ui/roznamcha_form.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Desktop and Urdu mobile layouts render and navigate without overflow',
    (tester) async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('ur');
      final fonts = FontLoader('NotoUrdu')
        ..addFont(rootBundle.load('assets/fonts/NotoNastaliqUrdu.ttf'));
      await fonts.load();
      await (FontLoader(
        'Manrope',
      )..addFont(rootBundle.load('assets/fonts/Manrope.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      final db = KhataDatabase(NativeDatabase.memory());
      await db.initialize();
      final app = AppController(db);
      await app.initialize();
      final boundary = GlobalKey();
      tester.view.physicalSize = const Size(1440, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: KhataApp(app)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Roznamcha'), findsWidgets);
      expect(find.text('A: Aamad / Wasooli'), findsOneWidget);
      expect(find.text('B: Kharcha'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('build/preview-desktop.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await app.setLanguage('ur');
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final mobile =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await mobile.toByteData(format: ui.ImageByteFormat.png);
        await File('build/preview-urdu.png')
            .writeAsBytes(png!.buffer.asUint8List());
        mobile.dispose();
      });
      expect(
        Directionality.of(tester.element(find.text('روزنامچہ').first)),
        TextDirection.rtl,
      );
      await tester.tap(find.widgetWithText(FloatingActionButton, 'نیا اندراج'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The sheet opens the same Roznamcha form as the page.
      expect(find.byType(RoznamchaForm), findsNWidgets(2));
      expect(find.text('وصولی / فروخت'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await db.close();
    },
  );
}
