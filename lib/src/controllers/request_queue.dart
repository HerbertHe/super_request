import 'dart:async';
import 'dart:collection';

import '../core/cancellation.dart';
import '../core/context.dart';
import '../core/pipeline.dart';
import '../core/request_service.dart';

enum RequestQueueTaskState { queued, running, completed, failed, cancelled }

final class RequestQueueStats {
  const RequestQueueStats({required this.queued, required this.running});

  final int queued;
  final int running;

  bool get isIdle => queued == 0 && running == 0;
}

/// Handle returned immediately when a request enters a [RequestQueue].
final class RequestQueueTask<T> {
  RequestQueueTask._(this.id, this.future, this._state, this._cancel);

  final Object id;
  final Future<T> future;
  final RequestQueueTaskState Function() _state;
  final bool Function(String? message) _cancel;

  RequestQueueTaskState get state => _state();
  bool get isDone => switch (state) {
    RequestQueueTaskState.completed ||
    RequestQueueTaskState.failed ||
    RequestQueueTaskState.cancelled => true,
    _ => false,
  };

  /// Returns false when this task had already finished or been cancelled.
  bool cancel([String? message]) => _cancel(message);
}

abstract interface class _QueueEntryBase {
  Object get id;
  RequestQueueTaskState get state;
  set state(RequestQueueTaskState value);
  RequestCancellationController get cancellation;
  RequestCancellationLink get link;
  void Function()? get detachCancellation;
  set detachCancellation(void Function()? value);

  Future<void> execute();
  void completeCancellation(RequestCancellationReason reason);
}

final class _QueueEntry<T> implements _QueueEntryBase {
  _QueueEntry({
    required this.id,
    required this.request,
    required this.context,
  }) {
    link = RequestCancellationLink([
      context.cancellationToken,
      cancellation.token,
    ]);
  }

  @override
  final Object id;
  final RequestCall<T> request;
  final RequestContext context;
  final Completer<T> completer = Completer<T>();

  @override
  final RequestCancellationController cancellation =
      RequestCancellationController();
  @override
  late final RequestCancellationLink link;
  @override
  void Function()? detachCancellation;
  @override
  RequestQueueTaskState state = RequestQueueTaskState.queued;

  @override
  Future<void> execute() async {
    try {
      final value = await raceCancellation(
        request(context.copyWith(cancellationToken: link.token)),
        link.token,
      );
      state = RequestQueueTaskState.completed;
      if (!completer.isCompleted) completer.complete(value);
    } catch (error, stackTrace) {
      state =
          error is RequestCancelledException
              ? RequestQueueTaskState.cancelled
              : RequestQueueTaskState.failed;
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  @override
  void completeCancellation(RequestCancellationReason reason) {
    state = RequestQueueTaskState.cancelled;
    if (!completer.isCompleted) {
      completer.completeError(RequestCancelledException(reason));
    }
  }
}

/// FIFO queue with a configurable number of concurrently running requests.
final class RequestQueue {
  RequestQueue({this.maxConcurrent = 1}) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'Must be at least 1.',
      );
    }
  }

  final int maxConcurrent;
  final Queue<_QueueEntryBase> _pending = Queue();
  final Map<Object, _QueueEntryBase> _running = {};
  final StreamController<RequestQueueStats> _changes =
      StreamController<RequestQueueStats>.broadcast(sync: true);
  var _nextId = 0;
  bool _disposed = false;

  int get queuedCount => _pending.length;
  int get runningCount => _running.length;
  bool get isIdle => queuedCount == 0 && runningCount == 0;
  bool get isDisposed => _disposed;
  RequestQueueStats get stats =>
      RequestQueueStats(queued: queuedCount, running: runningCount);
  Stream<RequestQueueStats> get changes => _changes.stream;

  Future<void> get idle async {
    if (isIdle) return;
    await changes.firstWhere((stats) => stats.isIdle);
  }

  RequestQueueTask<T> enqueue<T>(
    RequestCall<T> request, {
    Object? id,
    RequestContext context = const RequestContext(),
  }) {
    if (_disposed) throw StateError('RequestQueue has been disposed.');
    final resolvedId = id ?? ++_nextId;
    if (_contains(resolvedId)) {
      throw ArgumentError.value(
        id,
        'id',
        'A task with this id already exists.',
      );
    }

    final entry = _QueueEntry<T>(
      id: resolvedId,
      request: request,
      context: context,
    );
    entry.detachCancellation = entry.link.token.listen((reason) {
      if (entry.state == RequestQueueTaskState.queued) {
        _pending.remove(entry);
        entry.completeCancellation(reason);
        _release(entry);
        _emit();
      } else if (entry.state == RequestQueueTaskState.running) {
        entry.state = RequestQueueTaskState.cancelled;
      }
    });
    final task = RequestQueueTask<T>._(
      resolvedId,
      entry.completer.future,
      () => entry.state,
      (message) => entry.cancellation.cancel(
        RequestCancellationReason.cancelled(message ?? 'Queue task cancelled'),
      ),
    );
    if (!entry.completer.isCompleted) {
      _pending.add(entry);
      _emit();
      _drain();
    }
    return task;
  }

  RequestServiceWrapper<T, P> wrapper<T, P>() {
    return (next) =>
        (params, context) =>
            enqueue<T>(
              (queuedContext) => next(params, queuedContext),
              context: context,
            ).future;
  }

  bool cancel(Object id, [String? message]) {
    _QueueEntryBase? entry;
    for (final pending in _pending) {
      if (pending.id == id) {
        entry = pending;
        break;
      }
    }
    entry ??= _running[id];
    return entry?.cancellation.cancel(
          RequestCancellationReason.cancelled(
            message ?? 'Queue task $id cancelled',
          ),
        ) ??
        false;
  }

  int cancelAll([String? message]) {
    final entries = [..._pending, ..._running.values];
    var cancelled = 0;
    for (final entry in entries) {
      if (entry.cancellation.cancel(
        RequestCancellationReason.cancelled(
          message ?? 'Request queue cancelled',
        ),
      )) {
        cancelled++;
      }
    }
    return cancelled;
  }

  int terminate([String? message]) => cancelAll(message);

  void dispose([String? message]) {
    if (_disposed) return;
    _disposed = true;
    cancelAll(message ?? 'Request queue disposed');
    _closeChangesWhenIdle();
  }

  bool _contains(Object id) =>
      _running.containsKey(id) || _pending.any((entry) => entry.id == id);

  void _drain() {
    while (!_disposed &&
        _running.length < maxConcurrent &&
        _pending.isNotEmpty) {
      final entry = _pending.removeFirst();
      if (entry.link.token.isCancelled) continue;
      entry.state = RequestQueueTaskState.running;
      _running[entry.id] = entry;
      _emit();
      unawaited(_execute(entry));
    }
  }

  Future<void> _execute(_QueueEntryBase entry) async {
    await entry.execute();
    _running.remove(entry.id);
    _release(entry);
    _emit();
    _drain();
  }

  void _release(_QueueEntryBase entry) {
    entry.detachCancellation?.call();
    entry.detachCancellation = null;
    entry.link.dispose();
  }

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(
        RequestQueueStats(queued: queuedCount, running: runningCount),
      );
    }
    _closeChangesWhenIdle();
  }

  void _closeChangesWhenIdle() {
    if (_disposed && isIdle && !_changes.isClosed) {
      unawaited(_changes.close());
    }
  }
}
