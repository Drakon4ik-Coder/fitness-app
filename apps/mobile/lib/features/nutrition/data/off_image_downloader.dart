import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/app_log.dart';
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
          headers: {'User-Agent': userAgent ?? EnvironmentConfig.offUserAgent},
          responseType: ResponseType.bytes,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );

  final Dio _dio;
  final OffRateLimiter _rateLimiter;

  Future<OffImageResult?> downloadImage(
    String url, {
    bool useOffRateLimit = true,
  }) async {
    try {
      // The transport is a plain URL fetch and works for any image host. Only
      // OFF downloads spend OFF's partner budget; FatSecret CDN images must
      // not throttle later OFF searches.
      final response = useOffRateLimit
          ? await _rateLimiter.run(url, () => _dio.get<List<int>>(url))
          : await _dio.get<List<int>>(url);
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      final rawCt = response.headers.value('content-type') ?? 'image/jpeg';
      final contentType = rawCt.split(';').first.trim();
      return OffImageResult(
        bytes: Uint8List.fromList(data),
        contentType: contentType,
      );
    } catch (error, stackTrace) {
      // Best-effort by design: a failed download only means the food keeps
      // its remote image URL. Still worth a trace.
      logError('food.downloadImage', error, stackTrace);
      return null;
    }
  }
}
