/// Where people reach a human. The subscription screens show this exactly
/// when the phone may be offline, so it has to be available without a
/// network — the built-in address is the floor, never a placeholder.
abstract final class SupportConfig {
  /// Same address the website's legal pages publish.
  static const email = 'tarkk.hp@gmail.com';

  static Uri mailto({String? subject}) => Uri(
    scheme: 'mailto',
    path: email,
    query: subject == null ? null : 'subject=${Uri.encodeComponent(subject)}',
  );
}
