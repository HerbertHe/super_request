import 'context.dart';
import 'pipeline.dart';

/// A request whose input and output types are both known at compile time.
typedef RequestService<T, P> =
    Future<T> Function(P params, RequestContext context);

typedef RequestServiceWrapper<T, P> =
    RequestService<T, P> Function(RequestService<T, P> next);

RequestService<T, P> composeService<T, P>(
  RequestService<T, P> service,
  Iterable<RequestServiceWrapper<T, P>> wrappers,
) {
  return wrappers.toList().reversed.fold(
    service,
    (next, wrapper) => wrapper(next),
  );
}

/// Turns a parameter-dependent request factory into a service.
RequestService<T, P> serviceFromCall<T, P>(
  RequestCall<T> Function(P params) create,
) => (params, context) => create(params)(context);

/// Immutable builder for parameterized request wrappers.
final class RequestServicePipeline<T, P> {
  RequestServicePipeline(
    this.service, [
    Iterable<RequestServiceWrapper<T, P>> wrappers = const [],
  ]) : wrappers = List.unmodifiable(wrappers);

  final RequestService<T, P> service;
  final List<RequestServiceWrapper<T, P>> wrappers;

  RequestServicePipeline<T, P> use(RequestServiceWrapper<T, P> wrapper) =>
      RequestServicePipeline(service, [...wrappers, wrapper]);

  RequestService<T, P> get call => composeService(service, wrappers);

  Future<T> run(P params, [RequestContext context = const RequestContext()]) =>
      call(params, context);
}
