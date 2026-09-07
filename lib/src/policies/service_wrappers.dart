import 'dart:async';

import '../core/cancellation.dart';
import '../core/request_service.dart';
import 'retry.dart';

RequestServiceWrapper<T, P> serviceRetry<T, P>(RetryPolicy policy) {
  return (next) =>
      (params, context) => retry<T>(policy)(
        (attemptContext) => next(params, attemptContext),
      )(context);
}

/// Latest-call debounce. A newer invocation cancels the previous pending or
/// running invocation and only the latest parameters reach the wrapped service.
RequestServiceWrapper<T, P> requestDebounce<T, P>(Duration duration) {
  if (duration < Duration.zero) {
    throw ArgumentError.value(duration, 'duration', 'Cannot be negative.');
  }
  return (next) {
    RequestCancellationController? current;
    var generation = 0;

    return (params, context) async {
      final ownGeneration = ++generation;
      current?.cancel(
        RequestCancellationReason(
          RequestCancellationKind.superseded,
          'Superseded by debounced invocation $ownGeneration',
        ),
      );
      final controller = RequestCancellationController();
      current = controller;
      final link = RequestCancellationLink([
        context.cancellationToken,
        controller.token,
      ]);
      try {
        await cancellableDelay(duration, link.token);
        return await raceCancellation(
          next(params, context.copyWith(cancellationToken: link.token)),
          link.token,
        );
      } on RequestCancelledException catch (error) {
        if (error.reason.kind == RequestCancellationKind.superseded) {
          throw SupersededRequestException(error.reason, ownGeneration);
        }
        rethrow;
      } finally {
        link.dispose();
        if (identical(current, controller)) current = null;
      }
    };
  };
}

/// Leading-edge throttle. Calls inside [duration] share the same result.
RequestServiceWrapper<T, P> requestThrottle<T, P>(Duration duration) {
  if (duration < Duration.zero) {
    throw ArgumentError.value(duration, 'duration', 'Cannot be negative.');
  }
  return (next) {
    DateTime? lastStartedAt;
    Future<T>? shared;

    return (params, context) {
      final now = DateTime.now();
      final last = lastStartedAt;
      if (last != null && now.difference(last) < duration && shared != null) {
        return raceCancellation(shared!, context.cancellationToken);
      }
      lastStartedAt = now;
      final future = next(params, context);
      shared = future;
      return future;
    };
  };
}

final class RequestCache<T> {
  RequestCache({this.maxEntries = 256}) {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'Must be positive.');
    }
  }

  final int maxEntries;
  final Map<Object, _CacheEntry<T>> _entries = {};

  int get length => _entries.length;

  bool contains(Object key) => _entries.containsKey(key);

  Iterable<Object> get keys => List.unmodifiable(_entries.keys);

  void invalidate(Object key) => _entries.remove(key);

  void clear() => _entries.clear();

  void invalidateWhere(bool Function(Object key) test) {
    _entries.removeWhere((key, _) => test(key));
  }

  void _trim({Object? protectedKey}) {
    while (_entries.length > maxEntries) {
      Object? oldestKey;
      DateTime? oldestAccess;
      for (final item in _entries.entries) {
        if (item.key == protectedKey || item.value.inFlight != null) continue;
        if (oldestAccess == null ||
            item.value.lastAccess.isBefore(oldestAccess)) {
          oldestKey = item.key;
          oldestAccess = item.value.lastAccess;
        }
      }
      if (oldestKey == null) return;
      _entries.remove(oldestKey);
    }
  }
}

final class _CacheEntry<T> {
  _CacheEntry() : lastAccess = DateTime.now();

  T? value;
  bool hasValue = false;
  DateTime? savedAt;
  Future<T>? inFlight;
  DateTime lastAccess;
}

/// TTL cache with in-flight request deduplication.
RequestServiceWrapper<T, P> requestCache<T, P>(
  RequestCache<T> cache, {
  required Object Function(P params) keyOf,
  Duration ttl = const Duration(minutes: 5),
  bool deduplicate = true,
}) {
  if (ttl < Duration.zero) {
    throw ArgumentError.value(ttl, 'ttl', 'Cannot be negative.');
  }

  return (next) => (params, context) {
    final key = keyOf(params);
    final now = DateTime.now();
    final entry = cache._entries.putIfAbsent(key, _CacheEntry<T>.new);
    entry.lastAccess = now;
    final savedAt = entry.savedAt;
    if (entry.hasValue && savedAt != null && now.difference(savedAt) <= ttl) {
      return Future<T>.value(entry.value as T);
    }
    if (deduplicate && entry.inFlight != null) {
      return raceCancellation(entry.inFlight!, context.cancellationToken);
    }

    final future = next(params, context);
    entry.inFlight = future;
    cache._trim(protectedKey: key);
    return future.then(
      (value) {
        entry
          ..value = value
          ..hasValue = true
          ..savedAt = DateTime.now()
          ..lastAccess = DateTime.now()
          ..inFlight = null;
        cache._trim();
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        entry.inFlight = null;
        if (!entry.hasValue) cache._entries.remove(key);
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  };
}
