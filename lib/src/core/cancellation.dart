import 'dart:async';

/// Why a request stopped before producing a usable value.
enum RequestCancellationKind {
  cancelled,
  scopeDisposed,
  superseded,
  timeout,
  tabDeactivated,
}

final class RequestCancellationReason {
  const RequestCancellationReason(this.kind, [this.message]);

  const RequestCancellationReason.cancelled([String? message])
    : this(RequestCancellationKind.cancelled, message);

  final RequestCancellationKind kind;
  final String? message;

  @override
  String toString() => message ?? kind.name;
}

class RequestCancelledException implements Exception {
  const RequestCancelledException(this.reason);

  final RequestCancellationReason reason;

  @override
  String toString() =>
      'RequestCancelledException(${reason.kind.name}: $reason)';
}

final class SupersededRequestException extends RequestCancelledException {
  const SupersededRequestException(super.reason, this.generation);

  final int generation;

  @override
  String toString() => 'SupersededRequestException(generation: $generation)';
}

final class RequestTimeoutException extends RequestCancelledException {
  const RequestTimeoutException(super.reason, this.duration);

  final Duration duration;

  @override
  String toString() => 'RequestTimeoutException(after: $duration)';
}

/// Read-only cancellation signal passed through a request operation.
final class RequestCancellationToken {
  RequestCancellationToken._(this._future, this._reason, this._listen);

  static final RequestCancellationToken none = RequestCancellationToken._(
    Completer<RequestCancellationReason>().future,
    () => null,
    (_) => () {},
  );

  final Future<RequestCancellationReason> _future;
  final RequestCancellationReason? Function() _reason;
  final void Function() Function(void Function(RequestCancellationReason))
  _listen;

  Future<RequestCancellationReason> get whenCancelled => _future;
  bool get isCancelled => _reason() != null;
  RequestCancellationReason? get reason => _reason();

  void throwIfCancelled() {
    final current = reason;
    if (current != null) {
      throw RequestCancelledException(current);
    }
  }

  /// Registers a synchronous cancellation callback and returns an unsubscribe.
  void Function() listen(void Function(RequestCancellationReason) listener) =>
      _listen(listener);
}

/// Owner of a [RequestCancellationToken]. Cancellation is idempotent.
final class RequestCancellationController {
  final Completer<RequestCancellationReason> _completer =
      Completer<RequestCancellationReason>();
  RequestCancellationReason? _reason;
  final Set<void Function(RequestCancellationReason)> _listeners = {};

  late final RequestCancellationToken token = RequestCancellationToken._(
    _completer.future,
    () => _reason,
    (listener) {
      final current = _reason;
      if (current != null) {
        listener(current);
        return () {};
      }
      _listeners.add(listener);
      return () => _listeners.remove(listener);
    },
  );

  bool cancel([
    RequestCancellationReason reason =
        const RequestCancellationReason.cancelled(),
  ]) {
    if (_reason != null) return false;
    _reason = reason;
    _completer.complete(reason);
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener(reason);
    }
    return true;
  }
}

/// A disposable token that is cancelled when any parent token is cancelled.
///
/// Always call [dispose] when the operation finishes. This detaches listeners
/// from long-lived parent scopes and prevents completed requests accumulating.
final class RequestCancellationLink {
  RequestCancellationLink(Iterable<RequestCancellationToken> parents) {
    for (final parent in parents) {
      if (identical(parent, RequestCancellationToken.none)) continue;
      final reason = parent.reason;
      if (reason != null) {
        _controller.cancel(reason);
        break;
      }
      _unsubscribes.add(parent.listen(_controller.cancel));
    }
  }

  final RequestCancellationController _controller =
      RequestCancellationController();
  final List<void Function()> _unsubscribes = [];
  bool _disposed = false;

  RequestCancellationToken get token => _controller.token;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final unsubscribe in _unsubscribes) {
      unsubscribe();
    }
    _unsubscribes.clear();
  }
}

/// Completes with [future], or throws as soon as [token] is cancelled.
Future<T> raceCancellation<T>(
  Future<T> future,
  RequestCancellationToken token,
) {
  token.throwIfCancelled();
  if (identical(token, RequestCancellationToken.none)) return future;

  final result = Completer<T>();
  final detach = token.listen((reason) {
    if (!result.isCompleted) {
      result.completeError(RequestCancelledException(reason));
    }
  });
  if (result.isCompleted) detach();

  future.then(
    (value) {
      detach();
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      detach();
      if (!result.isCompleted) result.completeError(error, stackTrace);
    },
  );
  return result.future;
}

/// A delay that can be interrupted by request cancellation.
Future<void> cancellableDelay(
  Duration duration,
  RequestCancellationToken token,
) {
  if (duration <= Duration.zero) {
    token.throwIfCancelled();
    return Future<void>.value();
  }
  return raceCancellation(Future<void>.delayed(duration), token);
}
