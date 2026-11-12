import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'src/rust/api/app.dart' as rust_app;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  Object? startupError;
  try {
    await RustLib.init();
    final data = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    await rust_app.initApp(dataDir: data.path, cacheDir: cache.path);
  } catch (e) {
    startupError = e;
  }
  runApp(ProviderScope(child: FolioApp(startupError: startupError)));
}
