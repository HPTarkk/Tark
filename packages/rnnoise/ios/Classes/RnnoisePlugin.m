#import "RnnoisePlugin.h"
#if __has_include(<rnnoise/rnnoise-Swift.h>)
#import <rnnoise/rnnoise-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "rnnoise-Swift.h"
#endif

@implementation RnnoisePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftRnnoisePlugin registerWithRegistrar:registrar];
}
@end
