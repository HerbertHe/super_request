import 'package:dio/dio.dart';

import '../core/cancellation.dart';
import '../core/context.dart';
import '../core/pipeline.dart';

typedef ResponseDecoder<T> =
    T Function(Object? data, Response<Object?> response);

/// Creates lazy [RequestCall] values backed by Dio.
final class SuperRequestClient {
  SuperRequestClient({Dio? dio}) : dio = dio ?? Dio();

  final Dio dio;

  RequestCall<T> request<T>(
    String path, {
    String? method,
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    ResponseDecoder<T>? decoder,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return (context) async {
      context.cancellationToken.throwIfCancelled();
      final cancelToken = CancelToken();
      final detachCancellation = context.cancellationToken.listen((reason) {
        if (!cancelToken.isCancelled) cancelToken.cancel(reason);
      });

      try {
        final response = await dio.request<Object?>(
          path,
          data: data,
          queryParameters: queryParameters,
          options: (options ?? Options()).copyWith(
            method: method ?? options?.method ?? 'GET',
          ),
          cancelToken: cancelToken,
          onSendProgress: onSendProgress,
          onReceiveProgress: onReceiveProgress,
        );
        context.cancellationToken.throwIfCancelled();
        if (decoder != null) return decoder(response.data, response);
        return response.data as T;
      } on DioException {
        if (context.cancellationToken.isCancelled) {
          throw RequestCancelledException(context.cancellationToken.reason!);
        }
        rethrow;
      } finally {
        detachCancellation();
      }
    };
  }

  Future<T> execute<T>(
    String path, {
    String? method,
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    ResponseDecoder<T>? decoder,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    RequestContext context = const RequestContext(),
    Iterable<RequestWrapper<T>> wrappers = const [],
  }) {
    final call = request<T>(
      path,
      method: method,
      data: data,
      queryParameters: queryParameters,
      options: options,
      decoder: decoder,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
    );
    return composeRequest(call, wrappers)(context);
  }
}
