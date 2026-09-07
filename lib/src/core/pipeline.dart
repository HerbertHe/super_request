import 'context.dart';

typedef RequestCall<T> = Future<T> Function(RequestContext context);
typedef RequestWrapper<T> = RequestCall<T> Function(RequestCall<T> next);

/// Composes wrappers in declaration order: the first wrapper is outermost.
RequestCall<T> composeRequest<T>(
  RequestCall<T> request,
  Iterable<RequestWrapper<T>> wrappers,
) {
  return wrappers.toList().reversed.fold(request, (next, wrap) => wrap(next));
}

/// Reusable, immutable request pipeline.
final class RequestPipeline<T> {
  RequestPipeline(
    this.request, [
    Iterable<RequestWrapper<T>> wrappers = const [],
  ]) : wrappers = List.unmodifiable(wrappers);

  final RequestCall<T> request;
  final List<RequestWrapper<T>> wrappers;

  RequestPipeline<T> use(RequestWrapper<T> wrapper) =>
      RequestPipeline(request, [...wrappers, wrapper]);

  RequestCall<T> get call => composeRequest(request, wrappers);

  Future<T> run([RequestContext context = const RequestContext()]) =>
      call(context);
}
