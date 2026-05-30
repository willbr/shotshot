#import <Cocoa/Cocoa.h>

@interface RectSelectionController : NSObject

@property (nonatomic, assign) NSRect globalSelectionRect;
@property (nonatomic, assign) BOOL isSelecting;

- (instancetype)init;
- (void)startSelection;
- (void)endSelection;

// Called by the selection view when the user finishes a drag (single consolidated path).
- (void)finishSelectionWithGlobalRect:(NSRect)globalRect;

@end
