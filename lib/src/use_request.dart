import 'dart:async';

import 'cancellation.dart';
import 'context.dart';
import 'polling.dart';
import 'request_service.dart';
import 'scope.dart';

const Object _unsetStateValue = Object();

final class UseRequestState<T, P> {
  const UseRequestState({
    this.data,
    this.hasData = false,
    this.error,
    this.stackTrace,
    this.params,
    this.hasParams = false,
    this.loading = false,
    this.polling = false,
    this.activeRequests = 0,
  });

  final T? data;
  final bool hasData;
  final Object? error;
  final StackTrace? stackTrace;
  final P? params;
  final bool hasParams;
  final bool loading;
  final bool polling;
  final int activeRequests;

  UseRequestState<T, P> copyWith({
    Object? data = _unsetStateValue,
    bool? hasData,
    Object? error = _unsetStateValue,
    Object? stackTrace = _unsetStateValue,
    bool clearError = false,
    Object? params = _unsetStateValue,
    bool? hasParams,
    bool? loading,
    bool? polling,
    int? activeRequests,
  }) {
    return UseRequestState(
      data: identical(data, _unsetStateValue) ? this.data : data as T?,
      hasData: hasData ?? this.hasData,
      error:
          clearError
              ? null
              : identical(error, _unsetStateValue)
              ? this.error
              : error,
      stackTrace:
          clearError
              ? null
              : identical(stackTrace, _unsetStateValue)
              ? this.stackTrace
              : stackTrace as StackTrace?,
      params: identical(params, _unsetStateValue) ? this.params : params as P?,
      hasParams: hasParams ?? this.hasParams,
      loading: loading ?? this.loading,
      polling: polling ?? this.polling,
      activeRequests: activeRequests ?? this.activeRequests,
    );
  }
}

typedef UseRequestBefore<P> = void Function(P params);
typedef UseRequestSuccess<T, P> = void Function(T data, P params);
typedef UseRequestError<P> =
    void Function(Object error, StackTrace stackTrace, P params);
typedef UseRequestFinally<P> = void Function(P params);

/// Dart equivalent of the orchestration part of ahooks `useRequest`.
///
/// It is framework-neutral. Flutter widgets can subscribe to [states], while
/// Riverpod/Bloc/GetX adapters can map [state] into their own reactive model.
final class UseRequest<T, P> {
  UseRequest(
    RequestService<T, P> service, {
    Iterable<RequestServiceWrapper<T, P>> wrappers = const [],
    this.onBefore,
    this.onSuccess,
    this.onError,
    this.onFinally,
  }) : _service = composeService(service, wrappers),
       _state = UseRequestState<T, P>();

  final RequestService<T, P> _service;
  final UseRequestBefore<P>? onBefore;
  final UseRequestSuccess<T, P>? onSuccess;
  final UseRequestError<P>? onError;
  final UseRequestFinally<P>? onFinally;
  final RequestScope _scope = RequestScope();
  final StreamController<UseRequestState<T, P>> _states =
      StreamController<UseRequestState<T, P>>.broadcast(sync: true);
  UseRequestState<T, P> _state;
  RequestCancellationController? _pollCancellation;
  var _latestInvocation = 0;
  var _pollGeneration = 0;
  bool _disposed = false;

  UseRequestState<T, P> get state => _state;
  Stream<UseRequestState<T, P>> get states => _states.stream;
  bool get isDisposed => _disposed;

  Future<T> run(
    P params, {
    RequestContext context = const RequestContext(),
  }) async {
    if (_disposed) throw StateError('UseRequest has been disposed.');
    onBefore?.call(params);
    final invocation = ++_latestInvocation;
    final active = _state.activeRequests + 1;
    _setState(
      _state.copyWith(
        params: params,
        hasParams: true,
        loading: true,
        activeRequests: active,
        clearError: true,
      ),
    );

    try {
      final value = await _scope.run(
        (scopedContext) => _service(params, scopedContext),
        context: context,
      );
      if (invocation == _latestInvocation) {
        _setState(
          _state.copyWith(data: value, hasData: true, clearError: true),
        );
      }
      onSuccess?.call(value, params);
      return value;
    } catch (error, stackTrace) {
      if (invocation == _latestInvocation &&
          error is! RequestCancelledException) {
        _setState(_state.copyWith(error: error, stackTrace: stackTrace));
        onError?.call(error, stackTrace, params);
      }
      rethrow;
    } finally {
      final remaining =
          _state.activeRequests > 0 ? _state.activeRequests - 1 : 0;
      _setState(
        _state.copyWith(activeRequests: remaining, loading: remaining > 0),
      );
      onFinally?.call(params);
    }
  }

