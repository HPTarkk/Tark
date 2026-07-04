# audio_io

A Flutter plugin for cross-platform real-time audio streaming. Provides low-latency audio input/output with simple Stream-based API for audio processing, recording, and visualization.

## Features

- Real-time audio streaming from microphone to Flutter
- Audio output/playback through speakers
- Cross-platform support (iOS, macOS, Android, Web, Linux, Windows)
- Simple Stream-based API
- Configurable audio latency modes
- Consistent data format across all platforms (Float64, 48kHz, mono)
- Low-latency audio processing
- Volume level monitoring

## Platform Support

| Platform | Status | Implementation |
|----------|--------|---------------|
| iOS      | ✅ Supported | Native (AVAudioEngine) |
| macOS    | ✅ Supported | Native (AVAudioEngine) |
| Android  | ✅ Supported | FFI (miniaudio) |
| Web      | ✅ Supported | Web Audio API |
| Linux    | ✅ Supported | FFI (miniaudio) |
| Windows  | ✅ Supported | FFI (miniaudio) |

## Getting Started

### Installation

Add `audio_io` to your `pubspec.yaml`:

```yaml
dependencies:
  audio_io: ^0.3.2
```

### iOS Setup

Add microphone usage description to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for audio processing.</string>
```

### macOS Setup

1. Add microphone usage description to your `macos/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for audio processing.</string>
```

2. Enable audio input in your entitlements files:
   - `macos/Runner/DebugProfile.entitlements`
   - `macos/Runner/Release.entitlements`

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### Android Setup

Add microphone permission to your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

### Permissions

This plugin requires microphone permission to function. **Permission handling is the responsibility of your app** - the plugin does not request permissions automatically.

Use a package like [permission_handler](https://pub.dev/packages/permission_handler) to request microphone permission before calling `start()`:

```dart
import 'package:permission_handler/permission_handler.dart';

// Request permission before starting audio
final status = await Permission.microphone.request();
if (status.isGranted) {
  await AudioIo.instance.start();
} else {
  // Handle permission denied
}
```

If you call `start()` without microphone permission, an `AudioIoException` will be thrown with a clear error message.

### Usage

```dart
import 'package:audio_io/audio_io.dart';

// Get the audio instance
final audioIo = AudioIo.instance;

// Configure latency (optional)
await audioIo.requestLatency(AudioIoLatency.Balanced);

// Start audio processing
await audioIo.start();

// Listen to input audio stream
audioIo.input.listen((audioData) {
  // Process audio data (List<double>)
  print('Received ${audioData.length} samples');
  
  // Calculate volume level (RMS)
  final sum = audioData.fold<double>(
    0.0, (sum, sample) => sum + sample * sample);
  final rms = sqrt(sum / audioData.length);
});

// Send audio to output (echo example)
audioIo.input.listen((data) {
  audioIo.output.add(data);
});

// Stop audio processing
await audioIo.stop();
```

### Error Handling

The plugin throws `AudioIoException` for errors. Use `isPermissionDenied` to check for permission issues:

```dart
try {
  await AudioIo.instance.start();
} on AudioIoException catch (e) {
  if (e.isPermissionDenied) {
    // Microphone permission not granted
    print('Please grant microphone permission');
  } else {
    // Other audio errors (session, engine)
    print('Audio error: ${e.message}');
  }
}
```

### Latency Configuration

The plugin supports three latency modes:

```dart
enum AudioIoLatency {
  Realtime,  // Lowest latency (~1.5ms buffer)
  Balanced,  // Balanced latency/CPU (~3ms buffer)
  Powersave, // Lower CPU usage (~6ms buffer)
}

// Set before starting audio
await audioIo.requestLatency(AudioIoLatency.Realtime);
```

## Audio Format

All platforms use a consistent audio format:

- **Sample Rate**: 48kHz (may adapt to device capabilities)
- **Channels**: Mono (1 channel)
- **Data Type**: Double precision floats (Float64/double)
- **Stream Format**: Chunks of audio samples as `List<double>`
- **Internal Processing**: Platform-specific (Float32 on native platforms)

## Requirements

- Dart SDK: >=3.0.0 <4.0.0
- Flutter: >=3.10.0
- iOS: 12.0 or higher
- macOS: 10.15 or higher

## License

See LICENSE file for details.