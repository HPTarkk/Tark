import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/cubit/safe_emit_mixin.dart';
import '../../../../core/error/failure.dart';
import '../../domain/services/transfer_services.dart';

const _kWaitDelay = Duration(seconds: 4);

@singleton
class ConnectionCubit extends Cubit<ConnectionState> with SafeEmitMixin {
  final TransferServices _transferServices;
  ConnectionCubit(this._transferServices) : super(ConnectionStateInitial());

  StreamSubscription<bool>? _connectionSub;

  void startConnection() async {
    emit(ConnectionStateLoading());
    _connectionSub?.cancel();
    _connectionSub = _transferServices.connect().listen((data) async {
      if (data) {
        emit(ConnectionStateSuccess());
        return;
      }
      emit(ConnectionStateLoading());
      await Future.delayed(_kWaitDelay);
      if (isClosed) return;
      startConnection();
    });
  }

  Future<void> stopRecording() async {
    _transferServices.stopConnection();
    _connectionSub?.cancel();
    _connectionSub = null;
    emit(ConnectionStateInitial());
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> close() async {
    await stopRecording();
    return super.close();
  }
}

sealed class ConnectionState extends Equatable {
  const ConnectionState();

  @override
  List<Object?> get props => [];
}

final class ConnectionStateInitial extends ConnectionState {
  const ConnectionStateInitial();
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
