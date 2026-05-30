#import "HotkeyController.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hidsystem/IOHIDLib.h>

#import "RectSelectionController.h"

// Forward declarations for the C core (single file, no header)
typedef struct {
    void *data;
    int   size;
} PngBuffer;

extern int  capture_fullscreen(PngBuffer *out);
extern void png_buffer_free(PngBuffer *png);

@interface HotkeyController ()
@property (nonatomic, assign) CFMachPortRef eventTap;
@property (strong, nonatomic) RectSelectionController *rectSelectionController;
@end

@implementation HotkeyController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.rectSelectionController = [[RectSelectionController alloc] init];
        [self checkPermissions];
        [self setupHotkey];
    }
    return self;
}

- (void)checkPermissions {
    BOOL hasAccessibility = AXIsProcessTrusted();
    BOOL hasScreenRecording = CGPreflightScreenCaptureAccess();

    NSLog(@"[permissions] Accessibility trusted: %@", hasAccessibility ? @"YES" : @"NO");
    NSLog(@"[permissions] Screen Recording preflight: %@", hasScreenRecording ? @"YES" : @"NO");

    // Explicitly request Input Monitoring permission.
    if (@available(macOS 10.15, *)) {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    }

    if (!hasAccessibility || !hasScreenRecording) {
        NSLog(@"\nShotshot needs permissions (opening System Settings for you)...\n");

        // Open Accessibility
        if (!hasAccessibility) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
        }

        // Open Input Monitoring (critical for hotkey)
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];

        // Open Screen Recording
        if (!hasScreenRecording) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        }
    }
}

- (void)setupHotkey {
    BOOL trustedNow = AXIsProcessTrusted();
    NSLog(@"[permissions] AXIsProcessTrusted right before creating event tap: %@", trustedNow ? @"YES" : @"NO");

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);

    self.eventTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        hotkeyEventCallback,
        (__bridge void *)self
    );

    if (self.eventTap) {
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(self.eventTap, true);
        NSLog(@"[hotkey] Event tap created successfully");
    } else {
        NSLog(@"Failed to create event tap. Accessibility/Input Monitoring permission is missing.");

        // Automatically open the Input Monitoring pane to make it easy for the user
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

static CGEventRef hotkeyEventCallback(CGEventTapProxy proxy,
                                      CGEventType type,
                                      CGEventRef event,
                                      void *userInfo)
{
    (void)proxy; // unused

    if (type != kCGEventKeyDown) {
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    CGKeyCode keycode  = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    BOOL command = (flags & kCGEventFlagMaskCommand) != 0;
    BOOL shift   = (flags & kCGEventFlagMaskShift)   != 0;

    HotkeyController *controller = (__bridge HotkeyController *)userInfo;

    // ANSI keycodes for the physical keys we care about (stable; these are the
    // same values as the classic kVK_ANSI_S / kVK_ANSI_4 on all modern macOS).
    // We avoid pulling in Carbon/HIToolbox framework for two constants.
    const CGKeyCode kKeyS = 1;   // 's' / 'S'
    const CGKeyCode kKey4 = 21;  // '4'

    // ⌘ + Shift + S  → Rectangular selection (primary flow)
    if (command && shift && keycode == kKeyS) {
        [controller startRectSelection];
        return NULL;
    }

    // ⌘ + Shift + 4  → Fullscreen capture
    if (command && shift && keycode == kKey4) {
        [controller takeScreenshot];
        return NULL;
    }

    return event;
}

- (void)takeScreenshot {
#ifndef NDEBUG
    NSLog(@"Hotkey received — attempting capture...");
#endif

    PngBuffer png = {0};

    int result = capture_fullscreen(&png);
    if (result != 0 || png.data == NULL || png.size <= 0) {
        NSLog(@"Capture failed (result=%d, data=%p, size=%d)", result, png.data, png.size);
        return;
    }

    NSLog(@"Capture succeeded, PNG size = %d bytes", png.size);

    // Copy to clipboard
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    BOOL success = [pasteboard setData:[NSData dataWithBytes:png.data length:png.size]
                               forType:NSPasteboardTypePNG];

    if (success) {
#ifndef NDEBUG
        NSLog(@"Successfully wrote PNG to clipboard (%d bytes)", png.size);
#endif
    } else {
        NSLog(@"Failed to write PNG to clipboard");
    }

    // Immediately release and zero the data (Approach A)
    png_buffer_free(&png);
#ifndef NDEBUG
    NSLog(@"Data zeroed and released");
#endif
}

- (void)startRectSelection {
    [self.rectSelectionController startSelection];
}

@end
