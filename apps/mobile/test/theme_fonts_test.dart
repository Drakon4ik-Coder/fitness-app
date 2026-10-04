import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// google_fonts family name (`<Family>_<variant>`, what the theme's styles
/// carry) → the bundled file google_fonts resolves it to. Production runs with
/// runtime fetching off (KAN-123), so a variant missing here would render in
/// the fallback font for every user.
const _bundled = {
  'Inter_regular': 'Inter-Regular.ttf',
  'Inter_500': 'Inter-Medium.ttf',
  'SpaceGrotesk_600': 'SpaceGrotesk-SemiBold.ttf',
  'SpaceGrotesk_700': 'SpaceGrotesk-Bold.ttf',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every theme text style uses a bundled font variant (KAN-123)', () {
    final text = LuminaHealthTheme.dark().textTheme;
    final styles = {
      'displayLarge': text.displayLarge,
      'displayMedium': text.displayMedium,
      'displaySmall': text.displaySmall,
      'headlineLarge': text.headlineLarge,
      'headlineMedium': text.headlineMedium,
      'headlineSmall': text.headlineSmall,
      'titleLarge': text.titleLarge,
      'titleMedium': text.titleMedium,
      'titleSmall': text.titleSmall,
      'bodyLarge': text.bodyLarge,
      'bodyMedium': text.bodyMedium,
      'bodySmall': text.bodySmall,
      'labelLarge': text.labelLarge,
      'labelMedium': text.labelMedium,
      'labelSmall': text.labelSmall,
    };
    for (final MapEntry(key: role, value: style) in styles.entries) {
      expect(
        _bundled.keys,
        contains(style?.fontFamily),
        reason:
            '$role uses ${style?.fontFamily}: bundle its .ttf under '
            'assets/google_fonts/ (named <Family>-<Variant>.ttf) and add it '
            'to _bundled',
      );
    }
  });

  test('every bundled font file is in the asset manifest (KAN-123)', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    for (final file in _bundled.values) {
      expect(assets, contains('assets/google_fonts/$file'));
    }
  });
}
