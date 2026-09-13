#ifndef MADEIRA_WINE32_IOS_VIEW_H
#define MADEIRA_WINE32_IOS_VIEW_H
#ifdef __OBJC__
#import <UIKit/UIKit.h>
#ifdef __cplusplus
extern "C" {
#endif

// Call on the main thread. The host owns the parent controller; SDL owns its
// child and Metal view. Passing nil detaches presentation without stopping the
// guest, so returning to the library does not discard the running session.
void madeira_wine32_set_view_host(UIViewController* parent);
// Detach only if this controller still owns presentation. SwiftUI can create
// the replacement before dismantling the old view during rotation.
void madeira_wine32_remove_view_host(UIViewController* parent);
void madeira_wine32_show_keyboard(void);
// SDL/USB HID scancode, used by the session toolbar.
void madeira_wine32_key(int scancode, int down);
// Normalized display-view coordinates. button is 1=left or 3=right;
// down=-1 moves the pointer, 0 releases, 1 presses.
void madeira_wine32_pointer(float x, float y, int button, int down);

#ifdef __cplusplus
}
#endif
#endif
#endif
