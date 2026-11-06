/// Public surface of the Rating feature: rating Tarkk on Cafe Bazaar, from
/// Settings or, now and then, after a good ride.
library;

export '../domain/rating_prompt.dart' show RatingPrompt, RideCompanyClock;
export '../presentation/widget/rate_app_card.dart' show RateAppCard;
export '../presentation/widget/rating_story_sheet.dart'
    show maybeAskForRating, showRatingStory;
