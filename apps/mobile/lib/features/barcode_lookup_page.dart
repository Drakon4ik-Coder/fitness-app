import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/environment.dart';
import 'nutrition/nutrition_today_page.dart';
import '../ui_components/ui_components.dart';
import '../ui_system/tokens.dart';

class BarcodeLookupPage extends StatefulWidget {
  const BarcodeLookupPage({
    super.key,
    required this.accessToken,
    required this.onLogout,
    this.dio,
  });

  final String accessToken;
  final Future<void> Function() onLogout;
  final Dio? dio;

  @override
  State<BarcodeLookupPage> createState() => _BarcodeLookupPageState();
}

class _BarcodeLookupPageState extends State<BarcodeLookupPage> {
  final TextEditingController _controller = TextEditingController();
  late final Dio _dio;
  late final bool _ownsDio;

  bool _isLoading = false;
  String? _message;
  InlineBannerTone? _messageTone;
  Map<String, dynamic>? _item;

  @override
  void initState() {
    super.initState();
    if (widget.dio != null) {
      _dio = widget.dio!;
      _ownsDio = false;
    } else {
      _dio = Dio(
        BaseOptions(
          baseUrl: EnvironmentConfig.apiBaseUrl,
          headers: {'Authorization': 'Bearer ${widget.accessToken}'},
        ),
      );
      _ownsDio = true;
    }
  }

  @override
  void didUpdateWidget(covariant BarcodeLookupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessToken != widget.accessToken) {
      _dio.options.headers['Authorization'] = 'Bearer ${widget.accessToken}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    if (_ownsDio) {
      _dio.close();
    }
    super.dispose();
  }

  Future<void> _lookup() async {
    final barcode = _controller.text.trim();
    if (barcode.isEmpty) {
      setState(() {
        _message = 'Enter a barcode to look up.';
        _messageTone = InlineBannerTone.error;
        _item = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
      _messageTone = null;
      _item = null;
    });

    try {
      final response = await _dio.get('/api/v1/foods/barcode/$barcode');
      final data = response.data as Map;
      if (!mounted) {
        return;
      }
      setState(() {
        _item = Map<String, dynamic>.from(data);
        _isLoading = false;
      });
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final data = error.response?.data;
      String message;
      InlineBannerTone tone;
      if (statusCode == 404 && data is Map && data['fetch_external'] == true) {
        message = 'Fetch from OFF (coming next)';
        tone = InlineBannerTone.info;
      } else if (statusCode == 401) {
        await widget.onLogout();
        if (!mounted) {
          return;
        }
        setState(() {
          _isLoading = false;
        });
        return;
      } else {
        message = 'Lookup failed. Please try again.';
        tone = InlineBannerTone.error;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _message = message;
        _messageTone = tone;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = 'Lookup failed. Please try again.';
        _messageTone = InlineBannerTone.error;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _item?['normalized_name'] as String?;
    final brands = _item?['brands'] as String?;
    final ingredients = _item?['ingredients_text'] as String?;

    return AppScaffold(
      appBar: AppBar(
        title: const Text('Barcode Lookup'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: _isLoading ? null : () => widget.onLogout(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      scrollable: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'API: ${EnvironmentConfig.apiBaseUrl}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _controller,
            label: 'Barcode',
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _lookup(),
          ),
          const SizedBox(height: AppSpacing.md),
          AppPrimaryButton(
            onPressed: _isLoading ? null : _lookup,
            isLoading: _isLoading,
            child: const Text('Lookup'),
          ),
          if (_message != null) ...[
            const SizedBox(height: AppSpacing.md),
            InlineBanner(
              message: _message!,
              tone: _messageTone ?? InlineBannerTone.info,
            ),
          ],
          if (_item != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name?.isNotEmpty == true ? name! : 'Unnamed item',
                      style: theme.textTheme.titleLarge,
                    ),
                    if (brands?.isNotEmpty == true) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text('Brands: $brands'),
                    ],
                    if (ingredients?.isNotEmpty == true) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text('Ingredients: $ingredients'),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const NutritionTodayPage(),
                ),
              );
            },
            icon: const Icon(Icons.restaurant_menu),
            label: const Text('Go to Nutrition Today'),
          ),
        ],
      ),
    );
  }
}
