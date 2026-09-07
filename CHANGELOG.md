## 1.1.0

- Add Zone-based `TabScoped` request ownership and per-tab lifecycle cancellation.
- Add a framework-neutral `TabScopedLifecycle` mixin for page visibility events.
- Add `RequestCancellationKind.tabDeactivated` for structured tab cancellation.
- Organize internal sources into core, lifecycle, policies, controllers, and transport layers.
- Document TabScoped usage and Flutter page lifecycle integration in both languages.

## 1.0.0

- Initial release with composable request wrappers.
- Add scoped cancellation and keyed latest-generation requests.
- Add retry, timeout, one-shot polling, and polling streams.
- Add lazy Dio request adapter.
- Add typed parameterized request services and a framework-neutral `UseRequest`.
- Add debounce, throttle, typed cache, and service retry wrappers.
- Add a cancellable FIFO request queue with configurable concurrency.
- Add nullable-safe request state, lifecycle callbacks, stack traces, and reset.
- Add bounded typed caches and isolate state when wrappers are reused.
- Detach cancellation listeners after completion and validate policies at runtime.
