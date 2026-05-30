#import "RectSelectionController.h"
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

// Forward declarations for the C core
typedef struct {
    void *data;
    int   size;
} PngBuffer;

extern int  capture_rect(int x, int y, int width, int height, PngBuffer *out);
extern void png_buffer_free(PngBuffer *png);

@interface SelectionView : NSView
@property (nonatomic, strong) NSColor *dimColor;
@property (nonatomic, assign) NSRect localSelectionRect; // the portion of the selection that should be "cut out" on *this* view's screen, in the view's local coords (0,0 based)
@property (nonatomic, assign) BOOL isSelecting;
@property (nonatomic, assign) BOOL showsSizeLabel;      // controller decides which screen shows the dimension text
@property (nonatomic, assign) NSPoint startPoint; // in view coordinates for current drag (used only if local drag starts here)
@property (nonatomic, weak) RectSelectionController *controller;
@end

@implementation SelectionView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.dimColor = [[NSColor blackColor] colorWithAlphaComponent:0.5];
        // Intentionally not layer-backed — layer-backed transparent windows at max level
        // often produce striped/garbage corruption on secondary monitors.
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

// Local mouse handlers are intentionally minimal. Drag tracking is driven by a CGEventTap
// (see mouseSelectionEventCallback) so that clicks are consumed and do not reach apps
// under the dimmed overlay, while still supporting cross-monitor drags.

- (void)mouseDown:(NSEvent *)event {
    // Only used to ensure this view can become first responder on its own screen.
    // Real drag start is handled by globalMouseDown.
    (void)event;
}

- (void)mouseDragged:(NSEvent *)event {
    (void)event;
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
}

- (void)cancelOperation:(id)sender {
    [self.controller endSelection];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Critical for non-opaque NSBackingStoreBuffered windows used as full-screen overlays:
    // Always start by clearing the dirty area to fully transparent. Without this, pixels from
    // the previous frame (especially the white border and white size label) remain in the
    // backing store. The subsequent 50% black dim fill then blends over those remnants,
    // producing exactly the 1px white horizontal and vertical lines visible while dragging.
    [[NSColor clearColor] set];
    NSRectFill(dirtyRect);

    NSRect bounds = self.bounds; // this view's screen, 0,0 based

    if (!self.isSelecting || NSIsEmptyRect(self.localSelectionRect)) {
        // Full dim for this physical screen (either before drag starts, or selection is entirely on other monitors)
        [self.dimColor set];
        NSRectFill(bounds);
        return;
    }

    NSRect sel = self.localSelectionRect; // already in this view's local coords, provided by controller

    // Normalize in case upstream ever hands us a rect with negative width/height
    // (this has been the source of "only visible when dragging in one direction" bugs).
    if (sel.size.width < 0) {
        sel.origin.x += sel.size.width;
        sel.size.width = -sel.size.width;
    }
    if (sel.size.height < 0) {
        sel.origin.y += sel.size.height;
        sel.size.height = -sel.size.height;
    }

    // Snap the selection rect to pixel boundaries for the hole punch and border.
    // Fractional coordinates from live mouse drag + NSRectFill (even with kCGBlendModeCopy)
    // produce anti-aliased fringes exactly where the dim fill meets the transparent hole.
    // This is the source of the 1px white vertical and horizontal lines at the inner edges.
    NSRect hole;
    hole.origin.x = floor(sel.origin.x);
    hole.origin.y = floor(sel.origin.y);
    hole.size.width = ceil(NSMaxX(sel) - hole.origin.x);
    hole.size.height = ceil(NSMaxY(sel) - hole.origin.y);

    // Fill the entire screen with dim, then punch a clean transparent hole for the
    // selection area. The hole rect is integer-aligned so the dim/hole boundary has
    // no subpixel fringe.
    [self.dimColor set];
    NSRectFill(bounds);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextSetShouldAntialias(ctx, false);
    [[NSColor clearColor] set];
    NSRectFill(hole);
    CGContextRestoreGState(ctx);

    // White border drawn snapped for a crisp 1px line right at the dim/hole boundary.
    [[NSColor whiteColor] set];
    NSRect borderRect = NSMakeRect(hole.origin.x + 0.5,
                                   hole.origin.y + 0.5,
                                   hole.size.width,
                                   hole.size.height);
    NSFrameRectWithWidth(borderRect, 1.0);

    // Size label only on the screen the controller chose (avoids duplicates when selection spans monitors)
    if (self.showsSizeLabel) {
        NSString *sizeString = [NSString stringWithFormat:@"%ld × %ld",
                                (long)round(sel.size.width),
                                (long)round(sel.size.height)];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSSize textSize = [sizeString sizeWithAttributes:attrs];
        NSPoint textPoint = NSMakePoint(NSMidX(sel) - textSize.width/2.0, NSMaxY(sel) + 4);
        [sizeString drawAtPoint:textPoint withAttributes:attrs];
    }
}

