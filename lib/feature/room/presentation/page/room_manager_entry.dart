import 'package:flutter/material.dart';
import 'room_list_page.dart';
import 'room_create_page.dart';

/// Saved-Room management, or direct creation when Landing requests it.
class RoomManagerEntry extends StatelessWidget {
  const RoomManagerEntry({
    this.createOnOpen = false,
    this.initialName,
    this.continuous = false,
    super.key,
  });

  /// [initialName] prefills the new Room's name and [continuous] says the
  /// creation screen continues the screen beneath it (onboarding's last
  /// step). Both only matter with [createOnOpen]; see
  /// [RoomCreatePage.buildPage].
  static Widget buildPage({
    bool createOnOpen = false,
    String? initialName,
    bool continuous = false,
  }) => RoomManagerEntry(
    createOnOpen: createOnOpen,
    initialName: initialName,
    continuous: continuous,
  );

  final bool createOnOpen;
  final String? initialName;
  final bool continuous;

  @override
  Widget build(BuildContext context) {
    // Select the destination before its first frame. Pushing creation from a
    // list's post-frame callback briefly exposed the list on every arrival.
    return createOnOpen
        ? RoomCreatePage.buildPage(
            initialName: initialName,
            continuous: continuous,
          )
        : RoomListPage.buildPage();
  }
}
