import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/environment.dart';

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
        _item = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
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
      if (statusCode == 404 && data is Map && data['fetch_external'] == true) {
        message = 'Fetch from OFF (coming next)';
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
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _message = message;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = 'Lookup failed. Please try again.';
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

    return Scaffold(
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
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'API: ${EnvironmentConfig.apiBaseUrl}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _lookup(),
              decoration: const InputDecoration(
                labelText: 'Barcode',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isLoading ? null : _lookup,
              child: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Lookup'),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (_item != null) ...[
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    Text(
                      name?.isNotEmpty == true ? name! : 'Unnamed item',
                      style: theme.textTheme.titleLarge,
                    ),
                    if (brands?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Text('Brands: $brands'),
                    ],
                    if (ingredients?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Text('Ingredients: $ingredients'),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
