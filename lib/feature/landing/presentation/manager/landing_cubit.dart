import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/utils/logger.dart';

class LandingCubit extends Cubit<LandingState> {
  Timer? _ipTimer;

  LandingCubit() : super(LandingState.initial()) {
    _init();
  }

  Future<void> _init() async {
    final localIp = await _getLocalIp();
    final prefs = await SharedPreferences.getInstance();
    final myName = prefs.getString('user_name') ??
        'User${localIp.split('.').last}';
    emit(LandingState(localIp: localIp, myName: myName, isLoading: false));

    _ipTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      final newIp = await _getLocalIp();
      if (!isClosed && newIp != state.localIp) {
        emit(state.copyWith(localIp: newIp));
      }
    });
  }

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', trimmed);
    emit(state.copyWith(myName: trimmed));
  }

  @override
  Future<void> close() async {
    _ipTimer?.cancel();
    return super.close();
  }

  Future<String> _getLocalIp() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      Logger.log('Could not get local IP: $e');
    }
    return '0.0.0.0';
  }
}

class LandingState extends Equatable {
  final String localIp;
  final String myName;
  final bool isLoading;

  const LandingState({
    required this.localIp,
    required this.myName,
    required this.isLoading,
  });

  factory LandingState.initial() => const LandingState(
        localIp: '',
        myName: '',
        isLoading: true,
      );

  bool get hasNetwork => localIp.isNotEmpty && localIp != '0.0.0.0';

  LandingState copyWith({
    String? localIp,
    String? myName,
    bool? isLoading,
  }) =>
      LandingState(
        localIp: localIp ?? this.localIp,
        myName: myName ?? this.myName,
        isLoading: isLoading ?? this.isLoading,
      );

  @override
  List<Object?> get props => [localIp, myName, isLoading];
}
