import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/account/account_store.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/network/authenticated_api_client.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/core/security/app_secure_storage.dart';

import '../account/account_fakes.dart';

void main() {
  late FakeServiceClient server;
  late AccountStore vault;
  late DateTime now;
  late AuthenticatedApiClient api;

  setUp(() async {
    server = FakeServiceClient();
    vault = AccountStore(MemoryAppSecureStorage());
    now = DateTime.utc(2026, 9, 29, 12);
    api = AuthenticatedApiClient(server, vault, clock: () => now);
    await api.adopt(SessionTokens.fromJson(tokensJson())!);
  });

  String? bearer(ApiRequest r) => r.headers['Authorization'];

  test('adds the bearer token', () async {
    server.handler = (_) async => const ApiOk(200, {'ok': true});
    final response = await api.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiOk>());
    expect(bearer(server.requests.single), 'Bearer access-1');
  });

  test('without a session answers signed out and sends nothing', () async {
    await vault.clearTokens();
    final response = await api.send(const ApiRequest.get('/profile'));
    expect(response, isA<ApiSignedOut>());
    expect(server.requests, isEmpty);
  });

  test(
    'a 401 refreshes once and repeats the call with the new token',
    () async {
      server.handler = (r) async {
        if (r.path == '/auth/token/refresh') {
          expect(r.body, {'refreshToken': 'refresh-1'});
          return ApiOk(
            200,
            tokensJson(access: 'access-2', refresh: 'refresh-2'),
          );
        }
        return bearer(r) == 'Bearer access-2'
            ? const ApiOk(200, {'ok': true})
            : const ApiProblem(401, 'unauthorized');
      };

      final response = await api.send(const ApiRequest.get('/profile'));

      expect(response, isA<ApiOk>());
      expect(server.paths, ['/profile', '/auth/token/refresh', '/profile']);
      expect(bearer(server.requests.last), 'Bearer access-2');
      final stored = await vault.readTokens();
      expect(stored!.refreshToken, 'refresh-2');
    },
  );

  test('the idempotency key survives the refresh-and-repeat', () async {
    server.handler = (r) async {
      if (r.path == '/auth/token/refresh') {
        return ApiOk(200, tokensJson(access: 'access-2', refresh: 'refresh-2'));
      }
      return bearer(r) == 'Bearer access-2'
          ? const ApiOk(200, {})
          : const ApiProblem(401, 'unauthorized');
    };
    await api.send(
      const ApiRequest.post(
        '/subscription/bazaar/purchases',
        idempotencyKey: 'k',
      ),
    );
    final purchases = server.to('/subscription/bazaar/purchases').toList();
    expect(purchases, hasLength(2));
    expect(purchases.map((r) => r.idempotencyKey), everyElement('k'));
  });

  test(
    'concurrent 401s share one refresh (refresh tokens work once)',
    () async {
      final refreshAnswer = Completer<ApiResponse>();
      server.handler = (r) async {
        if (r.path == '/auth/token/refresh') return refreshAnswer.future;
        return bearer(r) == 'Bearer access-2'
            ? const ApiOk(200, {})
            : const ApiProblem(401, 'unauthorized');
      };

      final calls = [
        api.send(const ApiRequest.get('/profile')),
        api.send(const ApiRequest.get('/subscription')),
        api.send(const ApiRequest.get('/profile')),
      ];
      await Future<void>.delayed(Duration.zero);
      refreshAnswer.complete(
        ApiOk(200, tokensJson(access: 'access-2', refresh: 'refresh-2')),
      );
      final results = await Future.wait(calls);

      expect(results, everyElement(isA<ApiOk>()));
      expect(server.to('/auth/token/refresh'), hasLength(1));
    },
  );

  test('an expired access token is refreshed before use', () async {
    await api.adopt(
      SessionTokens.fromJson(
        tokensJson(accessExp: now.millisecondsSinceEpoch - 1000),
      )!,
    );
    server.handler = (r) async => r.path == '/auth/token/refresh'
        ? ApiOk(200, tokensJson(access: 'access-2', refresh: 'refresh-2'))
        : const ApiOk(200, {});

    await api.send(const ApiRequest.get('/profile'));

    expect(server.paths, ['/auth/token/refresh', '/profile']);
    expect(bearer(server.requests.last), 'Bearer access-2');
  });

  test('a refused refresh ends the session', () async {
    var ended = 0;
    api.sessionEnded.listen((_) => ended++);
    server.handler = (r) async => r.path == '/auth/token/refresh'
        ? const ApiProblem(401, 'session_ended')
        : const ApiProblem(401, 'unauthorized');

    final response = await api.send(const ApiRequest.get('/profile'));
    await Future<void>.delayed(Duration.zero);

    expect(response, isA<ApiSignedOut>());
    expect(await vault.readTokens(), isNull);
    expect(ended, 1);
  });

  test('a refresh that cannot reach the server keeps the session', () async {
    server.handler = (r) async => r.path == '/auth/token/refresh'
        ? const ApiTransportFailure(NetworkUnreachable('offline'))
        : const ApiProblem(401, 'unauthorized');

    final response = await api.send(const ApiRequest.get('/profile'));

    expect(response, isA<ApiTransportFailure>());
    expect(await vault.readTokens(), isNotNull);
  });

  test(
    'logout forgets the tokens even when the server is unreachable',
    () async {
      server.handler = (_) async =>
          const ApiTransportFailure(NetworkUnreachable('offline'));
      await api.logout();
      expect(server.paths, ['/auth/logout']);
      expect(await vault.readTokens(), isNull);
    },
  );

  test('logout everywhere calls logout-all', () async {
    server.handler = (_) async => const ApiOk(204, {});
    await api.logout(everywhere: true);
    expect(server.paths, ['/auth/logout-all']);
    expect(bearer(server.requests.single), 'Bearer access-1');
    expect(await vault.readTokens(), isNull);
  });
}
