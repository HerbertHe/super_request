import 'dart:async';
import 'dart:math' as math;

import '../core/cancellation.dart';
import '../core/context.dart';
import '../core/pipeline.dart';

typedef PollRetryPredicate =
    FutureOr<bool> Function(Object error, StackTrace stackTrace, int attempt);

final class PollOptions {
  const PollOptions({
    this.interval = const Duration(seconds: 2),
    this.backoffFactor = 1,
    this.maxInterval = const Duration(seconds: 30),
    this.maxAttempts,
    this.timeout,
  }) : assert(backoffFactor >= 1),
       assert(maxAttempts == null || maxAttempts > 0);

  final Duration interval;
  final double backoffFactor;
  final Duration maxInterval;
  final int? maxAttempts;
  final Duration? timeout;

  void validate() {
    if (interval.isNegative) {
      throw ArgumentError.value(interval, 'interval', 'Cannot be negative.');
    }
    if (maxInterval.isNegative) {
      throw ArgumentError.value(
        maxInterval,
        'maxInterval',
        'Cannot be negative.',
      );
    }
    if (!backoffFactor.isFinite || backoffFactor < 1) {
      throw ArgumentError.value(
        backoffFactor,
        'backoffFactor',
        'Must be finite and at least 1.',
      );
    }
    if (maxAttempts != null && maxAttempts! < 1) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'Must be positive.',
      );
    }
    if (timeout != null && timeout! <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  Duration delayAfter(int attempt) {
    validate();
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt', 'Must be positive.');
    }
    final raw = interval.inMilliseconds * math.pow(backoffFactor, attempt - 1);
    final milliseconds =
        raw.isFinite
            ? math.min(raw.round(), maxInterval.inMilliseconds)
            : maxInterval.inMilliseconds;
    return Duration(milliseconds: milliseconds);
  }
}

final class PollResult<T> {
  const PollResult({
    required this.value,
    required this.attempts,
    required this.elapsed,
  });

  final T value;
  final int attempts;
  final Duration elapsed;
}

sealed class PollEvent<T> {
  const PollEvent(this.attempt, this.elapsed);

  final int attempt;
  final Duration elapsed;
}

final class PollValue<T> extends PollEvent<T> {
  const PollValue(
    super.attempt,
    super.elapsed,
    this.value, {
    required this.done,
  });

  final T value;
  final bool done;
}

final class PollError<T> extends PollEvent<T> {
  const PollError(super.attempt, super.elapsed, this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class PollAttemptsExceededException implements Exception {
  const PollAttemptsExceededException(this.attempts);

  final int attempts;

  @override
  String toString() => 'PollAttemptsExceededException(attempts: $attempts)';
}

final class RequestPoller {
  const RequestPoller();

  Future<PollResult<T>> poll<T>({
    required RequestCall<T> request,
    required FutureOr<bool> Function(T value) until,
    PollOptions options = const PollOptions(),
    RequestContext context = const RequestContext(),
    PollRetryPredicate? retryOnError,
  }) async {
    options.validate();
    final stopwatch = Stopwatch()..start();
    final timeout = _timeoutController(options.timeout);
    final link = RequestCancellationLink([
      context.cancellationToken,
      if (timeout != null) timeout.controller.token,
    ]);
    try {
      for (var attempt = 1; ; attempt++) {
        link.token.throwIfCancelled();
        try {
          final value = await raceCancellation(
            request(
              context.copyWith(cancellationToken: link.token, attempt: attempt),
            ),
            link.token,
          );
          if (await raceCancellation(
            Future.sync(() => until(value)),
            link.token,
          )) {
            return PollResult(
              value: value,
              attempts: attempt,
              elapsed: stopwatch.elapsed,
            );
          }
        } catch (error, stackTrace) {
          if (error is RequestCancelledException) rethrow;
          if (!(await retryOnError?.call(error, stackTrace, attempt) ??
              false)) {
            rethrow;
          }
        }
        _checkAttempts(attempt, options.maxAttempts);
        await cancellableDelay(options.delayAfter(attempt), link.token);
      }
    } on RequestCancelledException catch (error) {
      if (error.reason.kind == RequestCancellationKind.timeout) {
        throw RequestTimeoutException(error.reason, options.timeout!);
      }
      rethrow;
    } finally {
      timeout?.timer.cancel();
      link.dispose();
      stopwatch.stop();
    }
  }

  Stream<PollEvent<T>> watch<T>({
    required RequestCall<T> request,
    required FutureOr<bool> Function(T value) until,
    PollOptions options = const PollOptions(),
    RequestContext context = const RequestContext(),
    PollRetryPredicate? retryOnError,
  }) {
    options.validate();
    final local = RequestCancellationController();
    late StreamController<PollEvent<T>> output;
    output = StreamController<PollEvent<T>>(
      onListen: () {
        unawaited(() async {
          final stopwatch = Stopwatch()..start();
          final timeout = _timeoutController(options.timeout);
          final link = RequestCancellationLink([
            context.cancellationToken,
            local.token,
            if (timeout != null) timeout.controller.token,
          ]);
          try {
            for (var attempt = 1; ; attempt++) {
              link.token.throwIfCancelled();
              try {
                final value = await raceCancellation(
                  request(
                    context.copyWith(
                      cancellationToken: link.token,
                      attempt: attempt,
                    ),
                  ),
                  link.token,
                );
                final done = await raceCancellation(
                  Future.sync(() => until(value)),
                  link.token,
                );
                if (local.token.isCancelled) return;
                output.add(
                  PollValue(attempt, stopwatch.elapsed, value, done: done),
                );
                if (done) return;
              } catch (error, stackTrace) {
                if (error is RequestCancelledException) rethrow;
                final retry =
                    await retryOnError?.call(error, stackTrace, attempt) ??
                    false;
                if (local.token.isCancelled) return;
                output.add(
                  PollError<T>(attempt, stopwatch.elapsed, error, stackTrace),
                );
                if (!retry) Error.throwWithStackTrace(error, stackTrace);
              }
              _checkAttempts(attempt, options.maxAttempts);
              await cancellableDelay(options.delayAfter(attempt), link.token);
            }
          } on RequestCancelledException catch (error, stackTrace) {
            if (local.token.isCancelled) return;
            if (error.reason.kind == RequestCancellationKind.timeout) {
              output.addError(
                RequestTimeoutException(error.reason, options.timeout!),
                stackTrace,
              );
            } else {
              output.addError(error, stackTrace);
            }
          } catch (error, stackTrace) {
            if (!local.token.isCancelled) output.addError(error, stackTrace);
          } finally {
            timeout?.timer.cancel();
            link.dispose();
            stopwatch.stop();
            await output.close();
          }
        }());
      },
      onCancel: () {
        local.cancel(
          const RequestCancellationReason.cancelled(
            'Polling subscription cancelled',
          ),
        );
      },
    );
    return output.stream;
  }

  static void _checkAttempts(int attempt, int? maxAttempts) {
    if (maxAttempts != null && attempt >= maxAttempts) {
      throw PollAttemptsExceededException(attempt);
    }
  }

  static _PollTimeout? _timeoutController(Duration? duration) {
    if (duration == null) return null;
    final controller = RequestCancellationController();
    final timer = Timer(
      duration,
      () => controller.cancel(
        RequestCancellationReason(
          RequestCancellationKind.timeout,
          'Polling exceeded $duration',
        ),
      ),
    );
    return _PollTimeout(controller, timer);
  }
}

final class _PollTimeout {
  const _PollTimeout(this.controller, this.timer);

  final RequestCancellationController controller;
  final Timer timer;
}
