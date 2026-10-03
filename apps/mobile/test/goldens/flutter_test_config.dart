import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Share of pixels allowed to differ before a golden fails (KAN-129).
///
/// Goldens are generated on Linux, CI's platform. Text and edge
/// anti-aliasing still vary slightly between Skia builds and platforms; 0.5%
/// absorbs that noise while a moved, resized or recolored widget changes far
/// more pixels and still fails.
const double kGoldenTolerance = 0.005;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _loadManifestFonts();
  final current = goldenFileComparator;
  if (current is LocalFileComparator) {
    goldenFileComparator = TolerantGoldenFileComparator(
      current.basedir.resolve('golden_test.dart'),
      tolerance: kGoldenTolerance,
    );
  }
  await testMain();
}

/// Tests render every unloaded font family as placeholder boxes. Loading the
/// fonts the app bundles (Material icons via `uses-material-design`) makes
/// icons in the screenshots real glyphs. The theme's text fonts come from the
/// bundled google_fonts assets (KAN-123) and load on their own.
Future<void> _loadManifestFonts() async {
  final manifest =
      json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// [LocalFileComparator] that accepts up to [tolerance] differing pixels.
/// Failures still write the diff images under `failures/` next to the test,
/// which CI uploads as an artifact.
class TolerantGoldenFileComparator extends LocalFileComparator {
  TolerantGoldenFileComparator(super.testFile, {required this.tolerance});

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    try {
      if (result.passed || result.diffPercent <= tolerance) {
        if (!result.passed) {
          debugPrint(
            'Golden $golden within tolerance: '
            '${(result.diffPercent * 100).toStringAsFixed(3)}% differs.',
          );
        }
        return true;
      }
      throw FlutterError(await generateFailureOutput(result, golden, basedir));
    } finally {
      result.dispose();
    }
  }
}
