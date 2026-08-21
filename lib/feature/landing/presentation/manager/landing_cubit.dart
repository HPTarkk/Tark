import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/identity/channel_membership.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/utils/fallback_display_name.dart';
import '../../../../core/utils/local_network.dart';
import '../../../transfer/api/transfer_api.dart';

@injectable
class LandingCubit extends Cubit<LandingState> {
  final TransferModeStore _modeStore;
  final SettingsRepository _settingsRepository;
  final ChannelMembership _membership;
  Timer? _ipTimer;
  StreamSubscription<TransferMode>? _modeSub;
  StreamSubscription<TransferMode?>? _pinSub;
  StreamSubscription<String>? _nameSub;

  LandingCubit(this._modeStore, this._settingsRepository, this._membership)
    : super(LandingState.initial(_modeStore.mode, _modeStore.pinnedMode)) {
    // Landing stays alive under Settings on the nav stack, so pick up mode
    // changes made there — the join button routes by state.transferMode.
    _modeSub = _modeStore.modeChanges.listen(
      (mode) => emit(state.copyWith(transferMode: mode)),
    );
    // The pin is watched separately because un-pinning back to automatic
    // deliberately leaves the effective mode alone (see [TransferModeStore]),
    // so it emits on this stream and on no other — and the page would
    // otherwise go on advertising a pin the user has just removed.
    _pinSub = _modeStore.pinChanges.listen((pin) => emit(state.withPin(pin)));
    // Same for the display name, which Settings (and a live walkie session)
    // edit through SettingsRepository — the identity card shows state.myName.
    _nameSub = _settingsRepository.myNameChanges.listen(
      (name) => emit(state.copyWith(myName: name)),
    );
    _init();
  }

  Future<void> _init() async {
    final localIp = await _getLocalIp();
    final storedName = await _settingsRepository.getMyName();
    final myName = storedName.isEmpty
        ? localizedFallbackDisplayName(
            await _settingsRepository.getLocaleCode(),
            localIp,
          )
        : storedName;
    emit(state.copyWith(localIp: localIp, myName: myName, isLoading: false));

    _ipTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      final newIp = await _getLocalIp();
      if (!isClosed && newIp != state.localIp) {
        emit(state.copyWith(localIp: newIp));
      }
    });
  }

  /// Takes the channel the tapped intent implies.
  ///
  /// Starting one names a channel; joining one deliberately does **not**, and
  /// leaves us open. A joiner who has not scanned a code has said nothing about
  /// which conversation they are in, and inventing a channel for them would be
  /// worse than useless — it would exclude them from every group on the
  /// network, including the one they meant to join. Any channel they are owed
  /// arrives from the code they scan; until then, open is the honest state.
  ///
  /// Leaving on join is what makes the two buttons reversible: tapping join
  /// after a create must not leave the phone filtering against its own
  /// abandoned channel.
  void takeChannel(ChannelIntent intent) => switch (intent) {
    ChannelIntent.create => _membership.createIfNone(),
    ChannelIntent.join => _membership.leave(),
  };

  /// Commits to the transport the advisor picked, on the way into a channel.
  ///
  /// Under automatic this is the only moment a transport is decided at all,
  /// and it has to be written rather than merely acted on: the DI factory
  /// picks a repository from the stored mode at cold start, and quick access
  /// resumes from it. Pinned plans still come through here and simply rewrite
  /// the value they already hold.
  Future<void> commit(TransferMode mode) => _modeStore.setMode(mode);

  /// Marks onboarding complete so subsequent cold starts skip this page and
  /// resume the last channel/mode directly — see QuickAccess.
  Future<void> markLaunched() =>
      _settingsRepository.setHasLaunchedBefore(true);

  @override
  Future<void> close() async {
    _ipTimer?.cancel();
    await _modeSub?.cancel();
    await _pinSub?.cancel();
    await _nameSub?.cancel();
    return super.close();
  }

  Future<String> _getLocalIp() async => await LocalNetwork.ipv4Address() ?? '0.0.0.0';
}

class LandingState extends Equatable {
  final String localIp;
  final String myName;
  final bool isLoading;
  final TransferMode transferMode;

  /// The transport pinned by hand in Advanced settings, or null for automatic
  /// — which is what almost every install runs, and what makes the two channel
  /// actions mean anything.
  final TransferMode? pinnedMode;

  const LandingState({
    required this.localIp,
    required this.myName,
    required this.isLoading,
    required this.transferMode,
    required this.pinnedMode,
  });

  factory LandingState.initial(
    TransferMode transferMode,
    TransferMode? pinnedMode,
  ) => LandingState(
    localIp: '',
    myName: '',
    isLoading: true,
    transferMode: transferMode,
    pinnedMode: pinnedMode,
  );

  /// A usable local address, which is the one fact both channel actions turn on.
  ///
  /// Distinct from the old `hasNetwork`, which folded in "…or the selected
  /// mode makes its own network" and so could not be handed to the advisor:
  /// the advisor's whole job is to decide *whether* to make a network, and an
  /// input that has already assumed the answer tells it nothing.
  bool get hasWifiAddress => localIp.isNotEmpty && localIp != '0.0.0.0';

  /// What the advisor is allowed to reason from. Platform capability is read
  /// here rather than injected: it cannot change while the app runs, and
  /// threading a constant through DI would buy a seam nothing needs.
  LinkConditions get conditions => LinkConditions(
    hasWifi: hasWifiAddress,
    // Only Android can raise a local-only access point.
    canHostHotspot: Platform.isAndroid,
    // Both phone platforms can be told to associate with a scanned network.
    canJoinHotspot: Platform.isAndroid || Platform.isIOS,
    // Android runs Classic RFCOMM + BLE, iOS runs BLE; desktop and web have
    // no Bluetooth transport at all (see BluetoothConnectPage).
    bluetoothSupported: Platform.isAndroid || Platform.isIOS,
    pinned: pinnedMode,
  );

  ChannelPlan planFor(ChannelIntent intent) =>
      TransportAdvisor.plan(intent, conditions);

  LandingState copyWith({
    String? localIp,
    String? myName,
    bool? isLoading,
    TransferMode? transferMode,
  }) => LandingState(
    localIp: localIp ?? this.localIp,
    myName: myName ?? this.myName,
    isLoading: isLoading ?? this.isLoading,
    transferMode: transferMode ?? this.transferMode,
    pinnedMode: pinnedMode,
  );

  /// Separate from [copyWith] because null is a meaningful value here —
  /// "automatic" — and the `?? this.x` idiom cannot express it.
  LandingState withPin(TransferMode? pin) => LandingState(
    localIp: localIp,
    myName: myName,
    isLoading: isLoading,
    transferMode: transferMode,
    pinnedMode: pin,
  );

  @override
  List<Object?> get props => [
    localIp,
    myName,
    isLoading,
    transferMode,
    pinnedMode,
  ];
}
