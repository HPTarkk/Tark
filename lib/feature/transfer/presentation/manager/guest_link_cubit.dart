import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/analytics/analytics.dart';
import '../../../../core/analytics/analytics_event.dart';
import '../../../../core/analytics/pairing_attempt.dart';
import '../../../../core/config/guest_config.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/codec/sdp_payload.dart';
import '../../domain/entity/guest_link_state.dart';
import '../../domain/repository/guest_link_controller.dart';

/// Host side of the guest handshake: create invite → show QR → scan the
/// guest's reply → connected.
@injectable
class GuestLinkCubit extends Cubit<GuestLinkPageState> {
  final GuestLinkController _link;
  final SfxPlayer _sfx;
  final Analytics _analytics;
  late final PairingAttempt _pairing;
  StreamSubscription<GuestLinkState>? _linkSub;

  GuestLinkCubit(this._link, this._sfx, this._analytics)
    : super(GuestLinkPageState.initial()) {
    _pairing = PairingAttempt(_analytics, transport: AnalyticsTransport.guest);
    _linkSub = _link.linkState.listen((s) {
      switch (s) {
        case GuestLinkState.awaitingPeer:
          _sfx.play(SfxEvent.toggle);
        case GuestLinkState.connected:
          _sfx.play(SfxEvent.peerJoin);
          _pairing.connected();
        case GuestLinkState.failed:
          _sfx.play(SfxEvent.error);
          // An invite we never managed to publish means the guest never got
          // a chance to see us at all — closer to "discovery" than to a
          // handshake that was attempted and lost.
          _pairing.failed(
            state.inviteUrl.isEmpty ? PairStage.discover : PairStage.handshake,
            PairFailure.unknown,
          );
        default:
          break;
      }
      emit(state.copyWith(link: s));
    }, onError: (Object e) => Logger.log('Guest link state error: $e'));
    createInvite();
  }

  Future<void> createInvite() async {
    // Hosting is the only role this screen can play — the other end is a
    // browser we have no SDK in.
    _pairing.start(PairRole.host);
    emit(state.copyWith(link: GuestLinkState.preparing, inviteUrl: ''));
    try {
      final payload = await _link.createInvite();
      if (isClosed) return;
      emit(state.copyWith(inviteUrl: '$kGuestWebAppUrl#o=$payload'));
    } catch (_) {
      // linkState stream already carries the failure.
    }
  }

  Future<void> submitAnswer(String scanned) async {
    final payload = extractSdpPayload(scanned);
    if (payload == null) return;
    _analytics.track(AnalyticsEvent.featureUsed(AppFeature.qrScan));
    try {
      await _link.acceptAnswer(payload);
    } catch (_) {
      // linkState stream already carries the failure.
    }
  }

  void cancel() {
    _pairing.failed(PairStage.handshake, PairFailure.userCancelled);
    _link.endSession();
  }

  @override
  Future<void> close() async {
    // Deliberately NOT ending the session here: on success this cubit
    // closes while navigating into the walkie page, which must inherit the
    // live link. cancel() is for the explicit back-out path.
    //
    // Same reasoning for the pairing attempt: an attempt still open at close
    // is one navigating into a live session, not one that failed.
    _pairing.abandon();
    await _linkSub?.cancel();
    return super.close();
  }
}

class GuestLinkPageState extends Equatable {
  final GuestLinkState link;
  final String inviteUrl;

  const GuestLinkPageState({required this.link, required this.inviteUrl});

  factory GuestLinkPageState.initial() =>
      const GuestLinkPageState(link: GuestLinkState.idle, inviteUrl: '');

  GuestLinkPageState copyWith({GuestLinkState? link, String? inviteUrl}) =>
      GuestLinkPageState(
        link: link ?? this.link,
        inviteUrl: inviteUrl ?? this.inviteUrl,
      );

  @override
  List<Object?> get props => [link, inviteUrl];
}
