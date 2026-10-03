import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// One scripted HTTP reply for [scriptedDio].
typedef FakeReply = ({int status, Object? data});

FakeReply ok([Object? data]) => (status: 200, data: data);
FakeReply status(int code, [Object? data]) => (status: code, data: data);

/// A Dio answered in-process by [handler] (KAN-131): no network, real Dio
/// semantics. Non-2xx replies reject as bad responses (so error interceptors
/// such as AuthInterceptor run); throwing a [DioException] from [handler]
/// simulates transport failures. Every request is appended to [log].
Dio scriptedDio(
  FutureOr<FakeReply> Function(RequestOptions request) handler, {
  List<RequestOptions>? log,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, requestHandler) async {
        log?.add(options);
        try {
          final reply = await handler(options);
          final response = Response<Object?>(
            requestOptions: options,
            statusCode: reply.status,
            data: reply.data,
          );
          if (reply.status >= 200 && reply.status < 300) {
            requestHandler.resolve(response);
          } else {
            requestHandler.reject(
              DioException.badResponse(
                statusCode: reply.status,
                requestOptions: options,
                response: response,
              ),
              true,
            );
          }
        } on DioException catch (error) {
          requestHandler.reject(error, true);
        }
      },
    ),
  );
  return dio;
}

/// A transport-level failure (no HTTP response): offline, DNS, timeout.
DioException offline(RequestOptions request) =>
    DioException.connectionError(requestOptions: request, reason: 'offline');

/// A Dio whose every call throws a non-Dio error, to reach the defensive
/// `catch (error)` branches services keep for programming errors.
class BrokenDio extends Fake implements Dio {
  @override
  BaseOptions options = BaseOptions();

  @override
  final Interceptors interceptors = Interceptors();

  Never _boom() => throw StateError('broken client');

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async => _boom();

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async => _boom();

  @override
  Future<Response<T>> patch<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async => _boom();

  @override
  Future<Response<T>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async => _boom();
}
