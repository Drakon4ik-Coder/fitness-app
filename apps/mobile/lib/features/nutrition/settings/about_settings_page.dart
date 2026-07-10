import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../../../ui_components/ui_components.dart';
import '../../../ui_system/tokens.dart';
import 'settings_rows.dart';

/// The policy is a public document served by the prod backend; staging and
/// local builds still link to the canonical copy.
const kPrivacyPolicyUrl = 'https://symbio.drakon4ik.uk/privacy';

const kOpenFoodFactsUrl = 'https://world.openfoodfacts.org';
const kOdblLicenseUrl = 'https://opendatacommons.org/licenses/odbl/1-0/';

/// Symbio's own license entry for the Flutter license page. The registry only
/// aggregates pub dependencies' licenses; the app's Apache-2.0/NOTICE must be
/// added explicitly (ODbL/Play launch requirement, KAN-43).
const _symbioNotice = '''
Symbio
Copyright 2026 Fitness App contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.''';

bool _symbioLicenseRegistered = false;

void _registerSymbioLicense() {
  if (_symbioLicenseRegistered) return;
  _symbioLicenseRegistered = true;
  LicenseRegistry.addLicense(
    () => Stream.value(
      const LicenseEntryWithLineBreaks(['symbio'], _symbioNotice),
    ),
  );
}

Future<String> _platformVersion() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
}

Future<bool> _openExternal(Uri url) => url_launcher.launchUrl(
  url,
  mode: url_launcher.LaunchMode.externalApplication,
);

/// Nested settings page with the app version, legal links and data-source
/// attribution. "Powered by Open Food Facts" + the ODbL link live here
/// because ODbL requires attribution in the product using the data, not just
/// the repository README.
class AboutSettingsPage extends StatefulWidget {
  const AboutSettingsPage({
    super.key,
    Future<String> Function()? loadVersion,
    Future<bool> Function(Uri url)? openUrl,
  }) : loadVersion = loadVersion ?? _platformVersion,
       openUrl = openUrl ?? _openExternal;

  /// Resolves the installed version string; tests pass a fake to avoid the
  /// platform channel.
  final Future<String> Function() loadVersion;

  /// Opens a URL in the external browser; tests pass a fake to capture it.
  final Future<bool> Function(Uri url) openUrl;

  @override
  State<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends State<AboutSettingsPage> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final version = await widget.loadVersion();
      if (mounted) setState(() => _version = version);
    } catch (_) {
      // Cosmetic only — the row keeps its placeholder.
    }
  }

  Future<void> _open(String url) async {
    var opened = false;
    try {
      opened = await widget.openUrl(Uri.parse(url));
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  void _showLicenses() {
    _registerSymbioLicense();
    showLicensePage(
      context: context,
      applicationName: 'Symbio',
      applicationVersion: _version.isEmpty ? null : _version,
      applicationLegalese: '© 2026 Symbio · Apache License 2.0',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppScaffold(
      safeArea: true,
      padding: EdgeInsets.zero,
      appBar: AppBar(title: const Text('About'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          AppSection(
            title: 'App',
            child: SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.info_outline,
                  title: 'Version',
                  subtitle: _version.isEmpty ? '…' : _version,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSection(
            title: 'Legal',
            child: SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Privacy policy',
                  subtitle: 'How your data is handled',
                  trailing: Icons.open_in_new,
                  onTap: () => _open(kPrivacyPolicyUrl),
                ),
                SettingsTile(
                  icon: Icons.description_outlined,
                  title: 'Open-source licenses',
                  subtitle: 'Symbio (Apache-2.0) and bundled packages',
                  onTap: _showLicenses,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppSection(
            title: 'Data sources',
            child: SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.restaurant_menu,
                  title: 'Powered by Open Food Facts',
                  subtitle: 'world.openfoodfacts.org',
                  trailing: Icons.open_in_new,
                  onTap: () => _open(kOpenFoodFactsUrl),
                ),
                SettingsTile(
                  icon: Icons.balance,
                  title: 'Open Database License (ODbL)',
                  subtitle: 'Food data licensing terms',
                  trailing: Icons.open_in_new,
                  onTap: () => _open(kOdblLicenseUrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Text(
              'Food and nutrition data comes from the Open Food Facts '
              'database, © Open Food Facts contributors, available under '
              'the Open Database License (ODbL).',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
