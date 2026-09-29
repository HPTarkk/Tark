import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/account/account_models.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/account/auth_result.dart';
import 'package:tark/core/account/google_id_token_source.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/network/service_api.dart';

import 'account_fakes.dart';

void main() {
  late AccountHarness h;

  setUp(() => h = AccountHarness());

  AuthError errorOf(AuthResult<Object?> result) =>
      (result as AuthFailure).error;

  group('sign-up', () {
    test('register keeps the flow and sends one idempotent start', () async {
      h.client.handler = (_) async => ApiOk(202, flowJson());

      final result = await h.repository.register(
        email: '  Pedi@Example.COM ',
        password: 'long enough',
        name: ' Pedi ',
      );

      expect(result, isA<AuthSuccess<PendingFlow>>());
      final request = h.client.requests.single;
      expect(request.path, '/auth/register');
      expect(request.body, {
        'email': 'pedi@example.com',
        'password': 'long enough',
        'name': 'Pedi',
        'locale': 'fa',
      });
      expect(request.idempotencyKey, isNotNull);
      final stored = await h.store.readFlow(FlowKind.register);
      expect(stored!.flowId, 'flow-1');
      expect(stored.email, 'pedi@example.com');
    });

    test('a retry after a lost answer reuses the idempotency key', () async {
      h.client.handler = (_) async =>
          const ApiTransportFailure(NetworkUnreachable('lost'));
      final first = await h.repository.register(
        email: 'a@b.co',
        password: 'long enough',
        name: 'A',
      );
      expect(errorOf(first).kind, AuthErrorKind.offline);

      h.client.handler = (_) async => ApiOk(202, flowJson());
      await h.repository.register(
        email: 'a@b.co',
        password: 'long enough',
        name: 'A',
      );
      final keys = h.client.requests.map((r) => r.idempotencyKey).toList();
      expect(keys[0], keys[1]);

      // A different request is a different write.
      await h.repository.register(
        email: 'c@d.co',
        password: 'long enough',
        name: 'A',
      );
      expect(h.client.requests.last.idempotencyKey, isNot(keys[0]));
    });

    test('verify sends the stored flowId with the code and signs in', () async {
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async => ApiOk(200, sessionJson());

      final result = await h.repository.verifyRegistration(code: '123456');

      expect(result, isA<AuthSuccess<AccountProfile>>());
      expect(h.client.requests.single.body, {
        'flowId': 'flow-1',
        'code': '123456',
      });
      expect(h.session.isSignedIn, isTrue);
      expect(await h.api.hasSession(), isTrue);
      expect(await h.store.readFlow(FlowKind.register), isNull);
    });

    test('verify by link sends the link token instead of a code', () async {
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async => ApiOk(200, sessionJson());
      await h.repository.verifyRegistration(linkToken: 'tok');
      expect(h.client.requests.single.body, {
        'flowId': 'flow-1',
        'linkToken': 'tok',
      });
    });

    test('without a flow on this phone nothing is sent', () async {
      final result = await h.repository.verifyRegistration(linkToken: 'tok');
      expect(errorOf(result).kind, AuthErrorKind.flowNotFound);
      expect(h.client.requests, isEmpty);
    });

    test('a wrong code keeps the flow and reports attempts left', () async {
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async =>
          const ApiProblem(422, 'code_invalid', fields: {'attemptsLeft': 2});
      final result = await h.repository.verifyRegistration(code: '000000');
      expect(errorOf(result).kind, AuthErrorKind.codeInvalid);
      expect(errorOf(result).attemptsLeft, 2);
      expect(await h.store.readFlow(FlowKind.register), isNotNull);
    });

    test('an expired flow is forgotten', () async {
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async => const ApiProblem(410, 'flow_expired');
      await h.repository.verifyRegistration(code: '000000');
      expect(await h.store.readFlow(FlowKind.register), isNull);
    });

    test('resend replaces the stored flow times', () async {
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async => ApiOk(202, flowJson(resendAt: 99000));
      final result = await h.repository.resend(FlowKind.register);
      expect(result, isA<AuthSuccess<PendingFlow>>());
      expect(h.client.requests.single.path, '/auth/register/resend');
      expect(h.client.requests.single.body, {'flowId': 'flow-1'});
      final stored = await h.store.readFlow(FlowKind.register);
      expect(stored!.resendAvailableAt.millisecondsSinceEpoch, 99000);
    });
  });

  group('password reset', () {
    test('forgot → verify → reset signs in', () async {
      h.client.handler = (r) async => switch (r.path) {
        '/auth/password/forgot' => ApiOk(202, flowJson(flowId: 'reset-1')),
        '/auth/password/forgot/verify' => const ApiOk(200, {
          'resetTicket': 'ticket-1',
          'expiresAt': farFuture,
        }),
        '/auth/password/reset' => ApiOk(200, sessionJson()),
        _ => const ApiProblem(404, 'not_found'),
      };

      await h.repository.forgotPassword('a@b.co');
      final verified = await h.repository.verifyReset(code: '654321');
      final ticket = (verified as AuthSuccess<ResetTicket>).value;
      final reset = await h.repository.resetPassword(
        ticket: ticket,
        newPassword: 'another long one',
      );

      expect(reset, isA<AuthSuccess<AccountProfile>>());
      expect(h.client.requests[1].body, {
        'flowId': 'reset-1',
        'code': '654321',
      });
      expect(h.client.requests[2].body, {
        'resetTicket': 'ticket-1',
        'newPassword': 'another long one',
      });
      expect(h.session.isSignedIn, isTrue);
      expect(await h.store.readFlow(FlowKind.reset), isNull);
    });
  });

  group('sign-in', () {
    test('every login failure reads as invalid credentials', () async {
      h.client.handler = (_) async =>
          const ApiProblem(401, 'invalid_credentials');
      final result = await h.repository.login(
        email: 'a@b.co',
        password: 'nope',
      );
      expect(errorOf(result).kind, AuthErrorKind.invalidCredentials);
      expect(h.session.isSignedIn, isFalse);
    });

    test('login success stores tokens and profile', () async {
      h.client.handler = (_) async => ApiOk(200, sessionJson());
      final result = await h.repository.login(
        email: 'a@b.co',
        password: 'right',
      );
      expect(
        (result as AuthSuccess<AccountProfile>).value.email,
        'pedi@example.com',
      );
      expect((await h.store.readProfile())!.email, 'pedi@example.com');
    });

    test('Google: nonce first, then the ID token carrying it', () async {
      h.client.handler = (r) async => switch (r.path) {
        '/auth/google/nonce' => const ApiOk(200, {
          'nonce': 'n-1',
          'expiresAt': farFuture,
        }),
        '/auth/google' => ApiOk(200, sessionJson()),
        _ => const ApiProblem(404, 'not_found'),
      };

      final result = await h.repository.signInWithGoogle();

      expect(result, isA<AuthSuccess<AccountProfile>>());
      expect(h.google.nonces, ['n-1']);
      expect(h.client.paths, ['/auth/google/nonce', '/auth/google']);
      expect(h.client.requests[1].body, {
        'idToken': 'google-id-token-for-n-1',
        'name': 'Pedi',
        'locale': 'fa',
      });
    });

    test('Google link-required carries the ticket and masked email', () async {
      h.client.handler = (r) async => switch (r.path) {
        '/auth/google/nonce' => const ApiOk(200, {
          'nonce': 'n',
          'expiresAt': farFuture,
        }),
        _ => const ApiProblem(
          409,
          'link_required',
          fields: {'ticket': 't-1', 'email': 'pe•••@gmail.com'},
        ),
      };
      final result = await h.repository.signInWithGoogle();
      final error = errorOf(result);
      expect(error.kind, AuthErrorKind.linkRequired);
      expect(error.ticket, 't-1');
      expect(error.maskedEmail, 'pe•••@gmail.com');

      h.client.handler = (_) async => ApiOk(200, sessionJson());
      final linked = await h.repository.linkGoogle(
        ticket: 't-1',
        password: 'pw',
      );
      expect(linked, isA<AuthSuccess<AccountProfile>>());
      expect(h.client.requests.last.path, '/auth/google/link');
      expect(h.client.requests.last.body, {
        'ticket': 't-1',
        'password': 'pw',
        'locale': 'fa',
      });
    });

    test('Google picker closed is not an error to show', () async {
      h.google.result = const GoogleCancelled();
      h.client.handler = (_) async =>
          const ApiOk(200, {'nonce': 'n', 'expiresAt': farFuture});
      final result = await h.repository.signInWithGoogle();
      expect(errorOf(result).kind, AuthErrorKind.googleCancelled);
      expect(h.client.paths, ['/auth/google/nonce']);
    });

    test('Google without a configured client sends nothing', () async {
      h.google.available = false;
      final result = await h.repository.signInWithGoogle();
      expect(errorOf(result).kind, AuthErrorKind.googleUnavailable);
      expect(h.client.requests, isEmpty);
    });
  });

  group('account', () {
    setUp(() => h.signIn());

    test('change password needs the session', () async {
      h.client.handler = (_) async => const ApiOk(204, {});
      final result = await h.repository.changePassword(
        currentPassword: 'old one',
        newPassword: 'new one!!',
      );
      expect(result, isA<AuthSuccess<void>>());
      expect(
        h.client.requests.single.headers['Authorization'],
        'Bearer access-1',
      );
    });

    test('delete asks for acknowledgement while a subscription runs', () async {
      h.client.handler = (_) async => const ApiProblem(
        409,
        'subscription_active',
        fields: {'autoRenewing': true},
      );
      final result = await h.repository.deleteAccount(
        confirmEmail: 'pedi@example.com',
        password: 'pw',
      );
      expect(errorOf(result).kind, AuthErrorKind.subscriptionActive);
      expect(errorOf(result).autoRenewing, isTrue);
      expect(h.client.requests.single.body, {
        'confirmEmail': 'pedi@example.com',
        'currentPassword': 'pw',
        'subscriptionAcknowledged': false,
        'locale': 'fa',
      });
      expect(h.session.isSignedIn, isTrue);
    });

    test('delete success ends the session here', () async {
      var signedOut = 0;
      h.session.signedOut.listen((_) => signedOut++);
      h.client.handler = (_) async => const ApiOk(204, {});
      final result = await h.repository.deleteAccount(
        confirmEmail: 'pedi@example.com',
        password: 'pw',
        subscriptionAcknowledged: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(result, isA<AuthSuccess<void>>());
      expect(h.session.isSignedIn, isFalse);
      expect(await h.api.hasSession(), isFalse);
      expect(await h.store.readProfile(), isNull);
      expect(signedOut, 1);
    });

    test('delete for a Google-only account re-signs in with Google', () async {
      h.client.handler = (r) async => r.path == '/auth/google/nonce'
          ? const ApiOk(200, {'nonce': 'n-9', 'expiresAt': farFuture})
          : const ApiOk(204, {});
      await h.repository.deleteAccount(
        confirmEmail: 'pedi@example.com',
        withGoogle: true,
      );
      final body = h.client.requests.last.body!;
      expect(body['googleIdToken'], 'google-id-token-for-n-9');
      expect(body.containsKey('currentPassword'), isFalse);
    });
  });

  test('Persian digits are typed codes too', () {
    expect(asciiDigits('۱۲۳٤٥6'), '123456');
    expect(asciiDigits('12 34-56'), '123456');
  });

  test('email shape check', () {
    expect(looksLikeEmail('a@b.co'), isTrue);
    expect(looksLikeEmail(' a@b.co '), isTrue);
    expect(looksLikeEmail('a@b'), isFalse);
    expect(looksLikeEmail('a b@c.d'), isFalse);
  });
}