  Future<T> refresh({RequestContext context = const RequestContext()}) {
    if (!_state.hasParams) {
      throw StateError('refresh() requires at least one successful run call.');
    }
    return run(_state.params as P, context: context);
  }

  void mutate(T value) {
    if (_disposed) throw StateError('UseRequest has been disposed.');
    _setState(_state.copyWith(data: value, hasData: true, clearError: true));
  }

  /// Cancels active work and restores data, error, and parameters to empty.
  void reset([String? message]) {
    if (_disposed) throw StateError('UseRequest has been disposed.');
    cancel(message ?? 'UseRequest reset');
    _setState(UseRequestState<T, P>());
  }

  /// Cancels every manual and polling request currently owned by this object.
  int cancel([String? message]) {
    _latestInvocation++;
    stopPolling();
    return _scope.cancelAll(message ?? 'UseRequest cancelled');
  }

  int terminate([String? message]) => cancel(message);

  /// Polls sequentially: each interval starts after the previous call ends.
  void startPolling(
    P params, {
    PollOptions options = const PollOptions(),
    bool Function(T value)? stopWhen,
    bool continueOnError = true,
  }) {
    if (_disposed) throw StateError('UseRequest has been disposed.');
    options.validate();
    stopPolling();
    final generation = ++_pollGeneration;
    final cancellation = RequestCancellationController();
    _pollCancellation = cancellation;
    final timeoutTimer =
        options.timeout == null
            ? null
            : Timer(
              options.timeout!,
              () => cancellation.cancel(
                RequestCancellationReason(
                  RequestCancellationKind.timeout,
                  'Polling exceeded ${options.timeout}',
                ),
              ),
            );
    _setState(_state.copyWith(polling: true));
    unawaited(
      () async {
        try {
          for (var attempt = 1; ; attempt++) {
            if (generation != _pollGeneration ||
                cancellation.token.isCancelled) {
              return;
            }
            try {
              final value = await run(
                params,
                context: RequestContext(cancellationToken: cancellation.token),
              );
              if (stopWhen?.call(value) ?? false) return;
            } catch (error) {
              if (error is RequestCancelledException) return;
              if (!continueOnError) return;
            }
            if (options.maxAttempts != null &&
                attempt >= options.maxAttempts!) {
              return;
            }
            try {
              await cancellableDelay(
                options.delayAfter(attempt),
                cancellation.token,
              );
            } on RequestCancelledException {
              return;
            }
          }
        } finally {
          timeoutTimer?.cancel();
        }
      }().whenComplete(() {
        _finishPolling(generation);
      }),
    );
  }

  void _finishPolling(int generation) {
    if (generation != _pollGeneration) return;
    _pollCancellation = null;
    _setState(_state.copyWith(polling: false));
  }

  bool stopPolling({bool cancelInFlight = true}) {
    _pollGeneration++;
    final cancellation = _pollCancellation;
    final wasPolling = cancellation != null || _state.polling;
    _pollCancellation = null;
    if (cancelInFlight) {
      cancellation?.cancel(
        const RequestCancellationReason.cancelled('Polling stopped'),
      );
    }
    _setState(_state.copyWith(polling: false));
    return wasPolling;
  }

  void dispose([String? message]) {
    if (_disposed) return;
    _pollGeneration++;
    _pollCancellation?.cancel(
      RequestCancellationReason.cancelled(message ?? 'UseRequest disposed'),
    );
    _pollCancellation = null;
    _scope.dispose(message);
    _setState(
      _state.copyWith(activeRequests: 0, loading: false, polling: false),
    );
    _disposed = true;
    unawaited(_states.close());
  }

  void _setState(UseRequestState<T, P> next) {
    if (_disposed) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}

UseRequest<T, P> useRequest<T, P>(
  RequestService<T, P> service, {
  Iterable<RequestServiceWrapper<T, P>> wrappers = const [],
  UseRequestBefore<P>? onBefore,
  UseRequestSuccess<T, P>? onSuccess,
  UseRequestError<P>? onError,
  UseRequestFinally<P>? onFinally,
}) => UseRequest(
  service,
  wrappers: wrappers,
  onBefore: onBefore,
  onSuccess: onSuccess,
  onError: onError,
  onFinally: onFinally,
);
