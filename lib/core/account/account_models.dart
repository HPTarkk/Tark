import 'package:equatable/equatable.dart';

/// The signed-in account's profile, as the server last described it.
/// Matches `Profile` in backend/api/openapi.yaml; unknown fields are ignored.
class AccountProfile extends Equatable {
  const AccountProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.signInMethods,
    this.avatarId,
  });

  final String id;
  final String name;

  /// Read-only on this side: it changes only through the email-change flow,
  /// which the app does not offer yet.
  final String email;

  /// The server's avatar id: one of the app's predefined avatars, written as
  /// the decimal of the local integer id (see [localAvatarId]).
  final String? avatarId;

  /// `password` and/or `google`.
  final Set<String> signInMethods;

  bool get hasPassword => signInMethods.contains('password');
  bool get hasGoogle => signInMethods.contains('google');

  /// The local integer avatar id this profile names, or null.
  int? get localAvatarId {
    final raw = avatarId;
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  static AccountProfile? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final name = json['name'];
    final email = json['email'];
    final avatar = json['avatarId'];
    final methods = json['signInMethods'];
    if (id is! String || email is! String) return null;
    return AccountProfile(
      id: id,
      name: name is String ? name : '',
      email: email,
      avatarId: avatar is String ? avatar : null,
      signInMethods: {
        if (methods is List)
          for (final m in methods)
            if (m is String) m,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'avatarId': avatarId,
    'signInMethods': signInMethods.toList(),
  };

  AccountProfile copyWith({String? name, String? avatarId}) => AccountProfile(
    id: id,
    name: name ?? this.name,
    email: email,
    avatarId: avatarId ?? this.avatarId,
    signInMethods: signInMethods,
  );

  @override
  List<Object?> get props => [id, name, email, avatarId, signInMethods];
}

/// The email flows the app runs. Email change exists on the server but is
/// not offered by the app yet.
enum FlowKind {
  register('register'),
  reset('reset');

  const FlowKind(this.linkSegment);

  /// The path segment in the email link: `https://tarkk.ir/v/<segment>#…`.
  final String linkSegment;
}

/// A started flow: the secret handle the code or link is verified with,
/// plus the times the screens count down to.
class PendingFlow extends Equatable {
  const PendingFlow({
    required this.kind,
    required this.flowId,
    required this.email,
    required this.expiresAt,
    required this.resendAvailableAt,
    this.codeLength = 6,
  });

  final FlowKind kind;
  final String flowId;

  /// What the person typed, to remind them where the code went.
  final String email;
  final DateTime expiresAt;
  final DateTime resendAvailableAt;
  final int codeLength;

  /// Reads the `FlowStarted` answer.
  static PendingFlow? fromResponse(
    FlowKind kind,
    String email,
    Map<String, dynamic> json,
  ) {
    final flowId = json['flowId'];
    final expires = json['expiresAt'];
    final resend = json['resendAvailableAt'];
    if (flowId is! String || flowId.isEmpty) return null;
    if (expires is! num || resend is! num) return null;
    final code = json['code'];
    final length = code is Map ? code['length'] : null;
    return PendingFlow(
      kind: kind,
      flowId: flowId,
      email: email,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expires.toInt(),
        isUtc: true,
      ),
      resendAvailableAt: DateTime.fromMillisecondsSinceEpoch(
        resend.toInt(),
        isUtc: true,
      ),
      codeLength: length is int && length > 0 && length <= 12 ? length : 6,
    );
  }

  static PendingFlow? fromStored(Map<String, dynamic> json) {
    final kind = FlowKind.values.where((k) => k.name == json['kind']);
    final email = json['email'];
    if (kind.isEmpty || email is! String) return null;
    return fromResponse(kind.first, email, json);
  }

  Map<String, Object?> toStored() => {
    'kind': kind.name,
    'flowId': flowId,
    'email': email,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'resendAvailableAt': resendAvailableAt.millisecondsSinceEpoch,
    'code': {'length': codeLength},
  };

  @override
  List<Object?> get props => [
    kind,
    flowId,
    email,
    expiresAt,
    resendAvailableAt,
  ];
}

/// The one-time permission to set a new password, from a verified reset.
class ResetTicket {
  const ResetTicket(this.value, this.expiresAt);

  final String value;
  final DateTime expiresAt;
}
