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
    // Advertise a larger max so macOS can expose higher modes in "Show all resolutions".
    descriptor.maxPixelsWide = MAX(width, 5120);
    descriptor.maxPixelsHigh = MAX(height, 2880);
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
    // Force Retina/HiDPI backing for sharper text and UI rendering.
    const BOOL effectiveHiDPI = YES;
    settings.hiDPI = effectiveHiDPI ? 1 : 0;

    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];

    // Put requested mode first so it is selected by default.
    CGVirtualDisplayMode *primaryMode = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                              height:height
                                                                         refreshRate:refreshRate];
    [modes addObject:primaryMode];

    // Additional common 16:9 modes for "Show all resolutions".
    // Only advertise modes at or above the requested base size so the default
    // mode does not land on a softer, lower-resolution setting.
    static const unsigned int kPresetModes[][2] = {
        {5120, 2880},
        {4096, 2304},
        {3840, 2160},
        {3200, 1800},
        {3008, 1692},
        {2880, 1620},
        {2560, 1440},
        {2304, 1296},
        {2048, 1152},
        {1920, 1080},
        {1680, 945},
        {1600, 900},
        {1366, 768},
        {1280, 720}
    };

    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:[NSString stringWithFormat:@"%ux%u", width, height]];
    const size_t presetCount = sizeof(kPresetModes) / sizeof(kPresetModes[0]);
    for (size_t i = 0; i < presetCount; i++) {
        const unsigned int candidateWidth = kPresetModes[i][0];
        const unsigned int candidateHeight = kPresetModes[i][1];

        if (candidateWidth > descriptor.maxPixelsWide || candidateHeight > descriptor.maxPixelsHigh) {
            continue;
        }

        if (candidateWidth < width || candidateHeight < height) {
            continue;
        }

        NSString *key = [NSString stringWithFormat:@"%ux%u", candidateWidth, candidateHeight];
        if ([seen containsObject:key]) {
            continue;
        }
        [seen addObject:key];

        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:candidateWidth
                                                                           height:candidateHeight
                                                                      refreshRate:refreshRate];
        [modes addObject:mode];
    }

    settings.modes = modes;

    BOOL applied = [display applySettings:settings];
    if (!applied) {
        NSLog(@"[VirtualDisplayBridge] Failed to apply settings to virtual display");
        return 0;
    }

    CGDirectDisplayID displayID = display.displayID;
    NSLog(@"[VirtualDisplayBridge] Created virtual display %u (%ux%u @ %.0fHz, hiDPI=%d, requestedHiDPI=%d)",
          displayID, width, height, refreshRate, effectiveHiDPI, hiDPI);

    @synchronized (activeDisplays()) {
        activeDisplays()[@(displayID)] = display;
    }

    return displayID;
}

+ (NSArray<NSDictionary *> *)availableModesForDisplay:(CGDirectDisplayID)displayID {
    // Fetch all modes including HiDPI duplicates so we can pick the best per resolution.
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (!modes) return @[];

    // Key: "pixelWxpixelH" → best NSDictionary seen so far.
    // When two modes share pixel dimensions, prefer the HiDPI one (higher scale).
    NSMutableDictionary<NSString *, NSDictionary *> *bestForPixelSize = [NSMutableDictionary dictionary];

    CFIndex count = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pixelWidth  = CGDisplayModeGetPixelWidth(mode);
        size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
        size_t logicalWidth  = CGDisplayModeGetWidth(mode);
        size_t logicalHeight = CGDisplayModeGetHeight(mode);
        double refreshRate = CGDisplayModeGetRefreshRate(mode);

        if (pixelWidth < 640 || pixelHeight < 480) continue;
        if (logicalWidth == 0 || logicalHeight == 0) continue;

        double scale = (double)pixelWidth / (double)logicalWidth;

        NSString *key = [NSString stringWithFormat:@"%zux%zu", pixelWidth, pixelHeight];
        NSDictionary *existing = bestForPixelSize[key];

        // Prefer HiDPI (scale > 1) over 1x for the same pixel dimensions.
        BOOL replaceExisting = (existing == nil) ||
                               (scale > [existing[@"scale"] doubleValue]);

        if (replaceExisting) {
            bestForPixelSize[key] = @{
                @"logicalWidth":  @(logicalWidth),
                @"logicalHeight": @(logicalHeight),
                @"pixelWidth":    @(pixelWidth),
                @"pixelHeight":   @(pixelHeight),
                @"scale":         @(scale),
                @"refreshRate":   @(refreshRate)
            };
        }
    }

    CFRelease(modes);

    NSMutableArray *result = [NSMutableArray arrayWithArray:bestForPixelSize.allValues];

    // Sort by pixel area descending (sharpest first).
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger areaA = [a[@"pixelWidth"] unsignedIntegerValue] * [a[@"pixelHeight"] unsignedIntegerValue];
        NSUInteger areaB = [b[@"pixelWidth"] unsignedIntegerValue] * [b[@"pixelHeight"] unsignedIntegerValue];
        if (areaA > areaB) return NSOrderedAscending;
        if (areaA < areaB) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return result;
}

+ (nullable NSDictionary *)activeModeForDisplay:(CGDirectDisplayID)displayID {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    if (!mode) return nil;

    size_t pixelWidth  = CGDisplayModeGetPixelWidth(mode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
    size_t logicalWidth  = CGDisplayModeGetWidth(mode);
    size_t logicalHeight = CGDisplayModeGetHeight(mode);
    double refreshRate = CGDisplayModeGetRefreshRate(mode);
    double scale = logicalWidth > 0 ? (double)pixelWidth / (double)logicalWidth : 1.0;
    CGDisplayModeRelease(mode);

    return @{
        @"logicalWidth":  @(logicalWidth),
        @"logicalHeight": @(logicalHeight),
        @"pixelWidth":    @(pixelWidth),
        @"pixelHeight":   @(pixelHeight),
        @"scale":         @(scale),
        @"refreshRate":   @(refreshRate)
    };
}

+ (BOOL)applyModeForDisplay:(CGDirectDisplayID)displayID
                pixelWidth:(unsigned int)pixelWidth
               pixelHeight:(unsigned int)pixelHeight {
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    if (!allModes) return NO;

    CGDisplayModeRef targetMode = NULL;
    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetPixelWidth(mode) == pixelWidth &&
            CGDisplayModeGetPixelHeight(mode) == pixelHeight) {
            targetMode = mode;
            break;
        }
    }

    if (!targetMode) {
        NSLog(@"[VirtualDisplayBridge] No mode found for %ux%u on display %u", pixelWidth, pixelHeight, displayID);
        CFRelease(allModes);
        return NO;
    }

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        NSLog(@"[VirtualDisplayBridge] CGBeginDisplayConfiguration failed: %d", err);
        CFRelease(allModes);
        return NO;
    }

    err = CGConfigureDisplayWithDisplayMode(config, displayID, targetMode, NULL);
    if (err != kCGErrorSuccess) {
        NSLog(@"[VirtualDisplayBridge] CGConfigureDisplayWithDisplayMode failed: %d", err);
        CGCancelDisplayConfiguration(config);
        CFRelease(allModes);
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    CFRelease(allModes);

    if (err == kCGErrorSuccess) {
        NSLog(@"[VirtualDisplayBridge] Applied mode %ux%u on display %u", pixelWidth, pixelHeight, displayID);
    } else {
        NSLog(@"[VirtualDisplayBridge] CGCompleteDisplayConfiguration failed: %d", err);
    }
    return err == kCGErrorSuccess;
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
