import 'dart:async';

import 'package:app_links/app_links.dart';

import '../utils/logger.dart';
import 'account_config.dart';
import 'account_models.dart';

/// A verification link from one of the account emails:
/// `https://tarkk.ir/v/<register|reset|email>#<linkToken>`.
class EmailLink {
  const EmailLink({required this.segment, required this.token});

  /// `register`, `reset` or `email`.
  final String segment;

  /// The part after `#`. Never logged.
  final String token;

  /// The flow this link finishes, or null for one the app does not run
  /// (email change).
  FlowKind? get kind {
    for (final k in FlowKind.values) {
      if (k.linkSegment == segment) return k;
    }
    return null;
  }

  /// The link in [uri], or null when [uri] is anything else (a home-widget
  /// launch, another page of the site).
  static EmailLink? parse(Uri uri) {
    if (uri.scheme != 'https') return null;
    if (uri.host.toLowerCase() != AccountConfig.linkHost) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != 'v') return null;
    final segment = segments[1];
    if (!const {'register', 'reset', 'email'}.contains(segment)) return null;
    final token = uri.fragment.trim();
    if (token.isEmpty || token.length > 512) return null;
    return EmailLink(segment: segment, token: token);
  }
}

/// Email links opening the app, from a cold start or while it runs.
abstract interface class EmailLinkSource {
  /// Every link, the one that launched the app included.
  Stream<EmailLink> get links;
}

/// [EmailLinkSource] over app_links (Android App Links, verified for
/// tarkk.ir/v/ — see the intent-filter in AndroidManifest.xml). Its stream
/// also carries the link that launched the app.
class AppLinksEmailLinkSource implements EmailLinkSource {
  AppLinksEmailLinkSource([AppLinks? appLinks])
    : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  @override
  Stream<EmailLink> get links => _appLinks.uriLinkStream
      .map(EmailLink.parse)
      .where((link) => link != null)
      .cast<EmailLink>()
      .handleError((Object error) {
        Logger.log('Account: link stream error (${error.runtimeType})');
      });
}

/// Hands each incoming email link to whoever can finish its flow.
///
/// A code-entry screen that is open registers itself as the handler for its
/// flow and gets the link directly. Otherwise [unclaimed] fires and the app
/// opens a code-entry screen for it.
class EmailLinkDispatcher {
  final _handlers = <FlowKind, bool Function(EmailLink)>{};
  final _unclaimed = StreamController<EmailLink>.broadcast();

  Stream<EmailLink> get unclaimed => _unclaimed.stream;

  /// Registers [handler] for [kind] until the returned callback is called.
  void Function() claim(FlowKind kind, bool Function(EmailLink) handler) {
    _handlers[kind] = handler;
    return () {
      if (identical(_handlers[kind], handler)) _handlers.remove(kind);
    };
  }

  void dispatch(EmailLink link) {
    final kind = link.kind;
    final handler = kind == null ? null : _handlers[kind];
    if (handler != null && handler(link)) return;
    if (!_unclaimed.isClosed) _unclaimed.add(link);
  }
}
