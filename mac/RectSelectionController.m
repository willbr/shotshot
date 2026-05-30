#import "RectSelectionController.h"
#import <CoreGraphics/CoreGraphics.h>

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

// Local mouse handlers are intentionally minimal now.
// All drag tracking (including cross-monitor) is driven by global monitors in the controller
// so that a rect can be drawn starting on one screen and continuing onto another without snapping.

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

    // Four outside dim strips (the parts of *this* screen outside the selection)
    NSRect top    = NSMakeRect(sel.origin.x, NSMaxY(sel), sel.size.width,  NSMaxY(bounds) - NSMaxY(sel));
    NSRect bottom = NSMakeRect(sel.origin.x, NSMinY(bounds), sel.size.width, sel.origin.y - NSMinY(bounds));
    NSRect left   = NSMakeRect(NSMinX(bounds), sel.origin.y, sel.origin.x - NSMinX(bounds), sel.size.height);
    NSRect right  = NSMakeRect(NSMaxX(sel), sel.origin.y, NSMaxX(bounds) - NSMaxX(sel), sel.size.height);

    // The four corner regions (top-left, top-right, bottom-left, bottom-right) are NOT covered
    // by the four cardinal strips above. We must dim them explicitly.
    NSRect topLeft     = NSMakeRect(NSMinX(bounds), NSMaxY(sel), sel.origin.x - NSMinX(bounds), NSMaxY(bounds) - NSMaxY(sel));
    NSRect topRight    = NSMakeRect(NSMaxX(sel), NSMaxY(sel), NSMaxX(bounds) - NSMaxX(sel), NSMaxY(bounds) - NSMaxY(sel));
    NSRect bottomLeft  = NSMakeRect(NSMinX(bounds), NSMinY(bounds), sel.origin.x - NSMinX(bounds), sel.origin.y - NSMinY(bounds));
    NSRect bottomRight = NSMakeRect(NSMaxX(sel), NSMinY(bounds), NSMaxX(bounds) - NSMaxX(sel), sel.origin.y - NSMinY(bounds));

    [self.dimColor set];
    if (top.size.height > 0)          NSRectFill(top);
    if (bottom.size.height > 0)       NSRectFill(bottom);
    if (left.size.width > 0)          NSRectFill(left);
    if (right.size.width > 0)         NSRectFill(right);

    if (topLeft.size.width > 0 && topLeft.size.height > 0)         NSRectFill(topLeft);
    if (topRight.size.width > 0 && topRight.size.height > 0)       NSRectFill(topRight);
    if (bottomLeft.size.width > 0 && bottomLeft.size.height > 0)   NSRectFill(bottomLeft);
    if (bottomRight.size.width > 0 && bottomRight.size.height > 0) NSRectFill(bottomRight);

    // White border on this screen
    [[NSColor whiteColor] set];
    NSFrameRectWithWidth(sel, 1.0);

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
        self.ignoresMouseEvents = YES;   // important: let mouse events reach the global monitors
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
@property (nonatomic, strong) id mouseDownMonitor;
@property (nonatomic, strong) id mouseDraggedMonitor;
@property (nonatomic, strong) id mouseUpMonitor;
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

    // Make the first window (usually primary) key so local events have a home,
    // but we will drive the actual drag with global monitors for cross-monitor reliability.
    SelectionWindow *firstWin = self.windows.firstObject;
    [firstWin makeKeyAndOrderFront:nil];
    [firstWin makeMainWindow];
    [firstWin makeFirstResponder:firstWin.selectionView];

    self.isSelecting = YES;
    self.globalSelectionRect = NSZeroRect;

    // Tell every per-screen view to do its full-dim immediately.
    [self updateAllViews];

    __weak RectSelectionController *weakSelf = self;

    // Global monitors are required so a drag that starts on one screen can continue
    // when the mouse crosses onto another screen without snapping or dropping the drag.
    self.mouseDownMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                                   handler:^(NSEvent *event) {
        [weakSelf globalMouseDown:event];
    }];

    self.mouseDraggedMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                                                      handler:^(NSEvent *event) {
        [weakSelf globalMouseDragged:event];
    }];

    self.mouseUpMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                                                 handler:^(NSEvent *event) {
        [weakSelf globalMouseUp:event];
    }];

    // Local Esc still works because at least one window is key.
    self.escapeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode == 53) {
            [weakSelf endSelection];
            return nil;
        }
        return event;
    }];
}

