import 'dart:async';

import '../../domain/service/room_invite_join_orchestrator.dart';

/// UI-owned offline carrier for the secure Room invite request/response flow.
///
/// [exchange] exposes the already-correlated encoded request as a QR payload and
/// waits until the user scans the issuer's encoded response. This class never
/// parses or authorizes Room membership; [RoomInviteJoinOrchestrator] remains
/// the only consumer of the response and performs request/Room/member
/// correlation before a grant can be imported.
final class RoomQrJoinCarrier implements RoomInviteJoinCarrier {
  final StreamController<String> _requests = StreamController<String>.broadcast(
    sync: true,
  );

  Completer<String>? _response;
  bool _disposed = false;

  Stream<String> get requests => _requests.stream;

  bool get awaitingResponse => _response != null;

  @override
  Future<String> exchange(String encodedRequest) {
    if (_disposed) {
      throw StateError('RoomQrJoinCarrier is disposed');
    }
    if (_response != null) {
      throw StateError('RoomQrJoinCarrier already has an active exchange');
    }
    final response = Completer<String>();
    _response = response;
    _requests.add(encodedRequest);
    return response.future.whenComplete(() {
      if (identical(_response, response)) _response = null;
    });
  }

  /// Completes the current exchange with the scanned issuer response.
  ///
  /// Returns false when there is no live request, so duplicate scanner frames
  /// cannot accidentally complete a later attempt.
  bool submitResponse(String encodedResponse) {
    final response = _response;
    if (_disposed || response == null || response.isCompleted) return false;
    response.complete(encodedResponse);
    return true;
  }

  void cancel([Object? reason]) {
    final response = _response;
    if (response == null || response.isCompleted) return;
    response.completeError(reason ?? StateError('Room QR join cancelled'));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cancel(StateError('RoomQrJoinCarrier disposed'));
    await _requests.close();
  }
}