@end

@interface SelectionWindow : NSWindow
@property (strong, nonatomic) SelectionView *selectionView;
@end

@implementation SelectionWindow

- (instancetype)initWithContentRect:(NSRect)contentRect {
    self = [super initWithContentRect:contentRect
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.level = CGWindowLevelForKey(kCGMaximumWindowLevelKey);
        self.backgroundColor = [NSColor clearColor];
        self.opaque = NO;
        self.hasShadow = NO;   // critical for clean full-desktop overlays, especially multi-monitor
        self.ignoresMouseEvents = YES;   // overlay is transparent to normal responder chain; CGEventTap consumes events so they don't reach background apps
        self.acceptsMouseMovedEvents = YES;
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

        // The view must have a 0,0-based frame. The window's frame (set later) carries the
        // global origin of the union rect. Using the raw contentRect (which can have negative
        // .origin on setups with screens left/above the primary) would give the view a
        // non-zero origin, breaking all per-screen strip math and causing only the primary
        // to receive dimming / drawing.
        NSRect viewFrame = NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height);
        self.selectionView = [[SelectionView alloc] initWithFrame:viewFrame];
        self.contentView = self.selectionView;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }

@end

@interface RectSelectionController ()
@property (strong, nonatomic) NSMutableArray<SelectionWindow *> *windows;
@property (nonatomic, assign) CFMachPortRef mouseEventTap;
@property (nonatomic, assign) CFRunLoopSourceRef mouseEventTapSource;
@property (nonatomic, strong) id escapeMonitor; // local key monitor for Esc
@property (nonatomic, assign) NSPoint dragStartGlobal; // fixed anchor point for the current drag
@end

@implementation RectSelectionController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.windows = [NSMutableArray array];
    }
    return self;
}

- (void)startSelection {
    [self endSelection];

    NSArray<NSScreen *> *screens = [NSScreen screens];
#ifndef NDEBUG
    NSLog(@"[rect] startSelection — %lu physical screen(s) detected", (unsigned long)screens.count);
#endif
    if (screens.count == 0) return;

    // One properly-sized, max-level window per physical screen.
    // This is the most reliable way on macOS to get dimming + drawing on *every* monitor,
    // especially with negative global origins or mixed-scale setups.
    for (NSScreen *screen in screens) {
        NSRect screenFrame = screen.frame;

        SelectionWindow *win = [[SelectionWindow alloc] initWithContentRect:screenFrame];
        [win setFrame:screenFrame display:YES];
        win.selectionView.controller = self;
        [self.windows addObject:win];

        [win orderFront:nil];   // bring every screen's overlay up
    }

    [NSApp activateIgnoringOtherApps:YES];

    // Make the first window (usually primary) key so local events (Esc) have a home.
    SelectionWindow *firstWin = self.windows.firstObject;
    [firstWin makeKeyAndOrderFront:nil];
    [firstWin makeMainWindow];
    [firstWin makeFirstResponder:firstWin.selectionView];

    self.isSelecting = YES;
    self.globalSelectionRect = NSZeroRect;

    // Tell every per-screen view to do its full-dim immediately.
    [self updateAllViews];

    __weak RectSelectionController *weakSelf = self;

    // CGEventTap for mouse events during selection. We consume the events (return NULL)
    // so the user's clicks do not activate or click through to applications behind the
    // dimmed overlay. This is much more reliable than the old NSEvent global monitor approach.
    CGEventMask mouseMask = CGEventMaskBit(kCGEventLeftMouseDown) |
                            CGEventMaskBit(kCGEventLeftMouseDragged) |
                            CGEventMaskBit(kCGEventLeftMouseUp);

    self.mouseEventTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mouseMask,
        mouseSelectionEventCallback,
        (__bridge void *)self
    );

    if (self.mouseEventTap) {
        self.mouseEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.mouseEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), self.mouseEventTapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(self.mouseEventTap, true);
    } else {
        NSLog(@"[rect] WARNING: failed to create mouse event tap (missing Input Monitoring permission?)");
    }

    // Local Esc monitor (works because one window is key).
    self.escapeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode == 53) {
            [weakSelf endSelection];
            return nil;
        }
        return event;
    }];
}

