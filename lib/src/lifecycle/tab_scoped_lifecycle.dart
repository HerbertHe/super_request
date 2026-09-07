import '../core/context.dart';
import '../core/pipeline.dart';
import '../core/request_service.dart';
import 'tab_scoped.dart';

/// Adapts a page or controller lifecycle to [TabScopeManager].
///
/// The host must call [handleTabShown], [handleTabHidden], and
/// [disposeTabScoped] from its real lifecycle. Keeping this mixin independent
/// of Flutter lets the same behavior work with State, BLoC, GetX, and other
/// presentation frameworks.
mixin TabScopedLifecycle {
  bool _tabScopedActive = false;
  bool _tabScopedDisposed = false;
  int _tabShownCount = 0;

  /// The manager shared by pages in the same tab host.
  TabScopeManager get tabScopeManager;

  /// Stable identity for the tab represented by this lifecycle owner.
  Object get tabScopeKey;

  bool get tabScopedActive => _tabScopedActive && !_tabScopedDisposed;
  bool get tabScopedDisposed => _tabScopedDisposed;
  int get tabShownCount => _tabShownCount;
  bool get isFirstTabShow => _tabShownCount == 1;

  /// Marks this tab visible and invokes [onTabShown] once per transition.
  void handleTabShown() {
    _ensureNotDisposed();
    if (_tabScopedActive) return;
    tabScopeManager.activate(tabScopeKey);
    _tabScopedActive = true;
    _tabShownCount++;
    onTabShown();
  }

  /// Marks this tab hidden, cancels its requests, and invokes [onTabHidden].
  void handleTabHidden() {
    _ensureNotDisposed();
    if (!_tabScopedActive) return;
    _tabScopedActive = false;
    tabScopeManager.deactivate(tabScopeKey);
    onTabHidden();
  }

  /// Runs arbitrary asynchronous work in this page's inherited tab Zone.
  Future<T> runTabScoped<T>(Future<T> Function() body) {
    _ensureNotDisposed();
    return TabScoped.using(tabScopeKey, body);
  }

  /// Runs shared work that must survive this page becoming hidden.
  Future<T> runTabUnscoped<T>(Future<T> Function() body) {
    _ensureNotDisposed();
    return TabScoped.unscoped(body);
  }

  /// Runs a typed request directly under this page's tab scope.
  Future<T> runTabRequest<T>(
    RequestCall<T> request, {
    RequestContext context = const RequestContext(),
  }) {
    _ensureNotDisposed();
    return tabScopeManager.run(tabScopeKey, request, context: context);
  }

  /// Runs a typed parameterized service directly under this page's tab scope.
  Future<T> runTabService<T, P>(
    RequestService<T, P> service,
    P params, {
    RequestContext context = const RequestContext(),
  }) {
    _ensureNotDisposed();
    return tabScopeManager.runService(
      tabScopeKey,
      service,
      params,
      context: context,
    );
  }

  /// Permanently releases this page's tab scope. Safe to call more than once.
  void disposeTabScoped([String? message]) {
    if (_tabScopedDisposed) return;
    _tabScopedDisposed = true;
    _tabScopedActive = false;
    if (!tabScopeManager.isDisposed) {
      tabScopeManager.disposeTab(
        tabScopeKey,
        message ?? 'Tab-scoped lifecycle disposed',
      );
    }
  }

  /// Called after the tab changes from hidden to visible.
  void onTabShown() {}

  /// Called after the tab changes from visible to hidden and requests cancel.
  void onTabHidden() {}

  void _ensureNotDisposed() {
    if (_tabScopedDisposed) {
      throw StateError('TabScopedLifecycle has been disposed.');
    }
  }
}
