/// Per-session Bluetooth connection role. Not persisted — a user is host or
/// joiner for the current session only, unlike [TransferMode] which is a
/// standing preference.
enum BluetoothRole { host, joiner }
