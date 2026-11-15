import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/widget/icon_pop_switcher.dart';
import '../../domain/service/room_topic_matcher.dart';

/// How each [RoomTopic] is drawn: one rounded Material icon, in the same
/// family as every other glyph in the app.
extension RoomTopicIcon on RoomTopic {
  IconData get icon => switch (this) {
    RoomTopic.emergency => Icons.emergency_rounded,
    RoomTopic.firefighters => Icons.local_fire_department_rounded,
    RoomTopic.police => Icons.local_police_rounded,
    RoomTopic.medical => Icons.local_hospital_rounded,
    RoomTopic.military => Icons.military_tech_rounded,
    RoomTopic.mourning => Icons.local_florist_rounded,
    RoomTopic.religion => Icons.mosque_rounded,
    RoomTopic.church => Icons.church_rounded,
    RoomTopic.synagogue => Icons.synagogue_rounded,
    RoomTopic.wedding => Icons.diamond_rounded,
    RoomTopic.birthday => Icons.cake_rounded,
    RoomTopic.baby => Icons.child_care_rounded,
    RoomTopic.americanFootball => Icons.sports_football_rounded,
    RoomTopic.football => Icons.sports_soccer_rounded,
    RoomTopic.basketball => Icons.sports_basketball_rounded,
    RoomTopic.volleyball => Icons.sports_volleyball_rounded,
    RoomTopic.tennis => Icons.sports_tennis_rounded,
    RoomTopic.baseball => Icons.sports_baseball_rounded,
    RoomTopic.cricket => Icons.sports_cricket_rounded,
    RoomTopic.handball => Icons.sports_handball_rounded,
    RoomTopic.hockey => Icons.sports_hockey_rounded,
    RoomTopic.golf => Icons.sports_golf_rounded,
    RoomTopic.boxing => Icons.sports_mma_rounded,
    RoomTopic.martialArts => Icons.sports_martial_arts_rounded,
    RoomTopic.gym => Icons.fitness_center_rounded,
    RoomTopic.yoga => Icons.self_improvement_rounded,
    RoomTopic.running => Icons.directions_run_rounded,
    RoomTopic.walking => Icons.directions_walk_rounded,
    RoomTopic.swimming => Icons.pool_rounded,
    RoomTopic.diving => Icons.scuba_diving_rounded,
    RoomTopic.surfing => Icons.surfing_rounded,
    RoomTopic.kayaking => Icons.kayaking_rounded,
    RoomTopic.sailing => Icons.sailing_rounded,
    // Material's "phishing" glyph is a fishing hook.
    RoomTopic.fishing => Icons.phishing_rounded,
    RoomTopic.paragliding => Icons.paragliding_rounded,
    RoomTopic.snowboarding => Icons.snowboarding_rounded,
    RoomTopic.skiing => Icons.downhill_skiing_rounded,
    RoomTopic.skateboarding => Icons.skateboarding_rounded,
    RoomTopic.skating => Icons.ice_skating_rounded,
    RoomTopic.animals => Icons.pets_rounded,
    RoomTopic.hiking => Icons.hiking_rounded,
    RoomTopic.camping => Icons.forest_rounded,
    RoomTopic.picnic => Icons.park_rounded,
    RoomTopic.beach => Icons.beach_access_rounded,
    RoomTopic.desert => Icons.wb_sunny_rounded,
    RoomTopic.delivery => Icons.local_shipping_rounded,
    RoomTopic.cycling => Icons.directions_bike_rounded,
    RoomTopic.motorcycle => Icons.two_wheeler_rounded,
    RoomTopic.racing => Icons.sports_motorsports_rounded,
    RoomTopic.offroad => Icons.terrain_rounded,
    RoomTopic.car => Icons.directions_car_rounded,
    RoomTopic.taxi => Icons.local_taxi_rounded,
    RoomTopic.bus => Icons.directions_bus_rounded,
    RoomTopic.train => Icons.train_rounded,
    RoomTopic.metro => Icons.subway_rounded,
    RoomTopic.flight => Icons.flight_rounded,
    RoomTopic.tour => Icons.tour_rounded,
    RoomTopic.hotel => Icons.hotel_rounded,
    RoomTopic.travel => Icons.luggage_rounded,
    RoomTopic.boardGames => Icons.casino_rounded,
    RoomTopic.theater => Icons.theater_comedy_rounded,
    RoomTopic.gaming => Icons.sports_esports_rounded,
    RoomTopic.tournament => Icons.emoji_events_rounded,
    RoomTopic.sports => Icons.sports_rounded,
    RoomTopic.music => Icons.music_note_rounded,
    RoomTopic.photography => Icons.photo_camera_rounded,
    RoomTopic.movies => Icons.movie_rounded,
    RoomTopic.books => Icons.auto_stories_rounded,
    RoomTopic.study => Icons.edit_note_rounded,
    RoomTopic.university => Icons.account_balance_rounded,
    RoomTopic.school => Icons.school_rounded,
    RoomTopic.coding => Icons.code_rounded,
    RoomTopic.science => Icons.science_rounded,
    RoomTopic.work => Icons.work_rounded,
    RoomTopic.business => Icons.storefront_rounded,
    RoomTopic.shopping => Icons.shopping_bag_rounded,
    RoomTopic.construction => Icons.construction_rounded,
    RoomTopic.art => Icons.palette_rounded,
    RoomTopic.factory => Icons.factory_rounded,
    RoomTopic.farm => Icons.agriculture_rounded,
    RoomTopic.garden => Icons.yard_rounded,
    RoomTopic.bbq => Icons.outdoor_grill_rounded,
    RoomTopic.pizza => Icons.local_pizza_rounded,
    RoomTopic.cafe => Icons.local_cafe_rounded,
    RoomTopic.food => Icons.restaurant_rounded,
    RoomTopic.nightlife => Icons.nightlife_rounded,
    RoomTopic.party => Icons.celebration_rounded,
    RoomTopic.event => Icons.event_rounded,
    RoomTopic.charity => Icons.volunteer_activism_rounded,
    RoomTopic.pets => Icons.pets_rounded,
    RoomTopic.family => Icons.family_restroom_rounded,
    RoomTopic.love => Icons.favorite_rounded,
    RoomTopic.home => Icons.home_rounded,
    RoomTopic.neighbors => Icons.apartment_rounded,
    RoomTopic.radio => Icons.settings_input_antenna_rounded,
    RoomTopic.echo => Icons.graphic_eq_rounded,
    RoomTopic.storm => Icons.thunderstorm_rounded,
    RoomTopic.lightning => Icons.bolt_rounded,
    RoomTopic.snow => Icons.ac_unit_rounded,
    RoomTopic.fire => Icons.whatshot_rounded,
    RoomTopic.wind => Icons.air_rounded,
    RoomTopic.sunset => Icons.wb_twilight_rounded,
    RoomTopic.stars => Icons.auto_awesome_rounded,
    RoomTopic.space => Icons.rocket_launch_rounded,
    RoomTopic.night => Icons.bedtime_rounded,
    RoomTopic.sky => Icons.cloud_rounded,
    RoomTopic.road => Icons.add_road_rounded,
    RoomTopic.friends => Icons.groups_rounded,
  };
}

