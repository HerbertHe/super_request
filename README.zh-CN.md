# super_request

[![pub package](https://img.shields.io/pub/v/super_request.svg)](https://pub.dev/packages/super_request)
[![pub points](https://img.shields.io/pub/points/super_request)](https://pub.dev/packages/super_request/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) | [简体中文](README.zh-CN.md)

`super_request` 是一个面向 Dart 和 Flutter 的框架无关请求编排库。它让传输层代码保持简洁，再通过强类型 wrapper 组合取消、最新请求优先、重试、超时、轮询、防抖、节流、缓存、队列和响应式请求状态等能力。

包内置 Dio 适配器，但核心抽象同样适用于任何异步函数。

## 功能

- 惰性、强类型的 `RequestCall<T>` 和参数化 `RequestService<T, P>`。
- 基于闭包的 wrapper，组合顺序可预测。
- 通过 `CancelToken` 统一取消 Dio 请求。
- 用于页面、组件或业务用例生命周期管理的请求 scope。
- 基于 Zone 的 `TabScoped` 请求归属、按 Tab 取消和显式 unscoped 逃生口。
- 用于页面可见性生命周期的框架无关 `TabScopedLifecycle` mixin。
- 用于搜索、筛选和刷新场景的按 key 最新请求优先机制。
- 支持取消感知等待的重试和超时策略。
- 支持退避、最大次数、超时和事件流的顺序轮询。
- 提供 `data`、`error`、`loading` 与轮询状态的 `UseRequest<T, P>` 控制器。
- 防抖、节流、强类型 TTL 缓存、在途去重和 service 重试 wrapper。
- 支持并发上限和单任务取消的 FIFO 请求队列。

## 安装

```yaml
dependencies:
  super_request: ^1.1.0
```

```dart
import 'package:super_request/super_request.dart';
```

`dio` 是包的依赖，`SuperRequestClient` 使用它完成 HTTP 传输。

## 核心概念

有两种互补的请求形式。

| 类型 | 适用场景 | 示例 |
| --- | --- | --- |
| `RequestCall<T>` | 调用时没有变化的输入参数。 | 加载固定用户资料。 |
| `RequestService<T, P>` | 调用参数会影响请求。 | 关键词搜索或按 ID 加载数据。 |

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

这两种形式均为惰性调用：创建它们不会发起请求，只有调用闭包或 `run()` 时才真正执行。

### 源码结构

内部源码遵循单向依赖分层：

```text
lib/src/
├── core/         请求类型、上下文、管线和取消机制
├── lifecycle/    scope、generation、TabScoped 归属和页面生命周期 mixin
├── policies/     重试、超时、轮询、缓存、防抖和节流
├── controllers/  UseRequest 状态和请求队列
└── transport/    Dio 集成
```

应用代码应导入 `package:super_request/super_request.dart`，不要直接依赖内部 `src` 路径。

## Dio 请求

使用已配置的 Dio 实例创建 `SuperRequestClient`。它的 `request<T>` 方法返回惰性 `RequestCall<T>`。

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

没有提供 `decoder` 时，响应数据会被直接转换为 `T`。对于 JSON 对象、列表、基础类型转换和所有业务模型，建议始终提供 decoder。

当不需要保存惰性请求闭包时，可以使用 `execute<T>`：

```dart
final user = await client.execute<User>(
  '/users/42',
  decoder: (data, _) => User.fromJson(data! as Map<String, dynamic>),
);
```

取消请求上下文时，`SuperRequestClient` 会同时取消底层 Dio `CancelToken`。

## 请求管线和 wrapper 顺序

对固定参数请求使用 `RequestPipeline<T>`。第一个注册的 wrapper 位于最外层。

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

上面的声明实际执行顺序为：

```text
scope(generation(timeout(retry(loadUser))))
```

`RequestContext` 会在整个调用链中传递取消状态、重试次数、可选 generation 和应用元数据。

## Scoped request

`RequestScope` 管理一组请求，适合页面、控制器、BLoC 或短生命周期业务操作。

```dart
final scope = RequestScope();

final feedRequest = scope.run(client.request<String>('/feed'));

scope.cancelAll('Refreshing the feed'); // 取消当前工作，但 scope 仍可复用。
try {
  await feedRequest;
} on RequestCancelledException {
  // 预期结果：过期请求不应更新页面。
}
scope.dispose(); // 永久关闭 scope，并取消所有活跃工作。
```

调用 `dispose()` 后，`run()` 会抛出 `StateError`。`cancelAll()` 返回本次新取消的操作数量。

Flutter 中建议每个生命周期边界持有一个 scope：

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

Riverpod 可使用 `ref.onDispose(scope.dispose)`；BLoC/Cubit 可在 `close()` 中调用 `scope.dispose()`。

## Tab Scoped 请求

`TabScoped` 使用 Dart Zone 将异步执行链与逻辑 Tab 关联。`TabScopeManager` 为每个 Tab 持有一个可复用请求 scope，并且只取消已停用 Tab 所属的请求。

在 Tab 宿主中创建一个 manager，并将它绑定为 wrapper：

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

在对应 Tab Zone 中运行页面级请求：

```dart
Future<Dashboard> loadHomeTab() {
  return TabScoped.using('home', loadDashboard.run);
}

void onTabChanged(String nextTab) {
  tabScopes.activate(nextTab); // 取消上一个 Tab 所属的请求。
}

void onTabHidden(String tab) {
  tabScopes.deactivate(tab); // 只取消当前 Tab。
}
```

`activate()` 返回在上一个 Tab 中取消的请求数量。再次进入 Tab 时，会在其可复用 scope 中创建新操作。

参数化 service 使用 `serviceWrapper()`：

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

不需要 wrapper 时，也可使用 manager 的显式 API：

```dart
final profile = await tabScopes.run('profile', loadProfile);
final item = await tabScopes.runService('catalog', loadItemById, 'item-42');
```

两个显式方法都会建立 Tab Zone，因此嵌套异步工作会继承相同归属。

共享应用状态应显式退出 Tab 取消：

```dart
final session = await TabScoped.unscoped(() {
  return refreshGlobalSession();
});
```

启用 `requireScope: true` 后，通过 manager 绑定的请求如果既不在 `TabScoped.using()` 中，也不在 `TabScoped.unscoped()` 中，会抛出 `StateError`。这适合在开发阶段发现未明确生命周期归属的请求。可使用 `onMissingScope` 记录日志或诊断信息。

```dart
final tabScopes = TabScopeManager(
  requireScope: true,
  onMissingScope: (context) {
    logger.warning('Request is missing a tab ownership decision');
  },
);
```

使用 `cancelTab()` 可在不改变 `activeTab` 的情况下取消某个 Tab；Tab 被永久移除时调用 `disposeTab()`；Tab 宿主销毁时调用 `dispose()`。Tab 停用会产生 `RequestCancelledException`，其 kind 为 `RequestCancellationKind.tabDeactivated`。

### 页面生命周期 mixin

页面类通常应使用 `TabScopedLifecycle`，而不是直接调用 manager。mixin 将显示、隐藏和销毁状态映射到对应的 Tab scope 操作，同时保持对 Flutter 的零依赖。

宿主需要提供共享的 `tabScopeManager`、稳定的 `tabScopeKey`，并转发真实的生命周期事件：

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

`handleTabShown()` 和 `handleTabHidden()` 对每次可见性切换都是幂等的。mixin 提供 `tabScopedActive`、`tabShownCount` 和 `isFirstTabShow` 状态，以及以下辅助方法：

- `runTabScoped()` 和 `runTabUnscoped()`：运行任意异步工作。
- `runTabRequest()`：运行强类型 `RequestCall<T>`。
- `runTabService()`：运行强类型 `RequestService<T, P>`。
- `disposeTabScoped()`：永久销毁页面 Tab scope。

每个逻辑 Tab 根节点只应有一个 `TabScopedLifecycle` owner。子组件应复用根 owner 的方法或 Zone，不要使用相同 Tab key 独立执行 dispose。

## 最新请求优先的 generation

`RequestGenerationManager` 可阻止旧响应写入当前状态，适用于搜索框、筛选变更、刷新和 Tab 切换。

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

默认情况下，新 generation 会取消上一代请求，旧请求以 `SupersededRequestException` 完成。设置 `cancelPrevious: false` 可以让旧传输继续，但其结果如果已过期，仍会被拒绝返回。

管线中也可使用：

```dart
final latestSearch = RequestPipeline(loadSearchResults)
    .use(generations.wrapper('user-search'));
```

一个稳定 key 应只服务于一条逻辑数据流。不要让搜索请求和破坏性变更等无关请求共用 key。

## 重试和超时

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

取消和超时异常不会重试。重试间隔支持取消。`RetryPolicy` 同时通过构造器断言和运行时校验非法值。

将 `requestTimeout` 放在 `retry` 外部可限制整段重试链路；将其放在内部可为每次尝试单独设定超时。

```dart
// 所有重试共享一个总超时。
RequestPipeline(loadUser)
    .use(requestTimeout(const Duration(seconds: 10)))
    .use(retry(const RetryPolicy()));

// 每一次尝试都有独立超时。
RequestPipeline(loadUser)
    .use(retry(const RetryPolicy()))
    .use(requestTimeout(const Duration(seconds: 10)));
```

## 轮询

`RequestPoller.poll()` 使用顺序轮询：一次请求结束后才等待间隔，再启动下一次请求，因此不会并发发起轮询请求。

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

当 UI 需要消费每次成功值和可恢复错误时，使用 `watch()`：

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

取消 stream 订阅会取消当前轮询请求。取消传入的 `RequestContext` 也会中断仍在执行的异步 `until` 判定。

`PollOptions` 支持 `interval`、`backoffFactor`、`maxInterval`、`maxAttempts` 和总 `timeout`。达到最大次数时会抛出 `PollAttemptsExceededException`。

## 参数化 service 和 `UseRequest`

对于带输入参数且需要可观测状态的请求，使用 `UseRequest<T, P>`。它类似 ahooks `useRequest` 的编排能力，但不依赖任何 Widget 框架。

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

### 状态

```dart
final state = searchUsers.state;

state.data;           // T?：最新成功结果
state.hasData;        // 区分“没有值”和合法 null
state.error;          // Object?：最新的非取消错误
state.stackTrace;     // state.error 对应的 StackTrace?
state.params;         // P?：最近一次请求参数
state.hasParams;      // 安全支持 nullable P
state.loading;        // 一个或多个请求运行时为 true
state.activeRequests; // 活跃请求数
state.polling;        // 控制器轮询运行时为 true
```

接入其他响应式状态系统时可订阅 `states`：

```dart
final subscription = searchUsers.states.listen((state) {
  render(
    users: state.data,
    loading: state.loading,
    error: state.error,
  );
});

// 在所属生命周期中取消 subscription。
```

多个 `run()` 可以并发执行。每个返回的 future 保留自己的结果或错误，但只有最新 invocation 可以更新 `UseRequestState` 中的 `data` 或 `error`。直到所有活跃请求完成或取消前，`loading` 都会保持 `true`。

### 控制器方法

```dart
await searchUsers.run(params); // 启动强类型请求并返回 Future<T>。
await searchUsers.refresh();   // 使用上次参数再次请求。
searchUsers.mutate(users);     // 本地更新 data。
searchUsers.cancel();          // 取消活跃请求和轮询，之后可复用。
searchUsers.terminate();       // cancel() 的别名。
searchUsers.reset();           // 取消工作并清空参数、data 和 error。
searchUsers.dispose();         // 永久取消工作并关闭 states。
```

`cancel()` 和 `terminate()` 返回本次新取消的活跃操作数量。至少调用一次 `run()` 后才可以调用 `refresh()`，否则会抛出 `StateError`。

### 生命周期回调

```dart
final request = useRequest<User, String>(
  loadUserById,
  onBefore: (id) => analytics.requestStarted(id),
  onSuccess: (user, id) => cacheUser(user),
  onError: (error, stackTrace, id) => reportError(error, stackTrace),
  onFinally: (id) => analytics.requestFinished(id),
);
```

取消时不会调用 `onError`，且只有最新 invocation 的错误才会触发 `onError`。每个成功 invocation 都会调用 `onSuccess`；无论成功、失败或取消，都会调用 `onFinally`。

### 控制器管理的轮询

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

searchUsers.stopPolling(); // 默认会取消正在进行的轮询请求。
```

当希望当前请求自然完成、但不再启动下一轮时，使用 `stopPolling(cancelInFlight: false)`。

## Service wrapper

参数化行为可以作为 wrapper 传入 `useRequest`，也可以通过 `RequestServicePipeline` / `composeService` 组合。

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

这里同样遵循 wrapper 顺序：第一个 wrapper 位于最外层。

### 防抖

`requestDebounce(duration)` 是最新调用优先的防抖。新调用会以 `SupersededRequestException` 取消之前仍在等待或已经运行的 invocation，只有最后的参数会到达被包装 service。

适合文本搜索和频繁变化的筛选条件。

### 节流

`requestThrottle(duration)` 是前沿节流。第一个调用会立即启动；在 duration 内的调用会共享第一个调用的结果，不会使用自己的参数执行 service。

适合重复点击、刷新按钮和高频滚动事件。

### 重试

`serviceRetry(policy)` 将 `RetryPolicy` 适配为参数化 service。每次尝试都会传入同一个 `P`，`RequestContext.attempt` 从 1 开始递增。

### 缓存

`RequestCache<T>` 按值类型约束，因此用于 `List<User>` 的缓存无法意外存储无关类型。

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

缓存条目使用 TTL，已完成条目采用最近最少使用淘汰。默认情况下，相同 key 的请求会加入在途请求，而不是发起重复传输。设置 `deduplicate: false` 可关闭在途去重。

## 请求队列

`RequestQueue` 按 FIFO 顺序运行任务，并限制活跃任务数量。

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

任务状态包括 `queued`、`running`、`completed`、`failed` 和 `cancelled`。

```dart
task.cancel('No longer needed');
queue.cancel('user:42');
queue.cancelAll('Leaving page');
await queue.idle;
queue.dispose();
```

`cancel`、`cancelAll` 和 `terminate` 会分别返回是否成功取消或新取消的任务数量。取消排队任务会在它开始前将其移除；取消运行中任务会立即让调用方收到 `RequestCancelledException`，即使底层 Future 不配合取消也是如此。

如需观察队列数量：

```dart
final subscription = queue.changes.listen((stats) {
  print('queued=${stats.queued}, running=${stats.running}');
});
```

也可把队列作为 service wrapper：

```dart
final request = useRequest<User, String>(
  loadUserById,
  wrappers: [queue.wrapper()],
);
```

## 自定义 wrapper

wrapper 就是普通闭包，无需继承基类。

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

参数化版本同理：

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

可通过 `RequestContext.metadata` 传递 trace ID、租户标识、缓存提示或其他请求范围数据。

## 取消请求

当请求需要 scope、队列或 `UseRequest` 之外的显式所有者时，创建 cancellation controller。

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

取消是幂等的。`raceCancellation` 和所有内置等待都会在取消后立即返回，因此即使底层 Future 很慢或不支持取消，也不会持续阻塞调用方。

## 错误

| 错误 | 含义 |
| --- | --- |
| `RequestCancelledException` | 显式取消或父级取消。 |
| `SupersededRequestException` | 新的防抖或 generation invocation 替代了当前请求。 |
| `RequestTimeoutException` | 请求或轮询超出配置超时。 |
| `PollAttemptsExceededException` | 轮询未能在限定次数内满足完成条件。 |
| `DioException` | 非统一取消导致的 Dio 传输、协议或状态错误。 |

取消和 superseded 属于控制流结果，而不是可重试失败。适当情况下应将它们与需要展示给用户的网络错误分开处理。

可检查 `RequestCancelledException.reason.kind`，区分普通取消、scope 销毁、superseded、超时和 Tab 停用。

## 测试

仓库测试使用 `Completer` 控制慢请求，覆盖取消、过期结果、队列并发上限、FIFO 顺序、缓存去重与淘汰、wrapper 隔离、轮询取消和 nullable 请求状态。

```bash
dart analyze
dart test
dart doc --output /tmp/super_request_doc
dart pub publish --dry-run
```

更多模式请查看可运行的 [example](example/super_request_example.dart) 和 [测试套件](test/super_request_test.dart)。

## License

MIT &copy; Herbert He
