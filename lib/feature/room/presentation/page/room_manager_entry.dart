import 'package:flutter/material.dart';
import 'room_list_page.dart';
import 'room_create_page.dart';

/// Saved-Room management, or direct creation when Landing requests it.
class RoomManagerEntry extends StatelessWidget {
  const RoomManagerEntry({this.createOnOpen = false, super.key});

  static Widget buildPage({bool createOnOpen = false}) =>
      RoomManagerEntry(createOnOpen: createOnOpen);

  final bool createOnOpen;

  @override
  Widget build(BuildContext context) {
    // Select the destination before its first frame. Pushing creation from a
    // list's post-frame callback briefly exposed the list on every arrival.
    return createOnOpen ? RoomCreatePage.buildPage() : RoomListPage.buildPage();
  }
}