/// The icon for a Room called [name], or null when the name says nothing
/// and the Room keeps its letter.
IconData? roomIconFor(String name) => RoomTopicMatcher.match(name)?.icon;

/// What a Room shows when its name says nothing: the channel mark the
/// create page has always used.
const IconData roomFallbackIcon = Icons.cell_tower_rounded;

/// A Room's topic icon, drawn small beside its name.
///
/// When the name changes (a rename, or typing on the create page) the old
/// icon sinks away and the new one springs up with a small twist, so the
/// change reads as the app recognising the name rather than as a redraw.
/// A name with no topic draws [fallback], or folds the glyph's space away
/// when there is none. Under reduced motion the icon simply swaps.
class RoomTopicGlyph extends StatelessWidget {
  const RoomTopicGlyph({
    required this.name,
    required this.color,
    this.size = 18,
    this.gap = 0,
    this.fallback,
    super.key,
  });

  final String name;
  final Color color;
  final double size;

  /// Space after the icon, folded away with it when there is no icon.
  final double gap;

  /// Drawn when [name] has no topic. Null folds the glyph away instead.
  final IconData? fallback;

  @override
  Widget build(BuildContext context) {
    final icon = roomIconFor(name) ?? fallback;
    final reduced = AppMotion.reduced(context);
    final glyph = IconPopSwitcher(
      icon: icon,
      reduced: reduced,
      child: icon == null
          ? const SizedBox.shrink()
          : Padding(
              padding: EdgeInsetsDirectional.only(end: gap),
              child: Icon(icon, size: size, color: color),
            ),
    );
    // Only a glyph that can fold away needs its width animated. Reduced
    // motion skips it outright: a zero-length AnimatedSize re-dirties itself
    // mid-layout.
    final folds = fallback == null && !reduced;
    return ExcludeSemantics(
      child: folds
          ? AnimatedSize(
              duration: AppMotion.card,
              curve: AppMotion.easeOut,
              alignment: AlignmentDirectional.centerStart,
              child: glyph,
            )
          : glyph,
    );
  }
}
