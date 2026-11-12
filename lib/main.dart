import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/organizations.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en');
  await initializeDateFormatting('ur');
  try {
    // Opens the organization that was used last.
    runApp(KhataRoot(await Organizations.open()));
  } catch (error) {
    runApp(MaterialApp(home: CouldNotOpen('$error')));
  }
}
