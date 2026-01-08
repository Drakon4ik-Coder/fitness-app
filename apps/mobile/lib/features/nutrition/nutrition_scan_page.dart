import 'package:flutter/material.dart';

import '../../ui_components/ui_components.dart';
import '../../ui_system/tokens.dart';

class NutritionScanPage extends StatelessWidget {
  const NutritionScanPage({super.key});

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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scanner placeholder',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Hook this up to barcode_lookup_page.dart later.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppPrimaryButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back to Today'),
          ),
        ],
      ),
    );
  }
}
