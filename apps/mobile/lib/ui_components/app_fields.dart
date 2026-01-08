import 'package:flutter/material.dart';

class AppFormField extends StatelessWidget {
  const AppFormField({
    super.key,
    required this.controller,
    required this.label,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.onFieldSubmitted,
    this.validator,
    this.autofillHints,
    this.enabled,
    this.suffixIcon,
    this.bottomSpacing,
  });

  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final ValueChanged<String>? onFieldSubmitted;
  final FormFieldValidator<String>? validator;
  final Iterable<String>? autofillHints;
  final bool? enabled;
  final Widget? suffixIcon;
  final double? bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final field = TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      autofillHints: autofillHints,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
      ),
    );

    if (bottomSpacing == null) {
      return field;
    }

    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing!),
      child: field,
    );
  }
}

class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.onSubmitted,
    this.enabled,
    this.suffixIcon,
    this.bottomSpacing,
  });

  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;
  final bool? enabled;
  final Widget? suffixIcon;
  final double? bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      onSubmitted: onSubmitted,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
      ),
    );

    if (bottomSpacing == null) {
      return field;
    }

    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing!),
      child: field,
    );
  }
}
