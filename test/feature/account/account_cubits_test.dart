import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/account/account_models.dart';
import 'package:tark/core/account/auth_result.dart';
import 'package:tark/core/network/service_api.dart';
import 'package:tark/feature/account/presentation/manager/account_form_cubit.dart';
import 'package:tark/feature/account/presentation/manager/code_entry_cubit.dart';
import 'package:tark/feature/account/presentation/manager/delete_account_cubit.dart';

import '../../core/account/account_fakes.dart';

void main() {
  group('AccountFormCubit', () {
    test('validates before any request', () {
      final h = AccountHarness();
      final cubit = AccountFormCubit(h.repository);

      expect(cubit.validate(email: '', password: 'x'), isFalse);
      expect(cubit.state.error!.kind, AuthErrorKind.incomplete);
      expect(cubit.validate(email: 'nope', password: 'x'), isFalse);
      expect(cubit.state.error!.kind, AuthErrorKind.emailInvalid);
      expect(cubit.validate(email: 'a@b.co', newPassword: 'short'), isFalse);
      expect(cubit.state.error!.kind, AuthErrorKind.passwordTooShort);
      expect(
        cubit.validate(email: 'a@b.co', newPassword: 'long enough'),
        isTrue,
      );
      expect(h.client.requests, isEmpty);
    });

    test('shows busy, then the error, and ignores a double tap', () async {
      final h = AccountHarness();
      h.client.handler = (_) async =>
          const ApiProblem(401, 'invalid_credentials');
      final cubit = AccountFormCubit(h.repository);
      final states = <AccountFormState>[];
      cubit.stream.listen(states.add);

      final first = cubit.run(
        () => h.repository.login(email: 'a@b.co', password: 'x'),
      );
      final second = await cubit.run(
        () => h.repository.login(email: 'a@b.co', password: 'x'),
      );
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(second, isNull);
      expect(h.client.requests, hasLength(1));
      expect(states.first.busy, isTrue);
      expect(states.last.busy, isFalse);
      expect(states.last.error!.kind, AuthErrorKind.invalidCredentials);
    });
  });

  group('CodeEntryCubit', () {
    Future<AccountHarness> withFlow({int resendAt = 0}) async {
      final h = AccountHarness();
      await h.store.writeFlow(
        PendingFlow.fromResponse(
          FlowKind.register,
          'a@b.co',
          flowJson(resendAt: resendAt),
        )!,
      );
      return h;
    }

    test('without a flow on this phone says so', () async {
      final h = AccountHarness();
      final cubit = CodeEntryCubit(
        repository: h.repository,
        kind: FlowKind.register,
      );
      await cubit.load(linkToken: 'tok');
      expect(cubit.state.phase, CodeEntryPhase.noFlow);
      expect(h.client.requests, isEmpty);
      await cubit.close();
    });

    test('verifies once all six digits are in (Persian digits too)', () async {
      final h = await withFlow();
      h.client.handler = (_) async => ApiOk(200, sessionJson());
      final cubit = CodeEntryCubit(
        repository: h.repository,
        kind: FlowKind.register,
      );
      await cubit.load();

      await cubit.submitCode('۱۲۳');
      expect(h.client.requests, isEmpty);
      await cubit.submitCode('۱۲۳۴۵۶');

      expect(h.client.requests.single.body!['code'], '123456');
      expect(cubit.state.phase, CodeEntryPhase.done);
      expect(h.session.isSignedIn, isTrue);
      await cubit.close();
    });

    test('a link opening the app verifies at once', () async {
      final h = await withFlow();
      h.client.handler = (_) async => ApiOk(200, sessionJson());
      final cubit = CodeEntryCubit(
        repository: h.repository,
        kind: FlowKind.register,
      );
      await cubit.load(linkToken: 'tok');
      expect(h.client.requests.single.body!['linkToken'], 'tok');
      expect(cubit.state.phase, CodeEntryPhase.done);
      await cubit.close();
    });

    test('a link from another flow asks for the code instead', () async {
      final h = await withFlow();
      h.client.handler = (_) async => const ApiProblem(422, 'code_invalid');
      final cubit = CodeEntryCubit(
        repository: h.repository,
        kind: FlowKind.register,
      );
      await cubit.load(linkToken: 'old');
      expect(cubit.state.phase, CodeEntryPhase.entering);
      expect(cubit.state.linkRejected, isTrue);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('a wrong code shows attempts left; an expired flow ends it', () async {
      final h = await withFlow();
      h.client.handler = (_) async =>
          const ApiProblem(422, 'code_invalid', fields: {'attemptsLeft': 4});
      final cubit = CodeEntryCubit(
        repository: h.repository,
        kind: FlowKind.register,
      );
      await cubit.load();
      await cubit.submitCode('000000');
      expect(cubit.state.error!.attemptsLeft, 4);
      expect(cubit.state.flowDead, isFalse);

      h.client.handler = (_) async => const ApiProblem(410, 'flow_expired');
      await cubit.submitCode('111111');
      expect(cubit.state.flowDead, isTrue);
      expect(cubit.state.canResend, isFalse);
      await cubit.close();
    });

    test('reset flows end with the ticket', () async {
      final h = AccountHarness();
      await h.store.writeFlow(
        PendingFlow.fromResponse(FlowKind.reset, 'a@b.co', flowJson())!,
      );
      h.client.handler = (_) async =>
          const ApiOk(200, {'resetTicket': 'ticket', 'expiresAt': farFuture});
      final cubit = CodeEntryCubit(
        repository: h.repository,
        kind: FlowKind.reset,
      );
      await cubit.load();
      await cubit.submitCode('123456');
      expect(cubit.state.phase, CodeEntryPhase.done);
      expect(cubit.state.ticket!.value, 'ticket');
      await cubit.close();
    });

    test('counts down to resendAvailableAt, then resends', () {
      fakeAsync((async) {
        final start = DateTime.utc(2026, 9, 29, 12);
        DateTime now() => start.add(async.elapsed);
        final h = AccountHarness();
        h.store.writeFlow(
          PendingFlow.fromResponse(
            FlowKind.register,
            'a@b.co',
            flowJson(
              resendAt: start
                  .add(const Duration(seconds: 60))
                  .millisecondsSinceEpoch,
            ),
          )!,
        );
        async.flushMicrotasks();
        final cubit = CodeEntryCubit(
          repository: h.repository,
          kind: FlowKind.register,
          clock: now,
        );
        cubit.load();
        async.flushMicrotasks();

        expect(cubit.state.resendIn, const Duration(seconds: 60));
        expect(cubit.state.canResend, isFalse);
        cubit.resend();
        async.flushMicrotasks();
        expect(h.client.requests, isEmpty);

        async.elapse(const Duration(seconds: 59));
        expect(cubit.state.resendIn, const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));
        expect(cubit.state.resendIn, Duration.zero);
        expect(cubit.state.canResend, isTrue);

        h.client.handler = (_) async => ApiOk(
          202,
          flowJson(
            resendAt: now()
                .add(const Duration(seconds: 60))
                .millisecondsSinceEpoch,
          ),
        );
        cubit.resend();
        async.flushMicrotasks();
        expect(h.client.requests.single.path, '/auth/register/resend');
        expect(cubit.state.resent, isTrue);
        expect(cubit.state.resendIn, const Duration(seconds: 60));
        cubit.close();
        async.flushMicrotasks();
      });
    });

    test('a too-early resend follows the server wait', () {
      fakeAsync((async) {
        final start = DateTime.utc(2026, 9, 29, 12);
        DateTime now() => start.add(async.elapsed);
        final h = AccountHarness();
        h.store.writeFlow(
          PendingFlow.fromResponse(FlowKind.register, 'a@b.co', flowJson())!,
        );
        h.client.handler = (_) async => const ApiProblem(
          429,
          'rate_limited',
          retryAfter: Duration(seconds: 30),
        );
        final cubit = CodeEntryCubit(
          repository: h.repository,
          kind: FlowKind.register,
          clock: now,
        );
        cubit.load();
        async.flushMicrotasks();
        cubit.resend();
        async.flushMicrotasks();
        expect(cubit.state.error, isNull);
        expect(cubit.state.resendIn, const Duration(seconds: 30));
        cubit.close();
        async.flushMicrotasks();
      });
    });
  });

  group('DeleteAccountCubit', () {
    test('asks for the subscription acknowledgement, then deletes', () async {
      final h = AccountHarness();
      await h.signIn();
      h.client.handler = (r) async =>
          r.body!['subscriptionAcknowledged'] == true
          ? const ApiOk(204, {})
          : const ApiProblem(
              409,
              'subscription_active',
              fields: {'autoRenewing': false},
            );
      final cubit = DeleteAccountCubit(h.repository);

      await cubit.submit(confirmEmail: 'pedi@example.com', password: 'pw');
      expect(cubit.state.subscriptionRunning, isTrue);
      expect(cubit.state.autoRenewing, isFalse);
      expect(cubit.state.error, isNull);

      // Not acknowledged yet: nothing is sent.
      await cubit.submit(confirmEmail: 'pedi@example.com', password: 'pw');
      expect(h.client.requests, hasLength(1));

      cubit.setAcknowledged(true);
      await cubit.submit(confirmEmail: 'pedi@example.com', password: 'pw');
      expect(cubit.state.deleted, isTrue);
      expect(h.session.isSignedIn, isFalse);
      await cubit.close();
    });

    test('empty fields are caught on the phone', () async {
      final h = AccountHarness();
      final cubit = DeleteAccountCubit(h.repository);
      await cubit.submit(confirmEmail: '', password: 'pw');
      expect(cubit.state.error!.kind, AuthErrorKind.incomplete);
      await cubit.submit(confirmEmail: 'a@b.co', password: '');
      expect(cubit.state.error!.kind, AuthErrorKind.incomplete);
      expect(h.client.requests, isEmpty);
      await cubit.close();
    });

    test('a wrong email is shown, not thrown', () async {
      final h = AccountHarness();
      await h.signIn();
      h.client.handler = (_) async =>
          const ApiProblem(422, 'confirmation_mismatch');
      final cubit = DeleteAccountCubit(h.repository);
      await cubit.submit(confirmEmail: 'x@y.co', password: 'pw');
      expect(cubit.state.error!.kind, AuthErrorKind.confirmationMismatch);
      expect(cubit.state.deleted, isFalse);
      await cubit.close();
    });
  });
}
