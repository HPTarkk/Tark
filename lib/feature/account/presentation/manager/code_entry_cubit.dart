import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/account/account_models.dart';
import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';

enum CodeEntryPhase {
  /// Reading the stored flow.
  loading,

  /// Waiting for the code (or a link).
  entering,

  /// A code or link is being checked.
  verifying,

  /// Sign-up verified and signed in, or reset verified ([ticket] set).
  done,

  /// There is no flow on this phone to finish: a link from a flow started
  /// on another phone, or one already finished. The person types the code
  /// on the phone that started it.
  noFlow,
}

class CodeEntryState extends Equatable {
  const CodeEntryState({
    this.phase = CodeEntryPhase.loading,
    this.flow,
    this.error,
    this.resendIn = Duration.zero,
    this.resent = false,
    this.resending = false,
    this.ticket,
    this.linkRejected = false,
  });

  final CodeEntryPhase phase;
  final PendingFlow? flow;
  final AuthError? error;

  /// Time left before a new code may be asked for; zero when it may.
  final Duration resendIn;

  /// A new code was just sent (for a short confirmation).
  final bool resent;
  final bool resending;

  /// Reset flows: the permission to set a new password.
  final ResetTicket? ticket;

  /// An email link opened the app but does not belong to this phone's
  /// current flow; the person should type the code instead.
  final bool linkRejected;

  /// A failure after which this flow cannot verify any more: the only way
  /// on is to start again.
  bool get flowDead => switch (error?.kind) {
    AuthErrorKind.flowExpired ||
    AuthErrorKind.flowNotFound ||
    AuthErrorKind.flowCompleted ||
    AuthErrorKind.resendLimit ||
    AuthErrorKind.emailAlreadyRegistered => true,
    _ => false,
  };

  bool get canResend =>
      phase == CodeEntryPhase.entering &&
      resendIn == Duration.zero &&
      !resending &&
      !flowDead;

  CodeEntryState copyWith({
    CodeEntryPhase? phase,
    PendingFlow? flow,
    AuthError? error,
    bool clearError = false,
    Duration? resendIn,
    bool? resent,
    bool? resending,
    ResetTicket? ticket,
    bool? linkRejected,
  }) => CodeEntryState(
    phase: phase ?? this.phase,
    flow: flow ?? this.flow,
    error: clearError ? null : (error ?? this.error),
    resendIn: resendIn ?? this.resendIn,
    resent: resent ?? this.resent,
    resending: resending ?? this.resending,
    ticket: ticket ?? this.ticket,
    linkRejected: linkRejected ?? this.linkRejected,
  );

  @override
  List<Object?> get props => [
    phase,
    flow,
    error,
    resendIn,
    resent,
    resending,
    ticket,
    linkRejected,
  ];
}

/// The 6-digit code screen, for sign-up and for password reset.
///
/// Verifies as soon as the last digit is in, or as soon as an email link
/// for the same flow opens the app. Counts down to `resendAvailableAt`
/// before offering a new code, and follows the server when it says to
/// wait longer.
class CodeEntryCubit extends Cubit<CodeEntryState> {
  CodeEntryCubit({
    required AuthRepository repository,
    required this.kind,
    DateTime Function()? clock,
  }) : _repository = repository,
       _clock = clock ?? DateTime.now,
       super(const CodeEntryState());

  final AuthRepository _repository;
  final FlowKind kind;
  final DateTime Function() _clock;
  Timer? _ticker;
  DateTime? _resendAt;

  /// No countdown longer than this, whatever a skewed clock says.
  static const _maxWait = Duration(minutes: 15);

  /// Loads the flow this phone started. With [linkToken] (the app was
  /// opened by an email link) verifies it at once.
  Future<void> load({String? linkToken}) async {
    final flow = await _repository.pendingFlow(kind);
    if (isClosed) return;
    if (flow == null) {
      emit(state.copyWith(phase: CodeEntryPhase.noFlow));
      return;
    }
    _startCountdown(flow.resendAvailableAt);
    emit(state.copyWith(phase: CodeEntryPhase.entering, flow: flow));
    if (linkToken != null) await submitLink(linkToken);
  }

  Future<void> submitCode(String raw) async {
    final code = asciiDigits(raw);
    final length = state.flow?.codeLength ?? 6;
    if (code.length != length) return;
    await _verify(code: code);
  }

  Future<void> submitLink(String token) => _verify(linkToken: token);

  Future<void> _verify({String? code, String? linkToken}) async {
    if (state.phase != CodeEntryPhase.entering) return;
    emit(
      state.copyWith(
        phase: CodeEntryPhase.verifying,
        clearError: true,
        resent: false,
        linkRejected: false,
      ),
    );
    switch (kind) {
      case FlowKind.register:
        final result = await _repository.verifyRegistration(
          code: code,
          linkToken: linkToken,
        );
        if (isClosed) return;
        switch (result) {
          case AuthSuccess():
            _stopCountdown();
            emit(state.copyWith(phase: CodeEntryPhase.done));
          case AuthFailure(:final error):
            _failed(error, byLink: linkToken != null);
        }
      case FlowKind.reset:
        final result = await _repository.verifyReset(
          code: code,
          linkToken: linkToken,
        );
        if (isClosed) return;
        switch (result) {
          case AuthSuccess(:final value):
            _stopCountdown();
            emit(state.copyWith(phase: CodeEntryPhase.done, ticket: value));
          case AuthFailure(:final error):
            _failed(error, byLink: linkToken != null);
        }
    }
  }

  void _failed(AuthError error, {required bool byLink}) {
    // A link that does not match this phone's flow (an email from an
    // earlier flow, a link sent before a resend) is not a wrong code the
    // person typed: say to type the code from the latest email instead.
    if (byLink &&
        (error.kind == AuthErrorKind.codeInvalid ||
            error.kind == AuthErrorKind.flowNotFound)) {
      emit(
        state.copyWith(
          phase: CodeEntryPhase.entering,
          clearError: true,
          linkRejected: true,
        ),
      );
      return;
    }
    emit(state.copyWith(phase: CodeEntryPhase.entering, error: error));
  }

  Future<void> resend() async {
    if (!state.canResend) return;
    emit(state.copyWith(resending: true, clearError: true, resent: false));
    final result = await _repository.resend(kind);
    if (isClosed) return;
    switch (result) {
      case AuthSuccess(:final value):
        _startCountdown(value.resendAvailableAt);
        emit(state.copyWith(flow: value, resending: false, resent: true));
      case AuthFailure(:final error):
        final wait = error.retryAfter;
        if (error.kind == AuthErrorKind.rateLimited && wait != null) {
          // The server knows better when the next send is allowed.
          _startCountdown(_clock().add(wait));
          emit(state.copyWith(resending: false));
        } else {
          emit(state.copyWith(resending: false, error: error));
        }
    }
  }

  void clearError() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }

  void _startCountdown(DateTime at) {
    _resendAt = at;
    _ticker?.cancel();
    _tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopCountdown() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _tick() {
    final at = _resendAt;
    if (at == null || isClosed) return;
    var left = at.difference(_clock());
    if (left.isNegative) left = Duration.zero;
    if (left > _maxWait) left = _maxWait;
    // Whole seconds, rounded up, so the label never shows 0:00 early.
    final seconds = (left.inMilliseconds / 1000).ceil();
    final rounded = Duration(seconds: seconds);
    if (rounded == Duration.zero) _stopCountdown();
    if (rounded != state.resendIn) emit(state.copyWith(resendIn: rounded));
  }

  @override
  Future<void> close() {
    _stopCountdown();
    return super.close();
  }
}
