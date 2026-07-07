import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/config/guest_config.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/utils/logger.dart';
import '../../data/webrtc/sdp_codec.dart';
import '../../domain/entity/guest_link_state.dart';
import '../../domain/repository/guest_link_controller.dart';

/// Host side of the guest handshake: create invite → show QR → scan the
/// guest's reply → connected.
@injectable
class GuestLinkCubit extends Cubit<GuestLinkPageState> {
  final GuestLinkController _link;
  StreamSubscription<GuestLinkState>? _linkSub;

  GuestLinkCubit(this._link) : super(GuestLinkPageState.initial()) {
    _linkSub = _link.linkState.listen(
      (s) {
        switch (s) {
          case GuestLinkState.awaitingPeer:
            Sfx.play(SfxEvent.toggle);
          case GuestLinkState.connected:
            Sfx.play(SfxEvent.peerJoin);
          case GuestLinkState.failed:
            Sfx.play(SfxEvent.error);
          default:
            break;
        }
        emit(state.copyWith(link: s));
      },
      onError: (Object e) => Logger.log('Guest link state error: $e'),
    );
    createInvite();
  }

  Future<void> createInvite() async {
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
    try {
      await _link.acceptAnswer(payload);
    } catch (_) {
      // linkState stream already carries the failure.
    }
  }

  void cancel() => _link.endSession();

  @override
  Future<void> close() async {
    // Deliberately NOT ending the session here: on success this cubit
    // closes while navigating into the walkie page, which must inherit the
    // live link. cancel() is for the explicit back-out path.
    await _linkSub?.cancel();
    return super.close();
  }
}

class GuestLinkPageState extends Equatable {
  final GuestLinkState link;
  final String inviteUrl;

  const GuestLinkPageState({required this.link, required this.inviteUrl});

  factory GuestLinkPageState.initial() => const GuestLinkPageState(
        link: GuestLinkState.idle,
        inviteUrl: '',
      );

  GuestLinkPageState copyWith({GuestLinkState? link, String? inviteUrl}) =>
      GuestLinkPageState(
        link: link ?? this.link,
        inviteUrl: inviteUrl ?? this.inviteUrl,
      );

  @override
  List<Object?> get props => [link, inviteUrl];
}
