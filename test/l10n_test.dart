import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zubair_khata_management/core/l10n.dart';

void main() {
  test('Explicit UI labels have Urdu translations', () {
    final missing = <String>{};
    final pattern = RegExp(r"\.t\('([^'\$\r\n]+)'\)");
    // Headings passed as plain strings: Tag, SectionHeader and the cards of
    // the details dialog translate them when they are drawn.
    final headings = RegExp(
      r"(?:\bTag|\bSectionHeader|\b_card)\(\s*'([^'\$\r\n]+)'",
    );
    for (final file
        in Directory('lib/ui')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final match in [
        ...pattern.allMatches(source),
        ...headings.allMatches(source),
      ]) {
        final key = match.group(1)!;
        if (!Words.hasUrdu(key)) missing.add(key);
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'All application-owned labels must be translated',
    );
  });

  test('The entry description helpers only use translated labels', () {
    // Labels in lib/features are not under lib/ui, so they are checked here.
    // test/entry_facts_test.dart also runs every entry type in Urdu.
    final missing = <String>{};
    final pattern = RegExp(r"\bt\('([^'\$\r\n]+)'\)");
    final source = File(
      'lib/features/ledger/entry_facts.dart',
    ).readAsStringSync();
    for (final match in pattern.allMatches(source)) {
      final key = match.group(1)!;
      if (!Words.hasUrdu(key)) missing.add(key);
    }
    expect(missing, isEmpty);
  });

  test('The detailed profit only uses translated labels', () {
    // What we have and Why (position.dart), also printed in the Profit
    // report; a call may break its text onto the next line.
    final missing = <String>{};
    final pattern = RegExp(r"\bt\(\s*'([^'\$\r\n]+)'");
    final source = File('lib/features/ledger/position.dart').readAsStringSync();
    var found = 0;
    for (final match in pattern.allMatches(source)) {
      found++;
      final key = match.group(1)!;
      if (!Words.hasUrdu(key)) missing.add(key);
    }
    expect(found, greaterThan(40));
    expect(missing, isEmpty);
  });
}