// CGEventTap callback that drives the selection while the dimmed overlays are up.
// Returning NULL consumes the event so it never reaches apps behind the overlay.
static CGEventRef mouseSelectionEventCallback(CGEventTapProxy proxy,
                                              CGEventType type,
                                              CGEventRef event,
                                              void *userInfo)
{
    (void)proxy;

    RectSelectionController *controller = (__bridge RectSelectionController *)userInfo;
    if (!controller || !controller.isSelecting) {
        return event;
    }

    CGPoint cgLocation = CGEventGetLocation(event);
    NSPoint location = NSPointFromCGPoint(cgLocation);

    switch (type) {
        case kCGEventLeftMouseDown:
            [controller handleSelectionMouseDownAtPoint:location];
            return NULL; // consume — prevents the click from activating windows underneath
        case kCGEventLeftMouseDragged:
            [controller handleSelectionMouseDraggedAtPoint:location];
            return NULL;
        case kCGEventLeftMouseUp:
            [controller handleSelectionMouseUpAtPoint:location];
            return NULL;
        default:
            return event;
    }
}

- (void)endSelection {
    if (self.escapeMonitor) {
        [NSEvent removeMonitor:self.escapeMonitor];
        self.escapeMonitor = nil;
    }

    if (self.mouseEventTap) {
        CGEventTapEnable(self.mouseEventTap, false);
        if (self.mouseEventTapSource) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), self.mouseEventTapSource, kCFRunLoopCommonModes);
            CFRelease(self.mouseEventTapSource);
            self.mouseEventTapSource = NULL;
        }
        CFRelease(self.mouseEventTap);
        self.mouseEventTap = NULL;
    }

    for (SelectionWindow *win in self.windows) {
        [win orderOut:nil];
    }
    [self.windows removeAllObjects];

    self.isSelecting = NO;
    self.globalSelectionRect = NSZeroRect;
}

- (void)updateAllViews {
    NSLog(@"[mouse] updateAllViews called  globalRect=(%.1f,%.1f) %.1fx%.1f  isSelecting=%d  windows=%lu",
          self.globalSelectionRect.origin.x, self.globalSelectionRect.origin.y,
          self.globalSelectionRect.size.width, self.globalSelectionRect.size.height,
          self.isSelecting, (unsigned long)self.windows.count);

    // Decide which screen (if any) should display the size label — the one with the largest overlap.
    SelectionView *labelView = nil;
    CGFloat maxArea = 0;

    for (SelectionWindow *win in self.windows) {
        NSRect screenGlobal = win.frame;
        NSRect intersection = NSIntersectionRect(self.globalSelectionRect, screenGlobal);

        SelectionView *v = win.selectionView;
        v.isSelecting = self.isSelecting;
        v.showsSizeLabel = NO;

        if (NSIsEmptyRect(intersection)) {
            v.localSelectionRect = NSZeroRect;
            NSLog(@"[mouse]   screen %@ → no intersection (full dim)", NSStringFromRect(win.frame));
        } else {
            NSRect local = [win convertRectFromScreen:intersection];
            local = NSIntersectionRect(local, v.bounds);

            // Normalize defensively (some convertRectFromScreen + intersection paths have been
            // known to produce negative sizes in edge cases with negative global Y monitors).
            if (local.size.width < 0) {
                local.origin.x += local.size.width;
                local.size.width = -local.size.width;
            }
            if (local.size.height < 0) {
                local.origin.y += local.size.height;
                local.size.height = -local.size.height;
            }

            v.localSelectionRect = local;

            NSLog(@"[mouse]   screen %@ → intersection global=%@  local=%@",
                  NSStringFromRect(win.frame),
                  NSStringFromRect(intersection),
                  NSStringFromRect(local));

            CGFloat area = intersection.size.width * intersection.size.height;
            if (area > maxArea) {
                maxArea = area;
                labelView = v;
            }
        }
    }

    if (labelView) {
        labelView.showsSizeLabel = YES;
    }

    // Now tell every window to redraw
    for (SelectionWindow *win in self.windows) {
        SelectionView *v = win.selectionView;
        [v setNeedsDisplay:YES];
        [win displayIfNeeded];
        [v displayIfNeeded];
    }
}

