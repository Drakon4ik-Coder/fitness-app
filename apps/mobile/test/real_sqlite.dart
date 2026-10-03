import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs the app's sqflite code against a real SQLite (via FFI) in a fresh
/// temp directory, with path_provider's documents directory pointed at it
/// (KAN-127). Fakes like InMemoryNutritionStore can't catch SQL, schema
/// migration or transaction bugs; these tests can.
///
/// Call from `setUp`; returns the directory the stores will write to.
Directory useRealSqlite() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = Directory.systemTemp.createTempSync('symbio_db_test_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async => dir.path);
  addTearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly hold a closed SQLite file; a leftover temp dir
      // is harmless.
    }
  });
  return dir;
}
