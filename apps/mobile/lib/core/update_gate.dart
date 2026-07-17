import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'app_log.dart';
import 'version_check_service.dart';

/// Play listing for the Update button. The app is not on Play yet — finalize
/// this URL (applicationId `uk.drakon4ik.symbio`) at Play launch.
const kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=uk.drakon4ik.symbio';

Future<String> _platformBuildNumber() async =>
    (await PackageInfo.fromPlatform()).buildNumber;

Future<bool> _openExternal(Uri url) => url_launcher.launchUrl(
  url,
  mode: url_launcher.LaunchMode.externalApplication,
);

/// Startup forced-update gate (KAN-100): renders [child] immediately and, if
/// the backend reports a `min_supported_build` above this install's
/// versionCode, overlays a blocking update dialog.
///
/// Fail-open by design — this is an offline-first app, so an unreachable
/// backend, a garbage payload or an unparsable build number must all start
/// the app normally. Only the definitive verdict "current build < minimum"
/// blocks; a user who is merely offline is never locked out.
class UpdateGate extends StatefulWidget {
  const UpdateGate({
    super.key,
    required this.child,
    this.versionService,
    Future<String> Function()? loadBuildNumber,
    Future<bool> Function(Uri url)? openUrl,
  }) : loadBuildNumber = loadBuildNumber ?? _platformBuildNumber,
       openUrl = openUrl ?? _openExternal;

  final Widget child;

  /// Injected by tests; defaults to the real backend /health/ probe.
  final VersionCheckService? versionService;

  /// Resolves the installed versionCode (as reported by the platform); tests
  /// pass a fake to avoid the platform channel.
  final Future<String> Function() loadBuildNumber;

  /// Opens the Play listing in the external browser/store; tests pass a fake
  /// to capture it.
  final Future<bool> Function(Uri url) openUrl;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  late final VersionCheckService _versionService =
      widget.versionService ?? VersionCheckService();

  @override
  void initState() {
    super.initState();
    unawaited(_checkMinSupportedBuild());
  }

  Future<void> _checkMinSupportedBuild() async {
    int minBuild;
    try {
      minBuild = await _versionService.fetchMinSupportedBuild();
    } catch (error, stackTrace) {
      logError('Update gate: min build unavailable', error, stackTrace);
      return;
    }
    // 0 = gate disabled server-side; skip the platform-channel lookup too.
    if (minBuild <= 0) return;

    int? currentBuild;
    try {
      currentBuild = int.tryParse(await widget.loadBuildNumber());
    } catch (error, stackTrace) {
      logError('Update gate: build number unavailable', error, stackTrace);
      return;
    }
    if (currentBuild == null || currentBuild >= minBuild) return;
    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ForcedUpdateDialog(openUrl: widget.openUrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ForcedUpdateDialog extends StatelessWidget {
  const _ForcedUpdateDialog({required this.openUrl});

  final Future<bool> Function(Uri url) openUrl;

  @override
  Widget build(BuildContext context) {
    // PopScope + the non-dismissible barrier make the dialog inescapable:
    // the gate only ever opens on a definitive too-old verdict, and the app
    // underneath may no longer speak the server's API.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Update required'),
        content: const Text(
          'This version of Symbio is no longer supported. Please update to '
          'the latest version to continue.',
        ),
        actions: [
          FilledButton(
            onPressed: () => openUrl(Uri.parse(kPlayStoreUrl)),
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }
}
