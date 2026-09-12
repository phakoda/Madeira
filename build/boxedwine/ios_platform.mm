#import <Foundation/Foundation.h>
#include <string>

// The upstream POSIX platform delegates these three hooks to macOS. The iOS
// host supplies resource lookup and owns all file-picker/navigation UI.
extern "C" void MacPlatormSetThreadPriority(void) {}
extern "C" void MacPlatformOpenFileLocation(const char*) {}
extern "C" const char* MacPlatformGetResourcePath(const char* name) {
    static thread_local std::string path;
    @autoreleasepool {
        NSString* relative = name ? [NSString stringWithUTF8String:name] : nil;
        NSString* resource = relative ? [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:relative] : nil;
        path = resource.fileSystemRepresentation ?: "";
    }
    return path.c_str();
}
