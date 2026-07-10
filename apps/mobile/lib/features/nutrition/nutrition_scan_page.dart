import 'dart:async';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';

class NutritionScanPage extends StatefulWidget {
  const NutritionScanPage({super.key, this.controller, this.openAppSettings});

  /// Tests inject a fake; defaults to a real camera-backed controller.
  final MobileScannerController? controller;

  /// Opens the OS app-settings page. After a permanent camera-permission
  /// denial the OS never re-shows the prompt, so settings is the only way
  /// back. Tests inject a spy; defaults to the app_settings plugin.
  final Future<void> Function()? openAppSettings;

  @override
  State<NutritionScanPage> createState() => _NutritionScanPageState();
}

class _NutritionScanPageState extends State<NutritionScanPage>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller =
      widget.controller ?? MobileScannerController();
  bool _hasReturned = false;

  @override
  void initState() {
    super.initState();
    // mobile_scanner only manages app-lifecycle start/stop for controllers
    // it creates itself; since we supply one, we do it. Restarting on resume
    // is what makes "grant camera access in Settings, come back" recover
    // without a manual retry.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_hasReturned) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.start());
    } else if (state == AppLifecycleState.inactive) {
      unawaited(_controller.stop());
    }
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_hasReturned) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue ?? barcode.displayValue;
      if (value != null && value.trim().isNotEmpty) {
        _hasReturned = true;
        // Tactile confirmation that the scan landed — the pop alone is easy
        // to miss with eyes on the product.
        unawaited(HapticFeedback.selectionClick());
        _controller.stop();
        Navigator.of(context).pop(value.trim());
        return;
      }
    }
  }

  Future<void> _openSettings() =>
      (widget.openAppSettings ?? AppSettings.openAppSettings)();

  // A successful start() clears the controller's error state, so retry is
  // just start(): on Android a non-permanent denial re-prompts here.
  Future<void> _retry() => _controller.start();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppScaffold(
      appBar: AppBar(title: const Text('Scan')),
      scrollable: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Align the barcode within the frame.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: _handleDetection,
                    errorBuilder: (context, error, child) => _ScanErrorPanel(
                      error: error,
                      onRetry: _retry,
                      onOpenSettings: _openSettings,
                    ),
                  ),
                  Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: _TorchButton(controller: _controller),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppPrimaryButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.controller});

  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, _) {
        // Unavailable until the camera starts, and stays that way on
        // torchless hardware (emulators, front cameras) — no dead button.
        if (state.torchState == TorchState.unavailable) {
          return const SizedBox.shrink();
        }
        final bool isOn = state.torchState == TorchState.on;
        return IconButton(
          onPressed: controller.toggleTorch,
          tooltip: isOn ? 'Turn torch off' : 'Turn torch on',
          icon: Icon(isOn ? Icons.flash_on : Icons.flash_off),
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.surface.withValues(alpha: 0.7),
            foregroundColor: colorScheme.onSurface,
          ),
        );
      },
    );
  }
}

class _ScanErrorPanel extends StatelessWidget {
  const _ScanErrorPanel({
    required this.error,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final MobileScannerException error;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool permissionDenied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;

    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            permissionDenied
                ? Icons.no_photography_outlined
                : Icons.error_outline,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            permissionDenied
                ? 'Camera access is turned off. Allow camera access in your '
                      'device settings to scan barcodes.'
                : 'The camera could not start.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (permissionDenied) ...[
            AppPrimaryButton(
              onPressed: onOpenSettings,
              child: const Text('Open settings'),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
