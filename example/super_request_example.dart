import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:super_request/super_request.dart';

Future<void> main() async {
  final client = SuperRequestClient(
    dio: Dio(BaseOptions(baseUrl: 'https://jsonplaceholder.typicode.com')),
  );
  final scope = RequestScope();
  final generations = RequestGenerationManager();

  final getTodo = client.request<Map<String, dynamic>>(
    '/todos/1',
    decoder: (data, _) => Map<String, dynamic>.from(data! as Map),
  );

  final pipeline = RequestPipeline(getTodo)
      .use(scope.wrapper())
      .use(generations.wrapper('todo-detail'))
      .use(requestTimeout(const Duration(seconds: 5)))
      .use(retry(const RetryPolicy(maxAttempts: 3)));

  final todo = await pipeline.run(
    const RequestContext(metadata: {'trace-id': 'example'}),
  );
  // ignore: avoid_print
  print(const JsonEncoder.withIndent('  ').convert(todo));

  final queue = RequestQueue(maxConcurrent: 2);
  final todoById = useRequest<Map<String, dynamic>, int>(
    serviceFromCall(
      (id) => client.request(
        '/todos/$id',
        decoder: (data, _) => Map<String, dynamic>.from(data! as Map),
      ),
    ),
    wrappers: [
      requestDebounce(const Duration(milliseconds: 200)),
      serviceRetry(const RetryPolicy(maxAttempts: 2)),
      queue.wrapper(),
    ],
  );
  await todoById.run(1);

  final result = await const RequestPoller().poll(
    request: getTodo,
    until: (value) => value['id'] == 1,
    options: const PollOptions(
      interval: Duration(seconds: 1),
      maxAttempts: 10,
      timeout: Duration(seconds: 30),
    ),
  );
  // ignore: avoid_print
  print('completed after ${result.attempts} attempts');

  todoById.dispose();
  queue.dispose();
  scope.dispose();
}
