## 0.0.1
Kiss release
Input from mic at fixed sample rate and buffer size, no output

## 0.0.2
Kiss MVP release

Input from mic at fixed sample rate and buffer size, output fixed at mono at the same sample rate as input.
Simple quick and dirty ringbuffer for output (needs optimisation)

## 0.0.3
Bugfix
Fix 32-64bit mismatch of data.

## 0.0.4
Improvement
Allow muliple listeners on audio input

## 0.0.5
Bugfix
Thread safety - memory leak fixed :)

## 0.0.6
Improvement
Main thread call for sink removed (attempt to reduce latency introduced in 0.0.5)

## 0.0.7
Rollback 0.0.6

## 0.0.8
Improvement
Handle audio session changes
Reset audio when entering foreground

## 0.0.9
Improvement
Handle audio interruptions
Using simpler binary message system to send data (2x cpu optimisation)
Replaced invoking method with binary message for output audio
Less format conversions when sending data in and out
Prep work for upcoming buffer and samplerate selection features

## 0.1.0
New Interface
Added inteface for getting format and buffer size selection (audio frame size)
Using serial queue for read and writes to buffer

## 0.1.1
Performance
Fixing Dart side audio format to double (everything is 64bit these days, 64bit is great for processing)
Optimised data conversion 

## 0.1.2
Bugfix
Fix bug which stopped audio when coming back from background

## 0.1.3
Bugfix
Fixed issue with route swapping from speaker to headphones

## 0.1.4
Bugfix
Better way to detect changes in audio format, removed old methods

## 0.1.5
Bugfix
Using detected input sample rate rather than fixed sample rate

## 0.1.6
Cleanup
Added null safety 

## 0.1.7
Performance improvement

## 0.1.8
Fix dangling pointer

## 0.1.9
Small performance improvement
Remove fonts from example
Bump SDK version

## 0.2.0
Major Update
- Added macOS platform support with full audio input/output capabilities
- Updated minimum SDK requirements: Dart >=3.4.0, Flutter >=3.22.0
- Fixed ring buffer infinite recursion bug in macOS implementation
- Added proper entitlements configuration for macOS microphone access
- Updated documentation with platform-specific setup instructions
- Improved cross-platform compatibility

## 0.3.0
Multi-Platform Release
- Added Android platform support using miniaudio C++ library via FFI
- Added Web platform support using Web Audio API
- Added Linux platform support using miniaudio via FFI
- Added Windows platform support using miniaudio via FFI
- Implemented configurable audio latency (Realtime/Balanced/Powersave modes)
- Added real-time volume meter visualization in example app
- Standardized data format across all platforms (Float64, 48kHz, mono)
- Fixed microphone permissions handling on Android
- Improved FFI implementation with proper memory management
- Added comprehensive .gitignore for C/C++ build artifacts
- Fixed all analyzer warnings and improved code quality
- Updated minimum SDK requirements: Dart >=3.0.0, Flutter >=3.10.0

Platform Support:
- iOS ✅ (Native Swift/AVAudioEngine)
- macOS ✅ (Native Swift/AVAudioEngine)  
- Android ✅ (FFI/miniaudio)
- Web ✅ (Web Audio API)
- Linux ✅ (FFI/miniaudio)
- Windows ✅ (FFI/miniaudio)

## 0.3.2
Bug Fix
- Fixed compile error in resetAudio() caused by start() signature change

## 0.3.1
Performance, Stability & Error Handling Update

Permission Handling:
- Added graceful error handling when microphone permission is not granted (iOS/macOS)
- Plugin now throws AudioIoException with clear message instead of crashing
- Added AudioIoException class with isPermissionDenied helper for easy error handling
- Permission errors clearly state that permission handling is the app's responsibility

Threading Fix:
- Fixed critical threading crash on macOS where platform channel messages were sent from audio thread
- Binary messages now dispatched to main thread before sending to Flutter (iOS/macOS)

API Additions:
- Added AudioIoException class for typed error handling
- AudioIoException.isPermissionDenied getter for checking permission errors
- AudioIoException includes code, message, and optional details

Critical Memory Leak Fixes:
- Implemented buffer pool for Data objects to eliminate real-time allocations in audio callbacks (iOS/macOS)
- Fixed catastrophic memory leak from DispatchQueue.main.async accumulation in audio callbacks (iOS/macOS)
- Fixed memory accumulation from queue.async in output message handler by switching to sync (iOS/macOS)
- Added autoreleasepool to audio callbacks and message handlers to ensure immediate memory release (iOS/macOS)
- Fixed retain cycle in plugin instance preventing deallocation (iOS/macOS)
- Fixed retain cycles in audio node callbacks by using weak self references (iOS/macOS)
- Fixed NotificationCenter observer leak by adding proper deinit cleanup (iOS/macOS)
- Fixed ByteData reference chain leak by copying audio data instead of creating views
- Fixed ring buffer index overflow that would cause eventual corruption
- Fixed StreamController memory leak in Dart output sink fallback
- Added proper cleanup of binary message handlers on stop
- Added buffer.clear() on stop to release memory immediately
- Optimized audio buffer conversion to reduce allocations per frame
- Made stream controllers synchronous to prevent event queue buildup
- Optimized Dart input processing to skip allocations when no listener present
- Eliminated Data array allocation in output handler by writing directly from buffer (iOS/macOS)

Performance Improvements:
- Optimized audio pipeline to use Float64 throughout iOS/macOS, eliminating unnecessary Float32→Float64 conversions
- Removed unnecessary thread dispatch from audio callbacks, eliminating unbounded queue growth
- Removed expensive DateTime operations from per-frame Dart message handler
- Reduced CPU overhead by eliminating Float32→Float64 conversion in audio processing
- Optimized buffer sizes based on latency mode (256-4096 samples)
- Improved thread synchronization for audio callbacks
- Optimized Dart output stream to avoid unnecessary Float64List allocations
- Eliminated per-frame List allocations in example app audio processing
- Minimized per-frame allocations in Dart message handler for better throughput

Bug Fixes:
- Fixed critical pipeline setup bug in iOS/macOS (_isPipelineSetup flag now properly set)
- Fixed audio format mismatch crash on iOS/macOS (AVAudioEngine Float32 compatibility)
- Fixed latency change handling on miniaudio platforms (now properly restarts with new buffer)
- Fixed Web platform getFrameDuration calculation before audio start
- Fixed example app pubspec.yaml formatting issues
- Added missing flutter_lints dependency to example app

Platform Improvements:
- Added clipping protection for miniaudio platforms (Linux/Windows/Android) to prevent audio distortion
- Implemented dynamic latency switching without restart on all platforms
- Fixed Web platform buffer size configuration based on latency settings
- Improved ring buffer size management with minimum size guarantee

Code Quality:
- Fixed analyzer warnings and applied dart fix recommendations
- Removed debug print statements from production code
- Disabled latency dropdown in example app when audio is running

Diagnostics:
- Added ring buffer overflow detection with logging (iOS/macOS)