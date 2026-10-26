import '../../../core/config/support_config.dart';

/// What a rider can say went wrong.
///
/// Deliberately short and in plain words: the person reporting has just been
/// upset, often on the side of a road, and a long taxonomy is a form to fill
/// in rather than a thing to say. Each one also drives what the report scene
/// acts out, so the choice reads back as "yes, that is what happened".
enum ReportReason { insult, threat, profile, spam, other }

/// One report, as it leaves the phone.
///
/// Tarkk has no server to send this to and records no voice, so a report is an
/// email to support written by the app and sent by the person: everything the
/// phone knows that identifies who and where, plus room for the only evidence
/// there is, which is what the reporter remembers. Nothing here is guessed or
/// fetched; every field is what the reporter's own screen showed.
final class AbuseReport {
  const AbuseReport({
    required this.reportedName,
    required this.reason,
    required this.at,
    this.roomName,
    this.reportedMemberId,
    this.appVersion,
  });

  final String reportedName;
  final ReportReason reason;
  final DateTime at;

  /// The Room's name, or null for a quick channel with no Room behind it.
  final String? roomName;

  /// The durable Room member id, which is what lets support tell two people
  /// with the same display name apart. Null outside a Room.
  final String? reportedMemberId;

  final String? appVersion;

  /// `2026-10-26 17:42` in the phone's local time: what the reporter will
  /// remember, and unambiguous without a calendar or locale to read it by.
  static String formatTime(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final local = at.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// The `mailto:` the report opens, with [subject] and [body] already
  /// localised by the caller.
  ///
  /// Encoded by hand rather than through `Uri(queryParameters:)`, which writes
  /// spaces as `+` — and mail apps put those `+` straight into the message.
  static Uri mailto({required String subject, required String body}) =>
      Uri.parse(
        'mailto:${SupportConfig.email}'
        '?subject=${Uri.encodeComponent(subject)}'
        '&body=${Uri.encodeComponent(body)}',
      );
}
