import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/environment.dart';
import 'off_rate_limiter.dart';

class OffImageResult {
  const OffImageResult({required this.bytes, required this.contentType});
  final Uint8List bytes;
  final String contentType;
}

class OffImageDownloader {
  OffImageDownloader({String? userAgent, OffRateLimiter? rateLimiter})
      : _rateLimiter = rateLimiter ?? OffRateLimiter.shared,
        _dio = Dio(
          BaseOptions(
            headers: {
              'User-Agent': userAgent ?? EnvironmentConfig.offUserAgent,
            },
            responseType: ResponseType.bytes,
          ),
        );

  final Dio _dio;
  final OffRateLimiter _rateLimiter;

  Future<OffImageResult?> downloadImage(String url) async {
    try {
      final response = await _rateLimiter.run(
        url,
        () => _dio.get<List<int>>(url),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      final rawCt = response.headers.value('content-type') ?? 'image/jpeg';
      final contentType = rawCt.split(';').first.trim();
      return OffImageResult(
        bytes: Uint8List.fromList(data),
        contentType: contentType,
      );
    } catch (_) {
      return null;
    }
  }
}
