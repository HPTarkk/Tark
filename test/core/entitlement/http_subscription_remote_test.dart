import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/account/account_store.dart';
import 'package:tark/core/entitlement/http_subscription_remote.dart';
import 'package:tark/core/entitlement/subscription_remote.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/network/authenticated_api_client.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/core/security/app_secure_storage.dart';

import '../account/account_fakes.dart';

void main() {
  late FakeServiceClient server;
  late AuthenticatedApiClient api;
  late List<Duration> slept;
  late HttpSubscriptionRemote remote;
  var keys = 0;

  final installKey = 'i' * 43;

  setUp(() async {
    server = FakeServiceClient();
    final vault = AccountStore(MemoryAppSecureStorage());
    api = AuthenticatedApiClient(server, vault);
    await api.adopt(SessionTokens.fromJson(tokensJson())!);
    slept = [];
    keys = 0;
    remote = HttpSubscriptionRemote(
      api,
      sleep: (d) async => slept.add(d),
      newKey: () => 'key-${++keys}',
    );
  });

  group('fetch', () {
    test(
      'an entitlement comes back as-is, with the install key sent',
      () async {
        server.handler = (_) async => const ApiOk(200, {
          'entitlement': 'v1.k.p.s',
          'bazaarChecked': false,
        });
        final fetch = await remote.fetch(installKey: installKey);
        expect(fetch, isA<FetchedEntitlement>());
        expect((fetch as FetchedEntitlement).token, 'v1.k.p.s');
        expect(fetch.bazaarChecked, isFalse);
        final request = server.requests.single;
        expect(request.path, '/subscription');
        expect(request.headers['X-Tark-Install-Key'], installKey);
        expect(request.headers['Authorization'], 'Bearer access-1');
        expect(request.headers.containsKey('Cache-Control'), isFalse);
      },
    );

    test(
      'a fresh fetch asks the server not to serve its stored answer',
      () async {
        server.handler = (_) async => const ApiOk(200, {
          'entitlement': 'v1.k.p.s',
          'bazaarChecked': true,
        });
        await remote.fetch(installKey: installKey, fresh: true);
        expect(server.requests.single.headers['Cache-Control'], 'no-cache');
      },
    );

    test('the plan title comes along when the server names it', () async {
      server.handler = (_) async => const ApiOk(200, {
        'entitlement': 'v1.k.p.s',
        'bazaarChecked': true,
        'planTitle': ' سه ماهه ',
      });
      final fetch = await remote.fetch(installKey: installKey);
      expect((fetch as FetchedEntitlement).planTitle, 'سه ماهه');

      server.handler = (_) async =>
          const ApiOk(200, {'entitlement': 'v1.k.p.s', 'planTitle': null});
      final bare = await remote.fetch(installKey: installKey);
      expect((bare as FetchedEntitlement).planTitle, isNull);
      expect(bare.bazaarChecked, isTrue);
    });

    test('no account on this phone is signed out, without a request', () async {
      await api.forget();
      expect(await remote.fetch(installKey: installKey), isA<FetchSignedOut>());
      expect(server.requests, isEmpty);
    });

    test('offline is unreachable, not trouble', () async {
      server.handler = (_) async =>
          const ApiTransportFailure(RequestTimedOut('slow'));
      expect(
        await remote.fetch(installKey: installKey),
        isA<FetchUnreachable>(),
      );
    });

    test('a server error or a broken reply is service trouble', () async {
      server.handler = (_) async => const ApiProblem(500, 'internal_error');
      expect(
        await remote.fetch(installKey: installKey),
        isA<FetchServiceTrouble>(),
      );
      server.handler = (_) async => const ApiOk(200, {'nope': 1});
      expect(
        await remote.fetch(installKey: installKey),
        isA<FetchServiceTrouble>(),
      );
      server.handler = (_) async =>
          const ApiTransportFailure(MalformedResponse('bad'));
      expect(
        await remote.fetch(installKey: installKey),
        isA<FetchServiceTrouble>(),
      );
    });

    test('a session the server ended is signed out', () async {
      server.handler = (r) async => r.path == '/auth/token/refresh'
          ? const ApiProblem(401, 'session_ended')
          : const ApiProblem(401, 'unauthorized');
      expect(await remote.fetch(installKey: installKey), isA<FetchSignedOut>());
    });
  });

  group('submitBazaarPurchase', () {
    test('sends sku, token and one idempotency key', () async {
      server.handler = (_) async =>
          const ApiOk(200, {'entitlement': 'v1.k.p.s', 'bazaarChecked': true});
      final fetch = await remote.submitBazaarPurchase(
        installKey: installKey,
        sku: 'tark_premium_1m',
        purchaseToken: 'tok',
      );
      expect(fetch, isA<FetchedEntitlement>());
      final request = server.requests.single;
      expect(request.path, '/subscription/bazaar/purchases');
      expect(request.body, {'sku': 'tark_premium_1m', 'purchaseToken': 'tok'});
      expect(request.idempotencyKey, 'key-1');
      expect(request.headers['X-Tark-Install-Key'], installKey);
    });

    test(
      'retries purchase_not_found_yet with the SAME key until verified',
      () async {
        var calls = 0;
        server.handler = (_) async {
          calls++;
          if (calls < 3) {
            return const ApiProblem(
              503,
              'purchase_not_found_yet',
              retryAfter: Duration(seconds: 10),
            );
          }
          return const ApiOk(200, {
            'entitlement': 'v1.k.p.s',
            'bazaarChecked': true,
          });
        };

        final fetch = await remote.submitBazaarPurchase(
          installKey: installKey,
          sku: 'tark_premium_12m',
          purchaseToken: 'tok',
        );

        expect(fetch, isA<FetchedEntitlement>());
        expect(server.requests, hasLength(3));
        expect(server.requests.map((r) => r.idempotencyKey).toSet(), {'key-1'});
        expect(slept, [
          const Duration(seconds: 10),
          const Duration(seconds: 10),
        ]);
      },
    );

    test('gives up after a bounded number of tries', () async {
      server.handler = (_) async =>
          const ApiProblem(503, 'purchase_not_found_yet');
      final fetch = await remote.submitBazaarPurchase(
        installKey: installKey,
        sku: 'tark_premium_1m',
        purchaseToken: 'tok',
      );
      expect(fetch, isA<FetchServiceTrouble>());
      expect(server.requests, hasLength(remote.maxAttempts));
      // No hint from the server: doubling from two seconds, capped at ten.
      expect(slept, const [
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
    });

    test('a server hint beyond the cap is clamped', () async {
      var calls = 0;
      server.handler = (_) async => ++calls == 1
          ? const ApiProblem(
              503,
              'bazaar_unavailable',
              retryAfter: Duration(seconds: 30),
            )
          : const ApiOk(200, {'entitlement': 't', 'bazaarChecked': true});
      await remote.submitBazaarPurchase(
        installKey: installKey,
        sku: 'tark_premium_1m',
        purchaseToken: 'tok',
      );
      expect(slept, const [Duration(seconds: 10)]);
    });

    test('a new purchase gets a new key', () async {
      server.handler = (_) async =>
          const ApiOk(200, {'entitlement': 't', 'bazaarChecked': true});
      for (var i = 0; i < 2; i++) {
        await remote.submitBazaarPurchase(
          installKey: installKey,
          sku: 'tark_premium_1m',
          purchaseToken: 'tok$i',
        );
      }
      expect(server.requests.map((r) => r.idempotencyKey), ['key-1', 'key-2']);
    });

    test(
      'a token owned by another account says so, without retrying',
      () async {
        server.handler = (_) async =>
            const ApiProblem(409, 'purchase_owned_elsewhere');
        final fetch = await remote.submitBazaarPurchase(
          installKey: installKey,
          sku: 'tark_premium_1m',
          purchaseToken: 'tok',
        );
        expect(fetch, isA<FetchPurchaseOwnedElsewhere>());
        expect(server.requests, hasLength(1));
        expect(slept, isEmpty);
      },
    );

    test('an invalid purchase is trouble, not a retry', () async {
      server.handler = (_) async => const ApiProblem(422, 'purchase_invalid');
      final fetch = await remote.submitBazaarPurchase(
        installKey: installKey,
        sku: 'tark_premium_1m',
        purchaseToken: 'tok',
      );
      expect(fetch, isA<FetchServiceTrouble>());
      expect(server.requests, hasLength(1));
    });
  });
}
