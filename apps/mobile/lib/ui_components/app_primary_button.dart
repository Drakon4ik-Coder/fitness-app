import 'package:flutter/material.dart';

class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.child,
    this.onPressed,
    this.isLoading = false,
    this.loadingIndicator,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool isLoading;
  final Widget? loadingIndicator;

  @override
  Widget build(BuildContext context) {
    final Widget spinner = loadingIndicator ??
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );

    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      child: isLoading ? spinner : child,
    );
  }
}
