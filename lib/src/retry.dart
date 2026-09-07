import 'dart:math' as math;

import 'cancellation.dart';
import 'pipeline.dart';

typedef RetryPredicate =
    bool Function(Object error, StackTrace stackTrace, int attempt);

final class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 300),
    this.backoffFactor = 2,
    this.maxDelay = const Duration(seconds: 10),
    this.retryIf,
  }) : assert(maxAttempts >= 1),
       assert(backoffFactor >= 1);

  final int maxAttempts;
  final Duration initialDelay;
  final double backoffFactor;
  final Duration maxDelay;
  final RetryPredicate? retryIf;

  void validate() {
    if (maxAttempts < 1) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'Must be positive.',
      );
    }
    if (initialDelay.isNegative) {
      throw ArgumentError.value(
        initialDelay,
        'initialDelay',
        'Cannot be negative.',
      );
    }
    if (maxDelay.isNegative) {
      throw ArgumentError.value(maxDelay, 'maxDelay', 'Cannot be negative.');
    }
    if (!backoffFactor.isFinite || backoffFactor < 1) {
      throw ArgumentError.value(
        backoffFactor,
        'backoffFactor',
        'Must be finite and at least 1.',
      );
    }
  }

  Duration delayBefore(int nextAttempt) {
    validate();
    if (nextAttempt < 2) {
      throw ArgumentError.value(
        nextAttempt,
        'nextAttempt',
        'Must be at least 2.',
      );
    }
    final raw =
        initialDelay.inMilliseconds * math.pow(backoffFactor, nextAttempt - 2);
    final milliseconds =
        raw.isFinite
            ? math.min(raw.round(), maxDelay.inMilliseconds)
            : maxDelay.inMilliseconds;
    return Duration(milliseconds: milliseconds);
  }
}

RequestWrapper<T> retry<T>(RetryPolicy policy) {
  policy.validate();
  return (next) => (context) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      context.cancellationToken.throwIfCancelled();
      try {
        return await next(context.copyWith(attempt: attempt));
      } catch (error, stackTrace) {
        if (error is RequestCancelledException) rethrow;
        lastError = error;
        lastStack = stackTrace;
        final canRetry =
            attempt < policy.maxAttempts &&
            (policy.retryIf?.call(error, stackTrace, attempt) ?? true);
        if (!canRetry) rethrow;
        await cancellableDelay(
          policy.delayBefore(attempt + 1),
          context.cancellationToken,
        );
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  };
}
