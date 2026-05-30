#import "StatusItemController.h"

@interface StatusItemController ()
@property (strong, nonatomic) NSStatusItem *statusItem;
@end

@implementation StatusItemController

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupStatusItem];
    }
    return self;
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    NSImage *icon = [NSImage imageNamed:NSImageNameComputer];
    [icon setTemplate:YES];
    self.statusItem.button.image = icon;
    self.statusItem.button.imagePosition = NSImageOnly;

    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Shotshot"
                                                      action:@selector(quit:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end