// Point-based handlers (primary path via CGEventTap during dimmed selection).
// The tap consumes the events (return NULL) so clicks do not reach apps behind the overlay.

- (void)handleSelectionMouseDownAtPoint:(NSPoint)p {
    NSLog(@"[mouse] mouseDown at (%.1f, %.1f)  windows=%lu  isSelecting=%d",
          p.x, p.y, (unsigned long)self.windows.count, self.isSelecting);

    self.dragStartGlobal = p;
    self.globalSelectionRect = NSMakeRect(p.x, p.y, 0, 0);
    self.isSelecting = YES;
    [self updateAllViews];
}

- (void)handleSelectionMouseDraggedAtPoint:(NSPoint)current {
    if (!self.isSelecting) return;

#ifndef NDEBUG
    NSLog(@"[mouse] mouseDragged at (%.1f, %.1f)", current.x, current.y);
#endif

    // Always compute the selection from the original mouse-down point + current position.
    CGFloat x = fmin(self.dragStartGlobal.x, current.x);
    CGFloat y = fmin(self.dragStartGlobal.y, current.y);
    CGFloat w = fabs(current.x - self.dragStartGlobal.x);
    CGFloat h = fabs(current.y - self.dragStartGlobal.y);

    self.globalSelectionRect = NSMakeRect(x, y, w, h);
    [self updateAllViews];
}

- (void)handleSelectionMouseUpAtPoint:(NSPoint)ignoredLocation {
    NSLog(@"[mouse] mouseUp  current global rect=(%.1f,%.1f) %.1fx%.1f",
          self.globalSelectionRect.origin.x, self.globalSelectionRect.origin.y,
          self.globalSelectionRect.size.width, self.globalSelectionRect.size.height);

    if (!self.isSelecting) return;

    NSRect rect = self.globalSelectionRect;
    [self endSelection];   // disables the mouse event tap

    NSLog(@"[mouse]   after endSelection, about to capture rect=(%.1f,%.1f) %.1fx%.1f",
          rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);

    if (NSIsEmptyRect(rect) || rect.size.width < 1 || rect.size.height < 1) {
        NSLog(@"[mouse]   rect too small, skipping capture");
        return;
    }

    int x = (int)round(rect.origin.x);
    int y = (int)round(rect.origin.y);
    int w = (int)round(rect.size.width);
    int h = (int)round(rect.size.height);

    PngBuffer png = {0};
    int result = capture_rect(x, y, w, h, &png);

    if (result == 0 && png.data && png.size > 0) {
        NSData *pngData = [NSData dataWithBytes:png.data length:png.size];
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];

        NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
        [item setData:pngData forType:NSPasteboardTypePNG];
        BOOL ok = [pb writeObjects:@[item]];

        if (ok) {
#ifndef NDEBUG
            NSLog(@"Rect capture copied to clipboard (%d bytes)", png.size);
#endif
        } else {
            NSLog(@"Rect capture: failed to write to pasteboard");
        }
    } else {
        NSLog(@"Rect capture failed (result=%d)", result);
    }

    if (png.data) {
        png_buffer_free(&png);
    }
}

// Legacy wrappers (still used by finishSelectionWithGlobalRect and any external callers).
- (void)globalMouseDown:(NSEvent *)event {
    [self handleSelectionMouseDownAtPoint:[NSEvent mouseLocation]];
}

- (void)globalMouseDragged:(NSEvent *)event {
    [self handleSelectionMouseDraggedAtPoint:[NSEvent mouseLocation]];
}

- (void)globalMouseUp:(NSEvent *)event {
    [self handleSelectionMouseUpAtPoint:[NSEvent mouseLocation]];
}

// Legacy path kept for any direct callers.
- (void)finishSelectionWithGlobalRect:(NSRect)globalRect {
    [self globalMouseUp:nil];
}

@end
