#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "ios_view.h"
#include <SDL.h>
#include <string>

static __weak UIViewController* displayHost;
static __weak UIViewController* displayGuest;

static void detachGuest() {
    if (displayGuest.parentViewController) {
        [displayGuest willMoveToParentViewController:nil];
        [displayGuest.view removeFromSuperview];
        [displayGuest removeFromParentViewController];
    }
}

static void attachGuest() {
    if (!displayHost || !displayGuest || !displayGuest.isViewLoaded) return;
    if (displayGuest.parentViewController != displayHost) {
        detachGuest();
        [displayHost addChildViewController:displayGuest];
        displayGuest.view.frame = displayHost.view.bounds;
        displayGuest.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [displayHost.view addSubview:displayGuest.view];
        [displayGuest didMoveToParentViewController:displayHost];
    } else if (displayGuest.view.superview != displayHost.view) {
        // SDL replaces its initial touch view with a Metal view after startup.
        displayGuest.view.frame = displayHost.view.bounds;
        displayGuest.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [displayHost.view addSubview:displayGuest.view];
    }
    [displayHost.view layoutIfNeeded];
}

extern "C" void madeira_wine32_set_view_host(UIViewController* parent) {
    NSCAssert([NSThread isMainThread], @"Wine32 display requires the main thread");
    if (displayHost != parent) detachGuest();
    displayHost = parent;
    attachGuest();
}

extern "C" void madeiraWine32SDLViewChanged(UIViewController* controller) {
    if (displayGuest != controller) detachGuest();
    displayGuest = controller;
    attachGuest();
}

extern "C" void madeiraWine32SDLSetVisible(BOOL visible) {
    displayGuest.view.hidden = !visible;
}

extern "C" void madeiraWine32SDLWillDestroy(UIViewController* controller) {
    if (displayGuest == controller) {
        detachGuest();
        displayGuest = nil;
    }
}

extern "C" void madeira_wine32_show_keyboard(void) {
    if (SDL_IsTextInputActive()) SDL_StopTextInput();
    else SDL_StartTextInput();
}

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
