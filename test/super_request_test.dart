import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:super_request/super_request.dart';
import 'package:test/test.dart';

void main() {
  group('pipeline', () {
    test('wrappers are applied in declaration order', () async {
      final events = <String>[];

      RequestWrapper<int> named(String name) =>
          (next) => (context) async {
            events.add('$name:before');
            final value = await next(context);
            events.add('$name:after');
            return value;
          };

      final pipeline = RequestPipeline<int>((_) async {
        events.add('request');
        return 42;
      }).use(named('outer')).use(named('inner'));

      expect(await pipeline.run(), 42);
      expect(events, [
        'outer:before',
        'inner:before',
        'request',
        'inner:after',
        'outer:after',
      ]);
    });
  });

  group('Dio adapter', () {
    test('decodes a lazy response', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((options, _) async {
        expect(options.path, '/users/1');
        expect(options.method, 'GET');
        return ResponseBody.fromString(
          '{"id":1,"name":"Ada"}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = SuperRequestClient(dio: dio);

      final request = client.request<Map<String, dynamic>>(
        '/users/1',
        decoder: (data, _) => Map<String, dynamic>.from(data! as Map),
      );

      expect((await request(const RequestContext()))['name'], 'Ada');
    });

    test('bridges scope cancellation to Dio CancelToken', () async {
      final started = Completer<void>();
      final transportCancelled = Completer<void>();
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((_, cancelFuture) {
        started.complete();
        cancelFuture!.then((_) => transportCancelled.complete());
        return Completer<ResponseBody>().future;
      });
      final scope = RequestScope();
      final request = scope.run(
        SuperRequestClient(dio: dio).request<Object?>('/slow'),
      );
      final expectation = expectLater(
        request,
        throwsA(isA<RequestCancelledException>()),
      );

      await started.future;
      scope.dispose();
      await transportCancelled.future;
      await expectation;
    });

    test('detaches cancellation listener after request completion', () async {
      var transportCancelled = false;
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter((_, cancelFuture) {
        cancelFuture!.then((_) => transportCancelled = true);
        return Future.value(ResponseBody.fromString('1', 200));
      });
      final cancellation = RequestCancellationController();
      final request = SuperRequestClient(
        dio: dio,
      ).request<int>('/done', decoder: (data, _) => int.parse(data! as String));

      expect(
        await request(RequestContext(cancellationToken: cancellation.token)),
        1,
      );
      cancellation.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(transportCancelled, isFalse);
    });
  });

  group('scope', () {
    test('dispose cancels active work immediately', () async {
      final scope = RequestScope();
      final underlying = Completer<int>();
      final request = scope.run<int>((_) => underlying.future);
      final expectation = expectLater(
        request,
        throwsA(
          isA<RequestCancelledException>().having(
            (error) => error.reason.kind,
            'kind',
            RequestCancellationKind.scopeDisposed,
          ),
        ),
      );

      expect(scope.activeRequestCount, 1);
      scope.dispose();
      await expectation;
      expect(scope.activeRequestCount, 0);
    });

    test('cancelAll does not dispose the scope', () async {
      final scope = RequestScope();
      final request = scope.run<int>((_) => Completer<int>().future);
      final expectation = expectLater(
        request,
        throwsA(isA<RequestCancelledException>()),
      );
      scope.cancelAll();
      await expectation;

      expect(scope.isDisposed, isFalse);
      expect(await scope.run((_) async => 7), 7);
    });
  });

  group('generations', () {
    test('new request supersedes the previous generation', () async {
      final manager = RequestGenerationManager();
      final firstCompleter = Completer<int>();
      final secondCompleter = Completer<int>();

      final first = manager.runLatest('search', (_) => firstCompleter.future);
      final firstExpectation = expectLater(
        first,
        throwsA(isA<SupersededRequestException>()),
      );
      final second = manager.runLatest('search', (_) => secondCompleter.future);
      secondCompleter.complete(2);

      await firstExpectation;
      expect(await second, 2);
      expect(manager.current('search'), 2);
    });

    test(
      'stale result is rejected even without transport cancellation',
      () async {
        final manager = RequestGenerationManager();
        final firstCompleter = Completer<int>();

        final first = manager.runLatest(
          'search',
          (_) => firstCompleter.future,
          cancelPrevious: false,
        );
        final second = manager.runLatest(
          'search',
          (_) async => 2,
          cancelPrevious: false,
        );
        firstCompleter.complete(1);

        expect(await second, 2);
        await expectLater(first, throwsA(isA<SupersededRequestException>()));
      },
    );
  });

  group('policies', () {
    test('retry updates attempt and eventually succeeds', () async {
      final attempts = <int>[];
      final pipeline = RequestPipeline<int>((context) async {
        attempts.add(context.attempt);
        if (context.attempt < 3) throw StateError('not yet');
        return 9;
      }).use(
        retry(const RetryPolicy(maxAttempts: 3, initialDelay: Duration.zero)),
      );

      expect(await pipeline.run(), 9);
      expect(attempts, [1, 2, 3]);
    });

    test('timeout does not wait for an uncooperative request', () async {
      final pipeline = RequestPipeline<int>(
        (_) => Completer<int>().future,
      ).use(requestTimeout(const Duration(milliseconds: 10)));

      await expectLater(
        pipeline.run(),
        throwsA(isA<RequestTimeoutException>()),
      );
    });
  });

  group('polling', () {
    test('polls until the predicate succeeds', () async {
      var value = 0;
      final result = await const RequestPoller().poll<int>(
        request: (context) async {
          expect(context.attempt, value + 1);
          return ++value;
        },
        until: (current) => current == 3,
        options: const PollOptions(interval: Duration.zero, maxAttempts: 3),
      );

      expect(result.value, 3);
      expect(result.attempts, 3);
    });

    test('throws when max attempts are exhausted', () async {
      await expectLater(
        const RequestPoller().poll<int>(
          request: (_) async => 1,
          until: (_) => false,
          options: const PollOptions(interval: Duration.zero, maxAttempts: 2),
        ),
        throwsA(isA<PollAttemptsExceededException>()),
      );
    });

    test('watch emits values and marks the final event', () async {
      var value = 0;
      final events =
          await const RequestPoller()
              .watch<int>(
                request: (_) async => ++value,
                until: (current) => current == 2,
                options: const PollOptions(interval: Duration.zero),
              )
              .where((event) => event is PollValue<int>)
              .cast<PollValue<int>>()
              .toList();

      expect(events.map((event) => event.value), [1, 2]);
      expect(events.last.done, isTrue);
    });

    test('cancelling watch interrupts an uncooperative request', () async {
      final started = Completer<void>();
      final cancelled = Completer<RequestCancellationReason>();
      final subscription = const RequestPoller()
          .watch<int>(
            request: (context) {
              started.complete();
              context.cancellationToken.whenCancelled.then(cancelled.complete);
              return Completer<int>().future;
            },
            until: (_) => false,
          )
          .listen((_) {});

      await started.future;
      await subscription.cancel();
      expect((await cancelled.future).kind, RequestCancellationKind.cancelled);
    });

    test('cancellation interrupts a slow asynchronous predicate', () async {
      final cancellation = RequestCancellationController();
      final predicateStarted = Completer<void>();
      final future = const RequestPoller().poll<int>(
        request: (_) async => 1,
        until: (_) {
          predicateStarted.complete();
          return Completer<bool>().future;
        },
        context: RequestContext(cancellationToken: cancellation.token),
      );
      final expectation = expectLater(
        future,
        throwsA(isA<RequestCancelledException>()),
      );

      await predicateStarted.future;
      cancellation.cancel();
      await expectation;
    });

    test('validates options at runtime', () {
      expect(
        () => const RequestPoller().watch<int>(
          request: (_) async => 1,
          until: (_) => true,
          options: const PollOptions(interval: Duration(milliseconds: -1)),
        ),
        throwsArgumentError,
      );
    });
  });

  group('request queue', () {
    test('limits concurrent slow requests and preserves FIFO order', () async {
      final queue = RequestQueue(maxConcurrent: 2);
      final started = <int>[];
      final firstDone = Completer<int>();
      final secondDone = Completer<int>();
      final thirdDone = Completer<int>();

      RequestQueueTask<int> add(int id, Completer<int> done) =>
          queue.enqueue((_) {
            started.add(id);
            return done.future;
          }, id: id);

      final first = add(1, firstDone);
      final second = add(2, secondDone);
      final third = add(3, thirdDone);

      expect(started, [1, 2]);
      expect(queue.runningCount, 2);
      expect(queue.queuedCount, 1);
      expect(third.state, RequestQueueTaskState.queued);

      firstDone.complete(1);
      expect(await first.future, 1);
      await Future<void>.delayed(Duration.zero);
      expect(started, [1, 2, 3]);
      expect(third.state, RequestQueueTaskState.running);

      secondDone.complete(2);
      thirdDone.complete(3);
      expect(await second.future, 2);
      expect(await third.future, 3);
      expect(queue.isIdle, isTrue);
    });

    test('cancelled queued request is never started', () async {
      final queue = RequestQueue();
      final blocker = Completer<int>();
      var secondStarted = false;
      final first = queue.enqueue((_) => blocker.future, id: 'first');
      final second = queue.enqueue<int>((_) async {
        secondStarted = true;
        return 2;
      }, id: 'second');
      final expectation = expectLater(
        second.future,
        throwsA(isA<RequestCancelledException>()),
      );

      second.cancel();
      await expectation;
      expect(secondStarted, isFalse);
      expect(second.state, RequestQueueTaskState.cancelled);

      blocker.complete(1);
      expect(await first.future, 1);
    });

    test(
      'running slow request terminates without waiting for its Future',
      () async {
        final queue = RequestQueue();
        final started = Completer<void>();
        final task = queue.enqueue<int>((_) {
          started.complete();
          return Completer<int>().future;
        }, id: 'slow');
        final expectation = expectLater(
          task.future,
          throwsA(isA<RequestCancelledException>()),
        );

        await started.future;
        expect(queue.cancel('slow'), isTrue);
        await expectation;
        expect(task.state, RequestQueueTaskState.cancelled);
        expect(queue.isIdle, isTrue);
      },
    );

    test('acts as a wrapper for typed parameterized services', () async {
      final queue = RequestQueue();
      final firstDone = Completer<String>();
      final secondDone = Completer<String>();
      final started = <int>[];
      final request = useRequest<String, int>((id, _) {
        started.add(id);
        return id == 1 ? firstDone.future : secondDone.future;
      }, wrappers: [queue.wrapper()]);

      final first = request.run(1);
      final second = request.run(2);
      expect(started, [1]);
      expect(queue.queuedCount, 1);

      firstDone.complete('first');
      expect(await first, 'first');
      await Future<void>.delayed(Duration.zero);
      expect(started, [1, 2]);
      secondDone.complete('second');
      expect(await second, 'second');
      request.dispose();
      queue.dispose();
    });

    test(
      'dispose remains awaitable until running requests terminate',
      () async {
        final queue = RequestQueue();
        final task = queue.enqueue<int>((_) => Completer<int>().future);
        final expectation = expectLater(
          task.future,
          throwsA(isA<RequestCancelledException>()),
        );

        queue.dispose();
        await queue.idle;
        await expectation;
        expect(queue.isIdle, isTrue);
        expect(await queue.changes.isEmpty, isTrue);
      },
    );
  });

  group('service wrappers', () {
    test('debounce only executes the latest parameters', () async {
      final executed = <int>[];
      final request = useRequest<int, int>((params, _) async {
        executed.add(params);
        return params;
      }, wrappers: [requestDebounce(const Duration(milliseconds: 10))]);

      final first = request.run(1);
      final firstExpectation = expectLater(
        first,
        throwsA(isA<SupersededRequestException>()),
      );
      final second = request.run(2);

      await firstExpectation;
      expect(await second, 2);
      expect(executed, [2]);
      request.dispose();
    });

    test('reused debounce wrapper isolates each service instance', () async {
      final wrapper = requestDebounce<int, int>(Duration.zero);
      final firstService = composeService<int, int>((value, _) async => value, [
        wrapper,
      ]);
      final secondService = composeService<int, int>(
        (value, _) async => value,
        [wrapper],
      );

      final results = await Future.wait([
        firstService(1, const RequestContext()),
        secondService(2, const RequestContext()),
      ]);
      expect(results, [1, 2]);
    });

    test('throttle shares one request during the window', () async {
      var calls = 0;
      final done = Completer<int>();
      final service = composeService<int, int>((_, _) {
        calls++;
        return done.future;
      }, [requestThrottle(const Duration(seconds: 1))]);

      final first = service(1, const RequestContext());
      final second = service(2, const RequestContext());
      expect(calls, 1);
      done.complete(7);
      expect(await first, 7);
      expect(await second, 7);
    });

    test(
      'cache deduplicates slow requests and reuses the typed value',
      () async {
        final cache = RequestCache<String>();
        final done = Completer<String>();
        var calls = 0;
        final service = composeService<String, int>((_, _) {
          calls++;
          return done.future;
        }, [requestCache(cache, keyOf: (id) => id)]);

        final first = service(1, const RequestContext());
        final second = service(1, const RequestContext());
        expect(calls, 1);
        done.complete('user-1');
        expect(await first, 'user-1');
        expect(await second, 'user-1');
        expect(await service(1, const RequestContext()), 'user-1');
        expect(calls, 1);
      },
    );

    test('service retry preserves typed params across attempts', () async {
      final attempts = <int>[];
      final service = composeService<String, int>(
        (id, context) async {
          attempts.add(context.attempt);
          if (context.attempt == 1) throw StateError('temporary');
          return 'item-$id';
        },
        [
          serviceRetry(
            const RetryPolicy(maxAttempts: 2, initialDelay: Duration.zero),
          ),
        ],
      );

      expect(await service(7, const RequestContext()), 'item-7');
      expect(attempts, [1, 2]);
    });

    test('cache evicts old completed entries at its capacity', () async {
      final cache = RequestCache<int>(maxEntries: 2);
      final service = composeService<int, int>((value, _) async => value, [
        requestCache(cache, keyOf: (value) => value),
      ]);

      await service(1, const RequestContext());
      await service(2, const RequestContext());
      await service(3, const RequestContext());
      expect(cache.length, 2);
      expect(cache.contains(1), isFalse);
      expect(cache.keys, containsAll([2, 3]));
    });
  });

  group('useRequest', () {
    test('tracks concurrent loading and only commits latest data', () async {
      final firstDone = Completer<int>();
      final secondDone = Completer<int>();
      final request = useRequest<int, int>(
        (params, _) => params == 1 ? firstDone.future : secondDone.future,
      );

      final first = request.run(1);
      final second = request.run(2);
      expect(request.state.loading, isTrue);
      expect(request.state.activeRequests, 2);

      secondDone.complete(20);
      expect(await second, 20);
      expect(request.state.data, 20);
      expect(request.state.loading, isTrue);

      firstDone.complete(10);
      expect(await first, 10);
      expect(request.state.data, 20);
      expect(request.state.loading, isFalse);
      expect(request.state.activeRequests, 0);
      request.dispose();
    });

    test('terminate interrupts an uncooperative slow request', () async {
      final started = Completer<void>();
      final request = useRequest<int, void>((_, _) {
        started.complete();
        return Completer<int>().future;
      });
      final future = request.run(null);
      final expectation = expectLater(
        future,
        throwsA(isA<RequestCancelledException>()),
      );

      await started.future;
      request.terminate();
      await expectation;
      expect(request.state.loading, isFalse);
      request.dispose();
    });

    test('stopPolling cancels the current slow poll', () async {
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final request = useRequest<int, int>((_, context) {
        started.complete();
        context.cancellationToken.whenCancelled.then((_) {
          if (!cancelled.isCompleted) cancelled.complete();
        });
        return Completer<int>().future;
      });

      request.startPolling(
        1,
        options: const PollOptions(interval: Duration.zero),
      );
      await started.future;
      request.stopPolling();
      await cancelled.future;
      await Future<void>.delayed(Duration.zero);
      expect(request.state.polling, isFalse);
      expect(request.state.loading, isFalse);
      request.dispose();
    });

    test('supports nullable typed params and data', () async {
      final request = useRequest<String?, int?>((value, _) async {
        return value?.toString();
      });

      expect(await request.run(null), isNull);
      expect(request.state.hasParams, isTrue);
      expect(request.state.params, isNull);
      expect(request.state.hasData, isTrue);
      expect(request.state.data, isNull);
      expect(await request.refresh(), isNull);
      request.dispose();
    });

    test('exposes lifecycle callbacks and error stack trace', () async {
      final events = <String>[];
      final request = useRequest<int, int>(
        (_, _) => throw StateError('failed'),
        onBefore: (params) => events.add('before:$params'),
        onError: (error, _, params) => events.add('error:$params'),
        onFinally: (params) => events.add('finally:$params'),
      );

      await expectLater(request.run(4), throwsStateError);
      expect(events, ['before:4', 'error:4', 'finally:4']);
      expect(request.state.error, isA<StateError>());
      expect(request.state.stackTrace, isNotNull);
      request.reset();
      expect(request.state.hasData, isFalse);
      expect(request.state.error, isNull);
      request.dispose();
    });
  });
}

final class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )
  handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options, cancelFuture);

  @override
  void close({bool force = false}) {}
}
