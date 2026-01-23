import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';

class NutritionScanPage extends StatefulWidget {
  const NutritionScanPage({super.key});

  @override
  State<NutritionScanPage> createState() => _NutritionScanPageState();
}

class _NutritionScanPageState extends State<NutritionScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _hasReturned = false;

  void _handleDetection(BarcodeCapture capture) {
    if (_hasReturned) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue ?? barcode.displayValue;
      if (value != null && value.trim().isNotEmpty) {
        _hasReturned = true;
        _controller.stop();
        Navigator.of(context).pop(value.trim());
        return;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppScaffold(
      appBar: AppBar(
        title: const Text('Scan'),
      ),
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
              child: MobileScanner(
                controller: _controller,
                onDetect: _handleDetection,
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
