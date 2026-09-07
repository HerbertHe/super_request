import 'cancellation.dart';
import 'context.dart';
import 'pipeline.dart';

final class _GenerationSlot {
  _GenerationSlot(this.value, this.controller);

  final int value;
  final RequestCancellationController controller;
}

/// Implements latest-wins requests, independently for each key.
final class RequestGenerationManager {
  final Map<Object, _GenerationSlot> _slots = {};

  int current(Object key) => _slots[key]?.value ?? 0;

  Future<T> runLatest<T>(
    Object key,
    RequestCall<T> request, {
    RequestContext context = const RequestContext(),
    bool cancelPrevious = true,
  }) async {
    final previous = _slots[key];
    final generation = (previous?.value ?? 0) + 1;
    if (cancelPrevious) {
      previous?.controller.cancel(
        RequestCancellationReason(
          RequestCancellationKind.superseded,
          'Superseded by generation $generation for key $key',
        ),
      );
    }

    final controller = RequestCancellationController();
    final slot = _GenerationSlot(generation, controller);
    _slots[key] = slot;
    final link = RequestCancellationLink([
      context.cancellationToken,
      controller.token,
    ]);

    try {
      final value = await raceCancellation(
        request(
          context.copyWith(
            cancellationToken: link.token,
            generation: generation,
          ),
        ),
        link.token,
      );
      if (!identical(_slots[key], slot)) {
        throw SupersededRequestException(
          RequestCancellationReason(
            RequestCancellationKind.superseded,
            'Generation $generation is stale for key $key',
          ),
          generation,
        );
      }
      return value;
    } on RequestCancelledException catch (error) {
      if (error.reason.kind == RequestCancellationKind.superseded) {
        throw SupersededRequestException(error.reason, generation);
      }
      rethrow;
    } finally {
      link.dispose();
    }
  }

  RequestWrapper<T> wrapper<T>(Object key, {bool cancelPrevious = true}) =>
      (next) =>
          (context) => runLatest(
            key,
            next,
            context: context,
            cancelPrevious: cancelPrevious,
          );

  bool cancel(Object key, [String? message]) {
    return _slots
            .remove(key)
            ?.controller
            .cancel(RequestCancellationReason.cancelled(message)) ??
        false;
  }

  int cancelAll([String? message]) {
    var cancelled = 0;
    for (final slot in _slots.values) {
      if (slot.controller.cancel(
        RequestCancellationReason.cancelled(message),
      )) {
        cancelled++;
      }
    }
    _slots.clear();
    return cancelled;
  }
}
