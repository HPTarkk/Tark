import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/network/http_service_client.dart';
import 'package:tark/core/network/service_api.dart';

void main() {
  final base = Uri.parse('https://api.example.test/v1');

  HttpTarkServiceClient clientFor(
    MockClientHandler handler, {
    Duration timeout = const Duration(seconds: 5),
    int maxBytes = 64 * 1024,
    Uri? baseUrl,
  }) => HttpTarkServiceClient(
    baseUrl: baseUrl ?? base,
    client: MockClient(handler),
    commonHeaders: () async => {
      'X-Tark-Platform': 'android',
      'X-Tark-Install-Key': 'k' * 43,
    },
    timeout: timeout,
    maxBytes: maxBytes,
  );

  test('sends JSON with the common headers and the idempotency key', () async {
    late http.Request seen;
    final client = clientFor((request) async {
      seen = request;
      return http.Response(
        jsonEncode({'flowId': 'f'}),
        202,
        headers: {'content-type': 'application/json'},
      );
    });

    final response = await client.send(
      const ApiRequest.post(
        '/auth/register',
        body: {'email': 'a@b.co'},
        idempotencyKey: 'key-1',
      ),
    );

    expect(response, isA<ApiOk>());
    expect((response as ApiOk).statusCode, 202);
    expect(response.body, {'flowId': 'f'});
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://api.example.test/v1/auth/register');
    expect(seen.headers['X-Tark-Platform'], 'android');
    expect(seen.headers['X-Tark-Install-Key'], 'k' * 43);
    expect(seen.headers['Idempotency-Key'], 'key-1');
    expect(seen.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(seen.body), {'email': 'a@b.co'});
  });

  test('204 is success with an empty body', () async {
    final client = clientFor((_) async => http.Response('', 204));
    final response = await client.send(const ApiRequest.post('/auth/logout'));
    expect(response, isA<ApiOk>());
    expect((response as ApiOk).body, isEmpty);
  });

  test('a Problem keeps its code and extras, never its detail', () async {
    final client = clientFor(
      (_) async => http.Response(
        jsonEncode({
          'code': 'code_invalid',
          'detail': 'developer words',
          'attemptsLeft': 3,
          'retryAfterMs': 1500,
        }),
        422,
      ),
    );
    final response = await client.send(
      const ApiRequest.post('/auth/register/verify'),
    );
    expect(response, isA<ApiProblem>());
    final problem = response as ApiProblem;
    expect(problem.statusCode, 422);
    expect(problem.code, 'code_invalid');
    expect(problem.intField('attemptsLeft'), 3);
    expect(problem.fields.containsKey('detail'), isFalse);
    expect(problem.retryAfter, const Duration(milliseconds: 1500));
  });

  test('Retry-After header is used when the body has no hint', () async {
    final client = clientFor(
      (_) async => http.Response(
        jsonEncode({'code': 'rate_limited'}),
        429,
        headers: {'retry-after': '7'},
      ),
    );
    final response = await client.send(const ApiRequest.post('/auth/login'));
    expect((response as ApiProblem).retryAfter, const Duration(seconds: 7));
  });

  test('a gateway page without a Problem gets a status code', () async {
    final client = clientFor(
      (_) async => http.Response('<html>Bad gateway</html>', 502),
    );
    final response = await client.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiProblem>());
    expect((response as ApiProblem).code, 'http_502');
  });

  test('a 200 that is not a JSON object is a broken reply', () async {
    final client = clientFor((_) async => http.Response('[1,2]', 200));
    final response = await client.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiTransportFailure>());
    final failure = response as ApiTransportFailure;
    expect(failure.failure, isA<MalformedResponse>());
    expect(failure.unreachable, isFalse);
  });

  test('an oversized body is cut off', () async {
    final client = clientFor(
      (_) async => http.Response('x' * 2048, 200),
      maxBytes: 1024,
    );
    final response = await client.send(const ApiRequest.get('/profile'));
    expect((response as ApiTransportFailure).failure, isA<ResponseTooLarge>());
  });

  test('a network error is unreachable, never an exception', () async {
    final client = clientFor(
      (_) async => throw http.ClientException('no route to host'),
    );
    final response = await client.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiTransportFailure>());
    expect((response as ApiTransportFailure).unreachable, isTrue);
  });

  test('a server that never answers times out', () async {
    final client = clientFor(
      (_) => Completer<http.Response>().future,
      timeout: const Duration(milliseconds: 20),
    );
    final response = await client.send(const ApiRequest.get('/profile'));
    expect((response as ApiTransportFailure).failure, isA<RequestTimedOut>());
    expect(response.unreachable, isTrue);
  });

  test('refuses a plaintext base URL before sending anything', () async {
    var sent = false;
    final client = clientFor((_) async {
      sent = true;
      return http.Response('{}', 200);
    }, baseUrl: Uri.parse('http://api.example.test/v1'));
    final response = await client.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiTransportFailure>());
    expect(sent, isFalse);
  });

  test('allows plain http to a backend on the local network', () async {
    Uri? seen;
    final client = clientFor((request) async {
      seen = request.url;
      return http.Response('{}', 200);
    }, baseUrl: Uri.parse('http://192.168.8.187:8080/v1'));
    final response = await client.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiOk>());
    expect(seen.toString(), 'http://192.168.8.187:8080/v1/profile');
  });

  test('plain http is limited to loopback and private addresses', () {
    for (final ok in [
      'http://localhost:8080/v1',
      'http://127.0.0.1:8080/v1',
      'http://10.0.2.2:8080/v1',
      'http://172.20.1.5/v1',
      'http://192.168.1.10/v1',
    ]) {
      expect(allowsPlainHttp(Uri.parse(ok)), isTrue, reason: ok);
    }
    for (final no in [
      'http://api.example.test/v1',
      'http://8.8.8.8/v1',
      'http://172.32.0.1/v1',
      'http://192.169.0.1/v1',
      'http://10.0.0.1.example.test/v1',
      'https://192.168.1.10/v1',
    ]) {
      expect(allowsPlainHttp(Uri.parse(no)), isFalse, reason: no);
    }
  });

  test('idempotency keys are random version-4 UUIDs', () {
    final a = newIdempotencyKey();
    final b = newIdempotencyKey();
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(uuid.hasMatch(a), isTrue);
    expect(a, isNot(b));
  });
}
