import '../core/cancellation.dart';
import '../core/context.dart';
import '../core/pipeline.dart';

/// Owns a group of requests, typically for a page, component, or use case.
final class RequestScope {
  final RequestCancellationController _lifetime =
      RequestCancellationController();
  final Set<RequestCancellationController> _operations = {};
  bool _disposed = false;

  bool get isDisposed => _disposed;
  int get activeRequestCount => _operations.length;

  Future<T> run<T>(
    RequestCall<T> request, {
    RequestContext context = const RequestContext(),
  }) async {
    if (_disposed) {
      throw StateError('RequestScope has already been disposed.');
    }

    final operation = RequestCancellationController();
    _operations.add(operation);
    final link = RequestCancellationLink([
      context.cancellationToken,
      _lifetime.token,
      operation.token,
    ]);
    try {
      return await raceCancellation(
        request(context.copyWith(cancellationToken: link.token)),
        link.token,
      );
    } finally {
      link.dispose();
      _operations.remove(operation);
    }
  }

  RequestWrapper<T> wrapper<T>() =>
      (next) => (context) => run(next, context: context);

  /// Cancels current operations while keeping this scope reusable.
  int cancelAll([String? message]) {
    return cancelAllWithReason(RequestCancellationReason.cancelled(message));
  }

  /// Cancels current operations with a structured reason.
  int cancelAllWithReason(RequestCancellationReason reason) {
    var cancelled = 0;
    for (final operation in _operations.toList()) {
      if (operation.cancel(reason)) cancelled++;
    }
    return cancelled;
  }

  /// Permanently closes the scope and cancels all active operations.
  void dispose([String? message]) {
    if (_disposed) return;
    _disposed = true;
    _lifetime.cancel(
      RequestCancellationReason(
        RequestCancellationKind.scopeDisposed,
        message ?? 'Request scope disposed',
      ),
    );
  }
}
