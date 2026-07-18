#
# rnnoise: RNNoise (Xiph.Org) vendored as a source pod, exposed to Dart via FFI.
#
# NOT YET BUILT OR TESTED — written on a Windows machine with no Xcode
# toolchain available. Build and verify on macOS before shipping the iOS side.
#
Pod::Spec.new do |s|
  s.name             = 'rnnoise'
  s.version          = '0.1.0'
  s.summary          = 'RNNoise real-time speech denoiser, FFI-bound.'
  s.description      = <<-DESC
Vendored RNNoise (BSD, Xiph.Org) C sources built as part of the Flutter iOS
pod and called from Dart via dart:ffi.
                       DESC
  s.homepage         = 'https://gitlab.xiph.org/xiph/rnnoise'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Xiph.Org Foundation' => 'https://xiph.org' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*', '../src/**/*.{c,h}', '../include/**/*.h'
  s.public_header_files = '../include/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'VALID_ARCHS[sdk=iphonesimulator*]' => 'x86_64 arm64',
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/../src $(PODS_TARGET_SRCROOT)/../include',
    # This is built as a dynamic framework (use_frameworks! in the app's
    # Podfile). Xcode/clang default new frameworks to hidden symbol
    # visibility, which would make rnnoise_create/process_frame/destroy
    # invisible to dart:ffi's DynamicLibrary.process() lookup even after a
    # clean build — force them visible instead of relying on the project's
    # default. RNNOISE_BUILD makes rnnoise.h's own RNNOISE_EXPORT macro
    # resolve to __attribute__((visibility("default"))); GCC_SYMBOLS_PRIVATE_EXTERN
    # is the belt-and-suspenders project-level equivalent.
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) RNNOISE_BUILD=1',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO',
  }
  s.swift_version = '5.0'
end