- (void)endSelection {
    if (self.mouseDownMonitor)    [NSEvent removeMonitor:self.mouseDownMonitor];
    if (self.mouseDraggedMonitor) [NSEvent removeMonitor:self.mouseDraggedMonitor];
    if (self.mouseUpMonitor)      [NSEvent removeMonitor:self.mouseUpMonitor];
    if (self.escapeMonitor)       [NSEvent removeMonitor:self.escapeMonitor];

    self.mouseDownMonitor = nil;
    self.mouseDraggedMonitor = nil;
    self.mouseUpMonitor = nil;
    self.escapeMonitor = nil;

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

- (void)globalMouseDown:(NSEvent *)event {
    NSPoint p = [NSEvent mouseLocation];
    NSLog(@"[mouse] globalMouseDown received at (%.1f, %.1f)  windows=%lu  isSelecting(before)=%d",
          p.x, p.y, (unsigned long)self.windows.count, self.isSelecting);

    self.dragStartGlobal = p;
    self.globalSelectionRect = NSMakeRect(p.x, p.y, 0, 0);
    self.isSelecting = YES;
    [self updateAllViews];

    NSLog(@"[mouse]   after down: globalSelectionRect=(%.1f,%.1f) %.1fx%.1f  isSelecting=%d",
          self.globalSelectionRect.origin.x, self.globalSelectionRect.origin.y,
          self.globalSelectionRect.size.width, self.globalSelectionRect.size.height,
          self.isSelecting);
}

- (void)globalMouseDragged:(NSEvent *)event {
    if (!self.isSelecting) return;

#ifndef NDEBUG
    NSPoint currentDbg = [NSEvent mouseLocation];
    NSLog(@"[mouse] globalMouseDragged at (%.1f, %.1f)", currentDbg.x, currentDbg.y);
#endif

    NSPoint current = [NSEvent mouseLocation];

    // Always compute the selection from the original mouse-down point + current position.
    // Using the mutating globalSelectionRect as the "anchor" was causing the rect to stop
    // growing (height stuck at 2px) when dragging past the start point in the "min" direction.
    CGFloat x = MIN(self.dragStartGlobal.x, current.x);
    CGFloat y = MIN(self.dragStartGlobal.y, current.y);
    CGFloat w = fabs(current.x - self.dragStartGlobal.x);
    CGFloat h = fabs(current.y - self.dragStartGlobal.y);

    self.globalSelectionRect = NSMakeRect(x, y, w, h);
    [self updateAllViews];
}

- (void)globalMouseUp:(NSEvent *)event {
    NSLog(@"[mouse] globalMouseUp received  isSelecting=%d  current global rect=(%.1f,%.1f) %.1fx%.1f",
          self.isSelecting,
          self.globalSelectionRect.origin.x, self.globalSelectionRect.origin.y,
          self.globalSelectionRect.size.width, self.globalSelectionRect.size.height);

    if (!self.isSelecting) return;

    NSRect rect = self.globalSelectionRect;
    [self endSelection];   // this also removes the global monitors

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
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        BOOL ok = [pb setData:[NSData dataWithBytes:png.data length:png.size]
                      forType:NSPasteboardTypePNG];
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

// Legacy path kept for any direct callers (the view still calls this).
- (void)finishSelectionWithGlobalRect:(NSRect)globalRect {
    [self globalMouseUp:nil]; // delegate to the same logic
}

@end
