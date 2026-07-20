import 'transfer_repository.dart';

/// The Wi-Fi/UDP transport specifically — as opposed to [TransferRepository],
/// which DI resolves to whichever transport the current mode selects.
/// Consumers that must talk to the Wi-Fi transport regardless of mode (the
/// hotspot bridge waiting for the first packet from the joined peer) depend
/// on this instead of the concrete implementation.
abstract interface class WifiTransferRepository implements TransferRepository {}
