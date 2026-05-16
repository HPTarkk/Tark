import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wakitaki/core/cubit/safe_emit_mixin.dart';
import 'package:wakitaki/core/error/failure.dart';

class ConnectionCubit extends Cubit<ConnectionState> with SafeEmitMixin {
  ConnectionCubit() : super(ConnectionStateLoading());

  
}

sealed class ConnectionState extends Equatable {
  const ConnectionState();

  @override
  List<Object?> get props => [];
}

final class ConnectionStateLoading extends ConnectionState {
  const ConnectionStateLoading();
}

final class ConnectionStateSuccess extends ConnectionState {
  const ConnectionStateSuccess();
}

final class ConnectionStateFailure extends ConnectionState {
  final Failure failure;
  const ConnectionStateFailure(this.failure);

  @override
  List<Object?> get props => [failure];
}
