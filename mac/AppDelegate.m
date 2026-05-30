#import "AppDelegate.h"
#import "StatusItemController.h"
#import "HotkeyController.h"

@interface AppDelegate ()
@property (strong, nonatomic) StatusItemController *statusItemController;
@property (strong, nonatomic) HotkeyController *hotkeyController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItemController = [[StatusItemController alloc] init];
    self.hotkeyController = [[HotkeyController alloc] init];
    // RectSelectionController is owned by HotkeyController (single instance)
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // Clean up if needed
}

@end
