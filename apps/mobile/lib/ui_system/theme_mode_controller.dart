import 'package:flutter/material.dart';

class ThemeModeController extends ChangeNotifier {
  ThemeModeController({ThemeMode initialMode = ThemeMode.light})
      : _mode = initialMode;

  ThemeMode _mode;

  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  void toggle() {
    _mode = isDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
  }
}

class ThemeModeScope extends InheritedNotifier<ThemeModeController> {
  const ThemeModeScope({
    super.key,
    required ThemeModeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeModeController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ThemeModeScope>();
    if (scope == null || scope.notifier == null) {
      throw FlutterError('ThemeModeScope not found in widget tree.');
    }
    return scope.notifier!;
  }

  static ThemeModeController? maybeOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ThemeModeScope>();
    return scope?.notifier;
  }
}
