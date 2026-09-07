# super_request

[![pub package](https://img.shields.io/pub/v/super_request.svg)](https://pub.dev/packages/super_request)
[![pub points](https://img.shields.io/pub/points/super_request)](https://pub.dev/packages/super_request/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) | [简体中文](README.zh-CN.md)

`super_request` is a framework-neutral request orchestration package for Dart and Flutter. It keeps transport code small and composes request behavior through typed wrappers: cancellation, latest-wins requests, retry, timeout, polling, debounce, throttle, caching, queues, and reactive request state.

It includes a Dio adapter, but its core abstractions work with any asynchronous function.

## Features

- Lazy, strongly typed `RequestCall<T>` and parameterized `RequestService<T, P>`.
- Closure-based wrappers with predictable composition order.
- Dio requests with unified cancellation through `CancelToken`.
- Request scopes for page, widget, or use-case lifecycle management.
- Zone-based `TabScoped` ownership with per-tab cancellation and an explicit unscoped escape hatch.
- A framework-neutral `TabScopedLifecycle` mixin for page visibility lifecycles.
- Keyed latest-wins generations for searches, filters, and refreshes.
- Retry and timeout policies with cancellation-aware waits.
- Sequential polling with backoff, maximum attempts, timeout, and event streams.
- A `UseRequest<T, P>` controller with `data`, `error`, `loading`, and polling state.
- Debounce, throttle, typed TTL cache, in-flight deduplication, and service retry wrappers.
- FIFO request queues with configurable concurrency and per-task cancellation.

## Installation

```yaml
dependencies:
  super_request: ^1.1.0
```

```dart
import 'package:super_request/super_request.dart';
```

`dio` is included as a dependency and is used by `SuperRequestClient`.

## Core concepts

There are two complementary request forms.

| Type | Use it when | Example |
| --- | --- | --- |
| `RequestCall<T>` | The request has no changing input at invocation time. | Load a fixed profile. |
| `RequestService<T, P>` | Call parameters affect the request. | Search with a keyword or load an item by ID. |

```dart
typedef RequestCall<T> = Future<T> Function(RequestContext context);
typedef RequestWrapper<T> = RequestCall<T> Function(RequestCall<T> next);

typedef RequestService<T, P> = Future<T> Function(
  P params,
  RequestContext context,
);
typedef RequestServiceWrapper<T, P> = RequestService<T, P> Function(
  RequestService<T, P> next,
);
```

Both forms are lazy: creating one never starts work. The request starts only when you invoke it or call `run()`.

### Source layout

The internal source tree follows a one-way dependency structure:

```text
lib/src/
├── core/         request types, contexts, pipelines, and cancellation
├── lifecycle/    scopes, generations, TabScoped ownership, and page lifecycle mixin
├── policies/     retry, timeout, polling, cache, debounce, and throttle
├── controllers/  UseRequest state and request queues
└── transport/    Dio integration
```

Applications should import `package:super_request/super_request.dart` rather than internal `src` paths.

## Dio requests

Create a `SuperRequestClient` around your configured Dio instance. Its `request<T>` method returns a lazy `RequestCall<T>`.

```dart
import 'package:dio/dio.dart';
import 'package:super_request/super_request.dart';

final client = SuperRequestClient(
  dio: Dio(BaseOptions(baseUrl: 'https://api.example.com')),
);

final loadUser = client.request<User>(
  '/users/42',
  decoder: (data, response) {
    return User.fromJson(data! as Map<String, dynamic>);
  },
);

final user = await loadUser(const RequestContext());
```

If no `decoder` is supplied, the response data is cast to `T`. Prefer a decoder for JSON objects, lists, primitive conversions, and application models.

`execute<T>` is a convenience method when you do not need to retain the lazy request call:

```dart
final user = await client.execute<User>(
  '/users/42',
  decoder: (data, _) => User.fromJson(data! as Map<String, dynamic>),
);
```

When the request context is cancelled, `SuperRequestClient` also cancels the underlying Dio `CancelToken`.

## Request pipelines and wrapper order

Use `RequestPipeline<T>` for a fixed-parameter request. The first registered wrapper is the outermost wrapper.

```dart
final request = RequestPipeline(loadUser)
    .use(scope.wrapper())
    .use(generations.wrapper('user-detail'))
    .use(requestTimeout(const Duration(seconds: 8)))
    .use(retry(const RetryPolicy(maxAttempts: 3)));

final user = await request.run(
  const RequestContext(metadata: {'trace-id': 'request-123'}),
);
```

The preceding declaration is evaluated as follows:

```text
scope(generation(timeout(retry(loadUser))))
```

`RequestContext` carries cancellation, retry attempt number, optional generation, and application metadata through the entire chain.

## Scoped requests

`RequestScope` owns a group of requests. It is appropriate for a screen, a controller, a BLoC, or a short-lived business operation.

```dart
final scope = RequestScope();

final feedRequest = scope.run(client.request<String>('/feed'));

scope.cancelAll('Refreshing the feed'); // Cancels current work; scope remains reusable.
try {
  await feedRequest;
} on RequestCancelledException {
  // Expected: the obsolete request must not update the screen.
}
scope.dispose(); // Permanently closes the scope and cancels all active work.
```

After `dispose()`, `run()` throws `StateError`. `cancelAll()` returns the number of operations that were newly cancelled.

In Flutter, own one scope per lifecycle boundary:

```dart
class _ProfilePageState extends State<ProfilePage> {
  final _scope = RequestScope();

  @override
  void dispose() {
    _scope.dispose('Profile page disposed');
    super.dispose();
  }
}
```

For Riverpod, use `ref.onDispose(scope.dispose)`. For BLoC/Cubit, call `scope.dispose()` from `close()`.

## Tab-scoped requests

`TabScoped` associates an asynchronous execution chain with a logical tab by using Dart Zones. `TabScopeManager` owns one reusable request scope per tab and cancels only the requests that belong to a deactivated tab.

Create one manager for the tab host and bind it as a wrapper:

```dart
final tabScopes = TabScopeManager(requireScope: true);

final loadDashboard = RequestPipeline(
  client.request<Dashboard>(
    '/dashboard',
    decoder: (data, _) => Dashboard.fromJson(
      data! as Map<String, dynamic>,
    ),
  ),
).use(tabScopes.wrapper());
```

Run page-level work inside the corresponding tab Zone:

```dart
Future<Dashboard> loadHomeTab() {
  return TabScoped.using('home', loadDashboard.run);
}

void onTabChanged(String nextTab) {
  tabScopes.activate(nextTab); // Cancels requests owned by the previous tab.
}

void onTabHidden(String tab) {
  tabScopes.deactivate(tab); // Cancels only this tab.
}
```

`activate()` returns the number of requests cancelled in the previous tab. Re-entering a tab creates new operations in its reusable scope.

For parameterized services, use `serviceWrapper()`:

```dart
final loadItem = useRequest<Item, String>(
  loadItemById,
  wrappers: [tabScopes.serviceWrapper()],
);

final item = await TabScoped.using(
  'catalog',
  () => loadItem.run('item-42'),
);
```

The manager also provides explicit APIs when a wrapper is unnecessary:

```dart
final profile = await tabScopes.run('profile', loadProfile);
final item = await tabScopes.runService('catalog', loadItemById, 'item-42');
```

Both explicit methods establish the Tab Zone, so nested asynchronous work inherits the same ownership.

Shared application work should explicitly opt out of tab cancellation:

```dart
final session = await TabScoped.unscoped(() {
  return refreshGlobalSession();
});
```

With `requireScope: true`, a bound request made outside both `TabScoped.using()` and `TabScoped.unscoped()` throws `StateError`. This is useful during development because it detects requests whose lifecycle ownership was never decided. Use `onMissingScope` for logging or diagnostics.

```dart
final tabScopes = TabScopeManager(
  requireScope: true,
  onMissingScope: (context) {
    logger.warning('Request is missing a tab ownership decision');
  },
);
```

Use `cancelTab()` to cancel a tab without changing `activeTab`, `disposeTab()` when a tab is permanently removed, and `dispose()` when the tab host is destroyed. Tab deactivation produces `RequestCancelledException` with `RequestCancellationKind.tabDeactivated`.

### Page lifecycle mixin

Page classes should normally use `TabScopedLifecycle` rather than calling the manager directly. The mixin maps visible, hidden, and disposed transitions to the correct tab-scope operations while remaining independent of Flutter.

Its host must provide a shared `tabScopeManager`, a stable `tabScopeKey`, and forward the actual lifecycle events:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:super_request/super_request.dart';

class HomeTabPage extends StatefulWidget {
  const HomeTabPage({
    super.key,
    required this.visible,
    required this.tabScopes,
  });

  final bool visible;
  final TabScopeManager tabScopes;

  @override
  State<HomeTabPage> createState() => _HomeTabPageState();
}

class _HomeTabPageState extends State<HomeTabPage>
    with TabScopedLifecycle {
  Dashboard? data;

  @override
  TabScopeManager get tabScopeManager => widget.tabScopes;

  @override
  Object get tabScopeKey => 'home';

  @override
  void initState() {
    super.initState();
    if (widget.visible) handleTabShown();
  }

  @override
  void didUpdateWidget(HomeTabPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      handleTabShown();
    } else {
      handleTabHidden();
    }
  }

  @override
  void onTabShown() {
    unawaited(_loadDashboard());
  }

  Future<void> _loadDashboard() async {
    final dashboard = await runTabRequest(loadDashboard);
    if (!tabScopedActive || !mounted) return;
    setState(() => data = dashboard);
  }

  @override
  void dispose() {
    disposeTabScoped();
    super.dispose();
  }
}
```

`handleTabShown()` and `handleTabHidden()` are idempotent per visibility transition. The mixin exposes `tabScopedActive`, `tabShownCount`, and `isFirstTabShow`, plus the following helpers:

- `runTabScoped()` and `runTabUnscoped()` for arbitrary asynchronous work.
- `runTabRequest()` for a typed `RequestCall<T>`.
- `runTabService()` for a typed `RequestService<T, P>`.
- `disposeTabScoped()` for permanent page disposal.

Use one `TabScopedLifecycle` owner at the root of each logical tab. Child widgets should reuse that owner's methods or Zone instead of disposing the same tab key independently.

## Latest-wins request generations

`RequestGenerationManager` prevents an old response from updating the current state. It is ideal for search boxes, filter changes, page refreshes, and tab switches.

```dart
final generations = RequestGenerationManager();

Future<List<User>> search(String keyword) {
  return generations.runLatest(
    'user-search',
    client.request<List<User>>(
      '/users/search',
      queryParameters: {'q': keyword},
      decoder: (data, _) => (data! as List)
          .map((json) => User.fromJson(json as Map<String, dynamic>))
          .toList(),
    ),
  );
}
```

A new generation cancels the previous one by default. The older call completes with `SupersededRequestException`. Set `cancelPrevious: false` to let the older transport continue; its result is still rejected if it is stale.

For a pipeline:

```dart
final latestSearch = RequestPipeline(loadSearchResults)
    .use(generations.wrapper('user-search'));
```

Use a stable key for one logical data stream. Do not reuse a key for unrelated requests, such as a search query and a destructive mutation.

## Retry and timeout

```dart
final reliableRequest = RequestPipeline(loadUser)
    .use(requestTimeout(const Duration(seconds: 10)))
    .use(
      retry(
        RetryPolicy(
          maxAttempts: 3,
          initialDelay: const Duration(milliseconds: 250),
          backoffFactor: 2,
          maxDelay: const Duration(seconds: 5),
          retryIf: (error, stackTrace, attempt) => isTransient(error),
        ),
      ),
    );
```

Cancellation and timeout exceptions are never retried. Delays between retries are cancellation-aware. `RetryPolicy` validates invalid values at runtime as well as through its constructor assertions.

Place `requestTimeout` outside `retry` to limit the whole retry sequence, or inside `retry` to apply a timeout per attempt.

```dart
// One timeout for all retries.
RequestPipeline(loadUser)
    .use(requestTimeout(const Duration(seconds: 10)))
    .use(retry(const RetryPolicy()));

// A timeout for every individual attempt.
RequestPipeline(loadUser)
    .use(retry(const RetryPolicy()))
    .use(requestTimeout(const Duration(seconds: 10)));
```

## Polling

`RequestPoller.poll()` runs sequentially: it waits for one request to finish, then waits for the configured interval, then starts the next request. It never overlaps poll requests.

```dart
final result = await const RequestPoller().poll<Job>(
  request: client.request<Job>(
    '/jobs/123',
    decoder: (data, _) => Job.fromJson(data! as Map<String, dynamic>),
  ),
  until: (job) => job.isTerminal,
  options: const PollOptions(
    interval: Duration(seconds: 1),
    backoffFactor: 1.5,
    maxInterval: Duration(seconds: 10),
    maxAttempts: 30,
    timeout: Duration(minutes: 2),
  ),
  retryOnError: (error, stackTrace, attempt) => isTransient(error),
);

print('Finished after ${result.attempts} attempts: ${result.value}');
```

Use `watch()` when the UI needs every successful value and recoverable error.

```dart
await for (final event in const RequestPoller().watch<Job>(
  request: loadJob,
  until: (job) => job.isTerminal,
  options: const PollOptions(interval: Duration(seconds: 1)),
  retryOnError: (error, stackTrace, attempt) => isTransient(error),
)) {
  switch (event) {
    case PollValue(value: final job, done: final done):
      renderJob(job, isFinal: done);
    case PollError(error: final error):
      reportRecoverableError(error);
  }
}
```

Cancelling the stream subscription cancels the active poll request. Cancelling the supplied `RequestContext` also interrupts an in-progress asynchronous `until` predicate.

`PollOptions` supports `interval`, `backoffFactor`, `maxInterval`, `maxAttempts`, and a total `timeout`. Exhausting `maxAttempts` throws `PollAttemptsExceededException`.

## Parameterized services and `UseRequest`

Use `UseRequest<T, P>` for requests with input parameters and observable state. It is analogous to the orchestration part of ahooks `useRequest`, without being tied to a widget framework.

```dart
final searchUsers = useRequest<List<User>, SearchParams>(
  serviceFromCall((params) {
    return client.request<List<User>>(
      '/users/search',
      method: 'POST',
      data: params.toJson(),
      decoder: (data, _) => (data! as List)
          .map((json) => User.fromJson(json as Map<String, dynamic>))
          .toList(),
    );
  }),
);

final users = await searchUsers.run(
  const SearchParams(keyword: 'Ada'),
);
```

### State

```dart
final state = searchUsers.state;

state.data;           // T? - latest successful value
state.hasData;        // Distinguishes no value from a legitimate null value
state.error;          // Object? - latest non-cancellation error
state.stackTrace;     // StackTrace? for state.error
state.params;         // P? - most recently requested parameters
state.hasParams;      // Supports nullable P safely
state.loading;        // True while one or more requests are active
state.activeRequests; // Number of active requests
state.polling;        // True while controller polling is active
```

Subscribe to `states` when integrating with another reactive system:

```dart
final subscription = searchUsers.states.listen((state) {
  render(
    users: state.data,
    loading: state.loading,
    error: state.error,
  );
});

// Dispose the subscription in the owner lifecycle.
```

Multiple `run()` calls may run concurrently. All returned futures retain their own result or error, while only the latest invocation may update `data` or `error` in `UseRequestState`. `loading` stays true until every active request has completed or been cancelled.

### Controller methods

```dart
await searchUsers.run(params); // Starts a typed request and returns Future<T>.
await searchUsers.refresh();   // Runs again with the last parameters.
searchUsers.mutate(users);     // Updates data locally.
searchUsers.cancel();          // Cancels active requests and polling; reusable afterward.
searchUsers.terminate();       // Alias for cancel().
searchUsers.reset();           // Cancels work and clears parameters, data, and errors.
searchUsers.dispose();         // Permanently cancels work and closes states.
```

`cancel()` and `terminate()` return the number of active operations that were newly cancelled. `refresh()` throws `StateError` until `run()` has been called at least once.

### Lifecycle callbacks

```dart
final request = useRequest<User, String>(
  loadUserById,
  onBefore: (id) => analytics.requestStarted(id),
  onSuccess: (user, id) => cacheUser(user),
  onError: (error, stackTrace, id) => reportError(error, stackTrace),
  onFinally: (id) => analytics.requestFinished(id),
);
```

`onError` is not called for cancellation and is only called for the latest invocation. `onSuccess` runs for every successful invocation, while `onFinally` runs after every invocation resolves, fails, or is cancelled.

### Controller-owned polling

```dart
searchUsers.startPolling(
  const SearchParams(keyword: 'Ada'),
  options: const PollOptions(
    interval: Duration(seconds: 5),
    timeout: Duration(minutes: 2),
  ),
  stopWhen: (users) => users.isNotEmpty,
  continueOnError: true,
);

searchUsers.stopPolling(); // Cancels the in-flight polling request by default.
```

The controller also supports `stopPolling(cancelInFlight: false)` when the current request should be allowed to finish but no later poll should start.

## Service wrappers

Apply parameter-aware behavior by passing service wrappers to `useRequest`, or by composing them with `RequestServicePipeline` / `composeService`.

```dart
final service = RequestServicePipeline<User, String>(loadUserById)
    .use(serviceRetry(const RetryPolicy(maxAttempts: 3)))
    .use(requestThrottle(const Duration(seconds: 1)));

final user = await service.run('42');
```

```dart
final cache = RequestCache<List<User>>(maxEntries: 256);
final queue = RequestQueue(maxConcurrent: 3);

final searchUsers = useRequest<List<User>, SearchParams>(
  searchService,
  wrappers: [
    requestDebounce(const Duration(milliseconds: 300)),
    requestThrottle(const Duration(seconds: 1)),
    serviceRetry(const RetryPolicy(maxAttempts: 3)),
    requestCache(
      cache,
      keyOf: (params) => params.cacheKey,
      ttl: const Duration(minutes: 5),
    ),
    queue.wrapper(),
  ],
);
```

Wrapper order matters here too: the first wrapper is outermost.

### Debounce

`requestDebounce(duration)` is latest-call debounce. A new invocation cancels the earlier pending *or already running* invocation with `SupersededRequestException`. Only the latest parameters reach the wrapped service.

Use it for text search and rapidly changing filters.

### Throttle

`requestThrottle(duration)` is leading-edge throttle. The first call starts immediately. Calls made within the duration share that first call's result and do not invoke the service with their own parameters.

Use it for repeated taps, refresh buttons, and high-frequency scroll events.

### Retry

`serviceRetry(policy)` adapts `RetryPolicy` to a parameterized service. The same `P` is passed to every attempt, while `RequestContext.attempt` increments from 1.

### Cache

`RequestCache<T>` is value-typed, so a cache intended for `List<User>` cannot accidentally store an unrelated result type.

```dart
final cache = RequestCache<User>(maxEntries: 100);

final cachedUser = requestCache<User, String>(
  cache,
  keyOf: (id) => 'user:$id',
  ttl: const Duration(minutes: 10),
);

cache.invalidate('user:42');
cache.invalidateWhere((key) => key.toString().startsWith('user:'));
cache.clear();
```

Cache entries use TTL and least-recently-used eviction for completed entries. By default, a request with the same key joins an in-flight request instead of starting a duplicate transport. Set `deduplicate: false` to opt out.

## Request queues

`RequestQueue` runs tasks in FIFO order and limits the number of active tasks.

```dart
final queue = RequestQueue(maxConcurrent: 2);

final task = queue.enqueue<User>(
  client.request<User>(
    '/users/42',
    decoder: (data, _) => User.fromJson(data! as Map<String, dynamic>),
  ),
  id: 'user:42',
);

final user = await task.future;
```

Task state is one of `queued`, `running`, `completed`, `failed`, or `cancelled`.

```dart
task.cancel('No longer needed');
queue.cancel('user:42');
queue.cancelAll('Leaving page');
await queue.idle;
queue.dispose();
```

`cancel`, `cancelAll`, and `terminate` report whether or how many tasks were newly cancelled. Cancelling a queued task removes it before it starts. Cancelling a running task immediately completes the caller's future with `RequestCancelledException`, even if the underlying Future does not cooperate.

Observe queue counts if needed:

```dart
final subscription = queue.changes.listen((stats) {
  print('queued=${stats.queued}, running=${stats.running}');
});
```

Use the queue as a service wrapper to queue parameterized requests as well:

```dart
final request = useRequest<User, String>(
  loadUserById,
  wrappers: [queue.wrapper()],
);
```

## Custom wrappers

Wrappers are ordinary closures. No base class is required.

```dart
RequestWrapper<T> logging<T>(void Function(String message) log) {
  return (next) => (context) async {
    final watch = Stopwatch()..start();
    try {
      return await next(context);
    } finally {
      log('attempt=${context.attempt}, elapsed=${watch.elapsed}');
    }
  };
}

final request = RequestPipeline(loadUser).use(logging(print));
```

A parameterized counterpart looks the same:

```dart
RequestServiceWrapper<T, P> loggingService<T, P>(
  void Function(String message) log,
) {
  return (next) => (params, context) async {
    final watch = Stopwatch()..start();
    try {
      return await next(params, context);
    } finally {
      log('params=$params, attempt=${context.attempt}, elapsed=${watch.elapsed}');
    }
  };
}
```

Use `RequestContext.metadata` for trace IDs, tenant identifiers, cache hints, or any other request-scoped data.

## Cancellation

Create a cancellation controller when work needs an explicit owner outside a scope, queue, or `UseRequest` controller.

```dart
final cancellation = RequestCancellationController();

final future = client.execute<User>(
  '/users/42',
  context: RequestContext(cancellationToken: cancellation.token),
);

cancellation.cancel(
  const RequestCancellationReason.cancelled('User left the screen'),
);
```

Cancellation is idempotent. `raceCancellation` and all built-in waits return promptly after cancellation, so a slow or non-cooperative lower-level Future cannot keep the caller waiting.

## Errors

| Error | Meaning |
| --- | --- |
| `RequestCancelledException` | Explicit cancellation or parent cancellation. |
| `SupersededRequestException` | A newer debounce or generation invocation replaced this one. |
| `RequestTimeoutException` | A request or poll exceeded its configured timeout. |
| `PollAttemptsExceededException` | Polling did not meet its completion condition in time. |
| `DioException` | A Dio transport, protocol, or status error not caused by unified cancellation. |

Cancellation and supersession are control-flow outcomes, not retryable failures. Handle them separately from user-visible network errors when appropriate.

Inspect `RequestCancelledException.reason.kind` to distinguish ordinary cancellation, scope disposal, supersession, timeout, and tab deactivation.

## Testing

The repository test suite includes controlled slow-request tests using `Completer`s. It covers cancellation, stale results, queue limits, FIFO order, cache deduplication and eviction, wrapper isolation, polling cancellation, and nullable request state.

```bash
dart analyze
dart test
dart doc --output /tmp/super_request_doc
dart pub publish --dry-run
```

See the runnable [example](example/super_request_example.dart) and the [test suite](test/super_request_test.dart) for additional patterns.

## License

MIT &copy; Herbert He
