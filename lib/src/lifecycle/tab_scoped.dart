import 'dart:async';

import '../core/cancellation.dart';
import '../core/context.dart';
import '../core/pipeline.dart';
import '../core/request_service.dart';
import 'scope.dart';

/// Zone-based context for associating requests with a logical application tab.
///
/// [using] marks asynchronous work as belonging to a tab. Requests become
/// cancellable by tab only when they are bound through [TabScopeManager].
abstract final class TabScoped {
  static final Object _tabKey = Object();
  static final Object _unscopedKey = Object();

  /// The tab key inherited by the current asynchronous execution zone.
  static Object? get current => Zone.current[_tabKey];

  /// Whether the current execution zone explicitly opts out of tab ownership.
  static bool get isUnscoped => Zone.current[_unscopedKey] == true;

  /// Runs [body] in a zone owned by [tab].
  static Future<T> using<T>(Object tab, Future<T> Function() body) {
    if (current == tab && !isUnscoped) return body();
    return runZoned(
      body,
      zoneValues: <Object, Object?>{_tabKey: tab, _unscopedKey: false},
    );
  }

  /// Synchronous counterpart to [using]. The returned value may itself be a
  /// Future and will retain the zone across asynchronous continuations.
  static R run<R>(Object tab, R Function() body) {
    if (current == tab && !isUnscoped) return body();
    return runZoned(
      body,
      zoneValues: <Object, Object?>{_tabKey: tab, _unscopedKey: false},
    );
  }

  /// Runs work that must survive tab switches, such as shared app state.
  static Future<T> unscoped<T>(Future<T> Function() body) {
    if (isUnscoped) return body();
    return runZoned(body, zoneValues: <Object, Object?>{_unscopedKey: true});
  }

  /// Synchronous counterpart to [unscoped].
  static R runUnscoped<R>(R Function() body) {
    if (isUnscoped) return body();
    return runZoned(body, zoneValues: <Object, Object?>{_unscopedKey: true});
  }
}

typedef MissingTabScopeHandler = void Function(RequestContext context);

/// Owns one reusable [RequestScope] per logical tab.
///
/// Bind this manager as a request or service wrapper. Requests started inside
/// [TabScoped.using] are then registered under that tab. [deactivate] cancels
/// only that tab, while explicitly unscoped requests remain active.
final class TabScopeManager {
  TabScopeManager({this.requireScope = false, this.onMissingScope});

  final bool requireScope;
  final MissingTabScopeHandler? onMissingScope;
  final Map<Object, RequestScope> _scopes = <Object, RequestScope>{};
  Object? _activeTab;
  bool _disposed = false;

  Object? get activeTab => _activeTab;
  bool get isDisposed => _disposed;
  int get tabCount => _scopes.length;

  int activeRequestCount(Object tab) => _scopes[tab]?.activeRequestCount ?? 0;

  /// Makes [tab] active and optionally cancels requests owned by the previous
  /// active tab. Returns the number of requests cancelled by the switch.
  int activate(Object tab, {bool cancelPrevious = true, String? message}) {
    _ensureUsable();
    final previous = _activeTab;
    if (previous == tab) return 0;
    _activeTab = tab;
    if (!cancelPrevious || previous == null) return 0;
    return _cancelTab(
      previous,
      message ?? 'Tab $previous deactivated when $tab became active',
    );
  }

  /// Marks [tab] inactive and cancels requests owned by it.
  int deactivate(Object tab, [String? message]) {
    _ensureUsable();
    if (_activeTab == tab) _activeTab = null;
    return _cancelTab(tab, message ?? 'Tab $tab deactivated');
  }

  /// Cancels current requests for [tab] while keeping its scope reusable.
  int cancelTab(Object tab, [String? message]) {
    _ensureUsable();
    return _cancelTab(tab, message ?? 'Requests for tab $tab cancelled');
  }

  /// Permanently removes one tab scope and cancels its active requests.
  bool disposeTab(Object tab, [String? message]) {
    _ensureUsable();
    if (_activeTab == tab) _activeTab = null;
    final scope = _scopes.remove(tab);
    if (scope == null) return false;
    scope.dispose(message ?? 'Tab $tab disposed');
    return true;
  }

  /// Explicitly runs a request under [tab] and establishes its inherited Zone.
  Future<T> run<T>(
    Object tab,
    RequestCall<T> request, {
    RequestContext context = const RequestContext(),
  }) {
    _ensureUsable();
    return TabScoped.using(
      tab,
      () => _scopeFor(tab).run(request, context: context),
    );
  }

  /// Explicitly runs a parameterized service under [tab].
  Future<T> runService<T, P>(
    Object tab,
    RequestService<T, P> service,
    P params, {
    RequestContext context = const RequestContext(),
  }) {
    return run(
      tab,
      (scopedContext) => service(params, scopedContext),
      context: context,
    );
  }

  /// Binds a fixed-parameter request to the current [TabScoped] zone.
  RequestWrapper<T> wrapper<T>() =>
      (next) => (context) {
        _ensureUsable();
        if (TabScoped.isUnscoped) return next(context);
        final tab = TabScoped.current;
        if (tab == null) return _handleMissingScope(next, context);
        return _scopeFor(tab).run(next, context: context);
      };

  /// Binds a parameterized service to the current [TabScoped] zone.
  RequestServiceWrapper<T, P> serviceWrapper<T, P>() =>
      (next) => (params, context) {
        _ensureUsable();
        if (TabScoped.isUnscoped) return next(params, context);
        final tab = TabScoped.current;
        if (tab == null) {
          onMissingScope?.call(context);
          if (requireScope) {
            throw StateError(
              'No TabScoped zone is active. Wrap the call with '
              'TabScoped.using() or TabScoped.unscoped().',
            );
          }
          return next(params, context);
        }
        return _scopeFor(
          tab,
        ).run((scopedContext) => next(params, scopedContext), context: context);
      };

  /// Permanently closes all tab scopes and cancels their active requests.
  void dispose([String? message]) {
    if (_disposed) return;
    _disposed = true;
    _activeTab = null;
    for (final entry in _scopes.entries) {
      entry.value.dispose(message ?? 'Tab ${entry.key} disposed');
    }
    _scopes.clear();
  }

  Future<T> _handleMissingScope<T>(
    RequestCall<T> next,
    RequestContext context,
  ) {
    onMissingScope?.call(context);
    if (requireScope) {
      throw StateError(
        'No TabScoped zone is active. Wrap the call with '
        'TabScoped.using() or TabScoped.unscoped().',
      );
    }
    return next(context);
  }

  RequestScope _scopeFor(Object tab) =>
      _scopes.putIfAbsent(tab, RequestScope.new);

  int _cancelTab(Object tab, String message) {
    return _scopes[tab]?.cancelAllWithReason(
          RequestCancellationReason(
            RequestCancellationKind.tabDeactivated,
            message,
          ),
        ) ??
        0;
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('TabScopeManager has been disposed.');
  }
}
