import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';

class DeleteAccountState extends Equatable {
  const DeleteAccountState({
    this.busy = false,
    this.error,
    this.subscriptionRunning = false,
    this.autoRenewing,
    this.acknowledged = false,
    this.deleted = false,
  });

  final bool busy;
  final AuthError? error;

  /// The server said a paid Bazaar period is still running: the person
  /// must read what that means and tick [acknowledged] before deleting.
  final bool subscriptionRunning;
  final bool? autoRenewing;
  final bool acknowledged;
  final bool deleted;

  DeleteAccountState copyWith({
    bool? busy,
    AuthError? error,
    bool clearError = false,
    bool? subscriptionRunning,
    bool? autoRenewing,
    bool? acknowledged,
    bool? deleted,
  }) => DeleteAccountState(
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
    subscriptionRunning: subscriptionRunning ?? this.subscriptionRunning,
    autoRenewing: autoRenewing ?? this.autoRenewing,
    acknowledged: acknowledged ?? this.acknowledged,
    deleted: deleted ?? this.deleted,
  );

  @override
  List<Object?> get props => [
    busy,
    error,
    subscriptionRunning,
    autoRenewing,
    acknowledged,
    deleted,
  ];
}

/// Deleting the account: the typed email, fresh proof (password or a new
/// Google sign-in), and — only when the server says a paid period is
/// running — the person's acknowledgement that deleting does not cancel
/// the Bazaar subscription.
class DeleteAccountCubit extends Cubit<DeleteAccountState> {
  DeleteAccountCubit(this._repository) : super(const DeleteAccountState());

  final AuthRepository _repository;

  void setAcknowledged(bool value) =>
      emit(state.copyWith(acknowledged: value, clearError: true));

  Future<void> submit({
    required String confirmEmail,
    String? password,
    bool withGoogle = false,
  }) async {
    if (state.busy) return;
    if (confirmEmail.trim().isEmpty ||
        (!withGoogle && (password == null || password.isEmpty))) {
      emit(state.copyWith(error: const AuthError(AuthErrorKind.incomplete)));
      return;
    }
    if (state.subscriptionRunning && !state.acknowledged) return;
    emit(state.copyWith(busy: true, clearError: true));
    final result = await _repository.deleteAccount(
      confirmEmail: confirmEmail,
      password: withGoogle ? null : password,
      withGoogle: withGoogle,
      subscriptionAcknowledged: state.acknowledged,
    );
    if (isClosed) return;
    switch (result) {
      case AuthSuccess():
        emit(state.copyWith(busy: false, deleted: true));
      case AuthFailure(:final error)
          when error.kind == AuthErrorKind.subscriptionActive:
        emit(
          state.copyWith(
            busy: false,
            subscriptionRunning: true,
            autoRenewing: error.autoRenewing,
          ),
        );
      case AuthFailure(:final error):
        emit(state.copyWith(busy: false, error: error));
    }
  }
}
