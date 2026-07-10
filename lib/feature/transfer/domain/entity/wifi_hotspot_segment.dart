/// Item 9: WiFi and Hotspot merge into one page with a segmented choice —
/// "already on the same Wi-Fi, nothing to set up" vs "set up a hotspot"
/// (Android hosts, iOS scans/joins — a Local-Only-Hotspot can't be hosted
/// from iOS, so the segment doesn't offer a host/join choice of its own,
/// the platform still decides that part).
enum WifiHotspotSegment { wifi, hotspot }
