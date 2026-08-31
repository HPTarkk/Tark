import 'package:flutter/material.dart';
import 'room_list_page.dart';

/// Production entry for durable Room management.
///
/// Landing owns Create and Join; this route owns saved-Room management only.
class RoomManagerEntry extends StatelessWidget {
  const RoomManagerEntry({this.createOnOpen = false, super.key});

  static Widget buildPage({bool createOnOpen = false}) =>
      RoomManagerEntry(createOnOpen: createOnOpen);

  final bool createOnOpen;

  @override
  Widget build(BuildContext context) {
    // One screen, one purpose: manage saved Rooms.  The landing screen owns
    // the two entry actions (create / scan), so this page must not duplicate
    // either of them as a second, competing CTA.
    return RoomListPage.buildPage(createOnOpen: createOnOpen);
  }
}
