import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/account/auth_repository.dart';
import '../../../../core/account/auth_result.dart';

class AccountFormState extends Equatable {
  const AccountFormState({this.busy = false, this.error});

  final bool busy;
  final AuthError? error;

  @override
  List<Object?> get props => [busy, error];
}

/// One form, one request at a time: shows the spinner, clears the previous
/// error, and ends in either an error to show or a result for the page to
/// move on with. The simple account screens (register, forgot password,
/// reset, change password) are nothing more than this plus their fields.
class AccountFormCubit extends Cubit<AccountFormState> {
  AccountFormCubit(this.repository) : super(const AccountFormState());

  final AuthRepository repository;

  /// Runs [action] unless one is already running (a double tap), and
  /// returns its result — null when it did not run or the page went away.
  Future<AuthResult<T>?> run<T>(Future<AuthResult<T>> Function() action) async {
    if (state.busy) return null;
    emit(const AccountFormState(busy: true));
    final result = await action();
    if (isClosed) return null;
    emit(
      AccountFormState(
        error: switch (result) {
          AuthFailure(:final error) => error,
          AuthSuccess() => null,
        },
      ),
    );
    return result;
  }

  /// Shows a problem found on the phone, before any request.
  void reject(AuthErrorKind kind) =>
      emit(AccountFormState(error: AuthError(kind)));

  void clearError() {
    if (state.error != null) emit(const AccountFormState());
  }

  /// The checks every form repeats before a round trip. Returns false (and
  /// shows why) when something is plainly missing.
  bool validate({
    String? email,
    String? password,
    String? newPassword,
    String? name,
  }) {
    final required = [email, password, newPassword, name].whereType<String>();
    if (required.any((v) => v.trim().isEmpty)) {
      reject(AuthErrorKind.incomplete);
      return false;
    }
    if (email != null && !looksLikeEmail(email)) {
      reject(AuthErrorKind.emailInvalid);
      return false;
    }
    if (newPassword != null && newPassword.length < 8) {
      reject(AuthErrorKind.passwordTooShort);
      return false;
    }
    if (newPassword != null && newPassword.length > 128) {
      reject(AuthErrorKind.passwordTooLong);
      return false;
    }
    return true;
  }
}
