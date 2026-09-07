import 'dart:async';

import '../core/cancellation.dart';
import '../core/pipeline.dart';

RequestWrapper<T> requestTimeout<T>(Duration duration) {
  if (duration <= Duration.zero) {
    throw ArgumentError.value(duration, 'duration', 'Must be positive.');
  }
  return (next) => (context) async {
    final controller = RequestCancellationController();
    final reason = RequestCancellationReason(
      RequestCancellationKind.timeout,
      'Request exceeded $duration',
    );
    final timer = Timer(duration, () => controller.cancel(reason));
    final link = RequestCancellationLink([
      context.cancellationToken,
      controller.token,
    ]);
    try {
      return await raceCancellation(
        next(context.copyWith(cancellationToken: link.token)),
        link.token,
      );
    } on RequestCancelledException catch (error) {
      if (error.reason.kind == RequestCancellationKind.timeout) {
        throw RequestTimeoutException(error.reason, duration);
      }
      rethrow;
    } finally {
      timer.cancel();
      link.dispose();
    }
  };
}
