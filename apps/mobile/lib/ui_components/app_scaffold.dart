import 'package:flutter/material.dart';

import '../ui_system/tokens.dart';

class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.padding,
    this.scrollable = false,
    this.scrollPhysics,
    this.safeArea = true,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final EdgeInsetsGeometry? padding;
  final bool scrollable;
  final ScrollPhysics? scrollPhysics;
  final bool safeArea;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final effectivePadding =
        padding ?? const EdgeInsets.all(AppSpacing.lg);
    final Widget content = scrollable
        ? SingleChildScrollView(
            padding: effectivePadding,
            physics: scrollPhysics,
            child: body,
          )
        : Padding(
            padding: effectivePadding,
            child: body,
          );
    final Widget wrapped = safeArea ? SafeArea(child: content) : content;

    return Scaffold(
      appBar: appBar,
      body: wrapped,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    );
  }
}
