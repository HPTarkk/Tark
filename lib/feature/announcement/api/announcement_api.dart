/// Public surface of the announcements feature.
///
/// Only the app composition root needs anything from here:
/// [AnnouncementGate] goes inside the update gate in `MaterialApp.builder`.
library;

export '../presentation/widget/announcement_gate.dart' show AnnouncementGate;
