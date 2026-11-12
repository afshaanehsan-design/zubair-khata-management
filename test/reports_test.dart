import 'dart:io';

import 'package:excel/excel.dart' as xls;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/features/reports/reports.dart';

void main() {
  testWidgets('Hybrid Urdu PDF and genuine XLSX preserve the same amounts', (
    tester,
  ) async {
    await (FontLoader(
      'NotoUrdu',
    )..addFont(rootBundle.load('assets/fonts/NotoNastaliqUrdu.ttf'))).load();
    final report = Report(
      title: 'کسٹمر کا کھاتہ',
      business: 'زبیر ٹریڈرز',
      subtitle: '07/11/2026 · INV-104',
      columns: ['تفصیل', 'رقم'],
      rows: [
        for (var i = 0; i < 35; i++)
          [
            const Cell('محمد علی — رقم کی وصولی، ٹ، ڈ، ڑ، ں، ھ، ء، ے'),
            Cell.amount(1234550 + i),
          ],
      ],
      urdu: true,
    );
    await tester.runAsync(() async {
      final exporter = ReportExporter();
      final bytes = await exporter.pdf(report);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      expect(bytes.length, greaterThan(20000));
      await File('build/urdu-statement.pdf').writeAsBytes(bytes);
      final spreadsheet = exporter.excel(report);
      final decoded = xls.Excel.decodeBytes(spreadsheet);
      final sheet = decoded.tables['Report']!;
      expect(sheet.rows[4][0]!.value.toString(), contains('محمد علی'));
      expect((sheet.rows[4][1]!.value as xls.DoubleCellValue).value, 12345.5);
      await File('build/urdu-statement.xlsx').writeAsBytes(spreadsheet);
      expect(exporter.csv(report), contains('12,345.5'));
      expect(exporter.csv(report), contains('محمد علی'));
    });
  });
  test('Spreadsheet formula injection is escaped without changing numeric negatives', () {
    const report = Report(
      title: 't',
      business: 'b',
      subtitle: 's',
      columns: ['Name', 'Amount'],
      rows: [
        [Cell('=1+1'), Cell('-20', -20)],
      ],
    );
    expect(ReportExporter().csv(report), contains("'=1+1"));
    expect(ReportExporter().csv(report), contains('"-20"'));
  });
}
