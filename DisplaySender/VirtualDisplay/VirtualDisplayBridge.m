#import "VirtualDisplayBridge.h"
#import "CGVirtualDisplayPrivate.h"

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *sActiveDisplays = nil;
static dispatch_once_t sOnceToken;

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *activeDisplays(void) {
    dispatch_once(&sOnceToken, ^{
        sActiveDisplays = [NSMutableDictionary dictionary];
    });
    return sActiveDisplays;
}

@implementation VirtualDisplayBridge

+ (CGDirectDisplayID)createVirtualDisplayWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                       refreshRate:(double)refreshRate
                                             hiDPI:(BOOL)hiDPI
                                              name:(NSString *)name {
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.name = name;
    descriptor.vendorID = 0x1234;
    descriptor.productID = 0x5678;
    descriptor.serialNum = 0x0001;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    // ~27" display physical size
    descriptor.sizeInMillimeters = CGSizeMake(597, 336);
    // sRGB color primaries
    descriptor.redPrimary   = CGPointMake(0.6400, 0.3300);
    descriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
    descriptor.bluePrimary  = CGPointMake(0.1500, 0.0600);
    descriptor.whitePoint   = CGPointMake(0.3127, 0.3290);

    descriptor.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    descriptor.terminationHandler = ^(CGDirectDisplayID displayID, void *error) {
        NSLog(@"[VirtualDisplayBridge] Virtual display %u terminated", displayID);
        @synchronized (activeDisplays()) {
            [activeDisplays() removeObjectForKey:@(displayID)];
        }
    };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) {
        NSLog(@"[VirtualDisplayBridge] Failed to create CGVirtualDisplay");
        return 0;
    }

    // Configure display modes
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;

    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];

    // Primary mode at requested resolution
    CGVirtualDisplayMode *primaryMode = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                            height:height
                                                                       refreshRate:refreshRate];
    [modes addObject:primaryMode];

    // Add a lower resolution mode as fallback
    if (width > 1920) {
        CGVirtualDisplayMode *fallbackMode = [[CGVirtualDisplayMode alloc] initWithWidth:1920
                                                                                 height:1080
                                                                            refreshRate:refreshRate];
        [modes addObject:fallbackMode];
    }

    settings.modes = modes;

    BOOL applied = [display applySettings:settings];
    if (!applied) {
        NSLog(@"[VirtualDisplayBridge] Failed to apply settings to virtual display");
        return 0;
    }

    CGDirectDisplayID displayID = display.displayID;
    NSLog(@"[VirtualDisplayBridge] Created virtual display %u (%ux%u @ %.0fHz, hiDPI=%d)",
          displayID, width, height, refreshRate, hiDPI);

    @synchronized (activeDisplays()) {
        activeDisplays()[@(displayID)] = display;
    }

    return displayID;
}

+ (void)destroyVirtualDisplay:(CGDirectDisplayID)displayID {
    @synchronized (activeDisplays()) {
        CGVirtualDisplay *display = activeDisplays()[@(displayID)];
        if (display) {
            [activeDisplays() removeObjectForKey:@(displayID)];
            NSLog(@"[VirtualDisplayBridge] Destroyed virtual display %u", displayID);
        }
    }
}

+ (void)destroyAllVirtualDisplays {
    @synchronized (activeDisplays()) {
        NSLog(@"[VirtualDisplayBridge] Destroying %lu virtual display(s)", (unsigned long)activeDisplays().count);
        [activeDisplays() removeAllObjects];
    }
}

+ (NSUInteger)activeVirtualDisplayCount {
    @synchronized (activeDisplays()) {
        return activeDisplays().count;
    }
}

@end
