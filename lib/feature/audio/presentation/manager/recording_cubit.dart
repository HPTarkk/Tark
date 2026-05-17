import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:wakitaki/feature/transfer/api/transfer_api.dart';

import '../../../../core/cubit/safe_emit_mixin.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../domian/entity/recorded_audio_data.dart';
import '../../domian/service/recording_services.dart';

@injectable
class RecordingCubit extends Cubit<RecordingState> with SafeEmitMixin {
  final RecordingServices _services;
  final TransferApi _transferApi;

  RecordingCubit(this._services, this._transferApi) : super(RecordingStateInitial());

  StreamSubscription<Either<Failure, RecordedAudioData>>? _sub;

  void startRecording() async {
    emit(RecordingStateLoading());
    _sub?.cancel();
    _sub = _services.startRecording().listen((data) {
      data.fold(
        (failure) {
          switch (state) {
            case RecordingStateInitial():
            case RecordingStateLoading():
            case RecordingFailureState():
              emit(RecordingFailureState(failure));
              break;
            case RecordingStateSuccess():
              Logger.log(failure);
              break;
          }
        },
        (data) {
          emit(RecordingStateSuccess(data: data));
          _transferApi.sendData(data);
        },
      );
    });
  }

  Future<void> stopRecording() async {
    await _services.stopRecording();
    _sub?.cancel();
    _sub = null;
    emit(RecordingStateInitial());
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> close() async {
    await stopRecording();
    return super.close();
  }
}

sealed class RecordingState extends Equatable {
  const RecordingState();

  @override
  List<Object?> get props => [];
}

final class RecordingStateInitial extends RecordingState {
  const RecordingStateInitial();
}

final class RecordingStateLoading extends RecordingState {
  const RecordingStateLoading();
}

final class RecordingStateSuccess extends RecordingState {
  final RecordedAudioData data;

  const RecordingStateSuccess({required this.data});

  @override
  List<Object?> get props => [data];
}

final class RecordingFailureState extends RecordingState {
  final Failure failure;
  const RecordingFailureState(this.failure);

  @override
  List<Object?> get props => [failure];
}
