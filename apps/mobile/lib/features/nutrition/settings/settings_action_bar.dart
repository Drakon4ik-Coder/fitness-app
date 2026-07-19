import '../../../ui_components/pinned_action_bar.dart';

/// Settings-named compatibility wrapper for the shared pinned action pattern.
/// Existing settings pages keep their KAN-94 API while other pages can use
/// [PinnedActionBar] directly.
class SettingsActionBar extends PinnedActionBar {
  const SettingsActionBar({super.key, required super.child});
}
