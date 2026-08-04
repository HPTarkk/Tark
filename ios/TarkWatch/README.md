# Tark Watch — watchOS target source

This directory contains the watchOS SwiftUI companion UI and WatchConnectivity
client. Add a **watchOS App for Existing iOS App** target in Xcode with bundle ID
`com.b1101.tark.watchkitapp`, then add the three Swift files and this Info.plist
to that target.

The iPhone side is already implemented in `Runner/AppDelegate.swift`. Both
sides use `WCSession`; the watch requests the latest room state every two
seconds while visible and sends `toggle_mute`, `reconnect`, and `leave` actions.

The phone remains the audio and network endpoint. No voice samples are copied
to the watch.
