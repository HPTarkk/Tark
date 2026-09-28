/// Public surface of the update feature.
///
/// Only the app composition root needs anything from here: [UpdateGate] goes
/// around the whole app in `MaterialApp.builder`.
library;

export '../presentation/widget/update_gate.dart' show UpdateGate;
