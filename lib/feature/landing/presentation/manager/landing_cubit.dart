import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/config/quick_access_config.dart';
import '../../../../core/utils/logger.dart';
import '../../../transfer/api/transfer_api.dart';

@injectable
class LandingCubit extends Cubit<LandingState> {
  final TransferModeStore _modeStore;
  Timer? _ipTimer;

  LandingCubit(this._modeStore)
      : super(LandingState.initial(_modeStore.mode)) {
    _init();
  }

  Future<void> _init() async {
    final localIp = await _getLocalIp();
    final prefs = await SharedPreferences.getInstance();
    final myName = prefs.getString('user_name') ??
        'User${localIp.split('.').last}';
    emit(state.copyWith(localIp: localIp, myName: myName, isLoading: false));

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

  Future<void> setTransferMode(TransferMode mode) async {
    await _modeStore.setMode(mode);
    emit(state.copyWith(transferMode: mode));
  }

  /// Marks onboarding complete so subsequent cold starts skip this page and
  /// resume the last channel/mode directly — see QuickAccess.
  Future<void> markLaunched() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(QuickAccessPrefs.hasLaunchedBefore, true);
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
  final TransferMode transferMode;

  const LandingState({
    required this.localIp,
    required this.myName,
    required this.isLoading,
    required this.transferMode,
  });

  factory LandingState.initial(TransferMode transferMode) => LandingState(
        localIp: '',
        myName: '',
        isLoading: true,
        transferMode: transferMode,
      );

  bool get hasNetwork =>
      transferMode == TransferMode.bluetooth ||
      // Hotspot mode creates its own network on entry, so no pre-existing IP
      // is required to start.
      transferMode == TransferMode.hotspot ||
      (localIp.isNotEmpty && localIp != '0.0.0.0');

  LandingState copyWith({
    String? localIp,
    String? myName,
    bool? isLoading,
    TransferMode? transferMode,
  }) =>
      LandingState(
        localIp: localIp ?? this.localIp,
        myName: myName ?? this.myName,
        isLoading: isLoading ?? this.isLoading,
        transferMode: transferMode ?? this.transferMode,
      );

  @override
  List<Object?> get props => [localIp, myName, isLoading, transferMode];
}
