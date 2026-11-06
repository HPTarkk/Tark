import 'package:flutter/services.dart';

import '../../../core/utils/logger.dart';

/// Where the rating page actually opened.
enum ReviewOutcome {
  /// Bazaar's own rate-and-review page is up.
  bazaar,

  /// No Bazaar app: Tarkk's listing opened in a browser instead.
  web,

  /// Nothing could open it.
  none,
}

/// Opens Cafe Bazaar's rating page for Tarkk. Backed by `StoreHandler` on
/// Android, which fires Bazaar's documented "comment" intent (ACTION_EDIT on
/// `bazaar://details?id=…`) and falls back to the web listing.
class BazaarReviewLauncher {
  const BazaarReviewLauncher();

  static const _channel = MethodChannel('tark/store');

  /// Tarkk's listing id on Bazaar. Fixed rather than read from the package
  /// name, so a `.dev` build still rates the real app.
  static const listingId = 'com.b1101.tark';

  /// The web listing: the fallback without the Bazaar app, and what the
  /// "copy link" chip hands over when even a browser would not open.
  static final webListing = Uri.parse('https://cafebazaar.ir/app/$listingId');

  Future<ReviewOutcome> open() async {
    try {
      final answer = await _channel.invokeMethod<String>('openReview', {
        'id': listingId,
        'url': webListing.toString(),
      });
      return switch (answer) {
        'bazaar' => ReviewOutcome.bazaar,
        'web' => ReviewOutcome.web,
        _ => ReviewOutcome.none,
      };
    } catch (e) {
      Logger.log('Rating: could not open Bazaar — $e');
      return ReviewOutcome.none;
    }
  }
}
