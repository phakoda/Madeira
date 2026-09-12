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
void madeira_wine32_show_keyboard(void);
// SDL/USB HID scancode, used by the session toolbar.
void madeira_wine32_key(int scancode, int down);

#ifdef __cplusplus
}
#endif
#endif
#endif
