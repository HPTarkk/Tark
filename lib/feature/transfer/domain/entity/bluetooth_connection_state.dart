enum BluetoothConnectionState {
  disconnected,
  hosting,
  scanning,
  connecting,
  connected,

  /// An established session dropped and the repository is trying to bring
  /// it back by itself (host re-advertises, joiner re-dials the last peer).
  reconnecting,
  error,
}
