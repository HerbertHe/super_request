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
