import 'cancellation.dart';

/// Immutable data propagated through every request and wrapper.
final class RequestContext {
  const RequestContext({
    RequestCancellationToken? cancellationToken,
    this.metadata = const <Object, Object?>{},
    this.attempt = 1,
    this.generation,
  }) : _cancellationToken = cancellationToken;

  final RequestCancellationToken? _cancellationToken;
  RequestCancellationToken get cancellationToken =>
      _cancellationToken ?? RequestCancellationToken.none;
  final Map<Object, Object?> metadata;
  final int attempt;
  final int? generation;

  RequestContext copyWith({
    RequestCancellationToken? cancellationToken,
    Map<Object, Object?>? metadata,
    int? attempt,
    int? generation,
  }) {
    return RequestContext(
      cancellationToken: cancellationToken ?? this.cancellationToken,
      metadata: metadata ?? this.metadata,
      attempt: attempt ?? this.attempt,
      generation: generation ?? this.generation,
    );
  }

  RequestContext withMetadata(Object key, Object? value) {
    return copyWith(metadata: {...metadata, key: value});
  }
}
