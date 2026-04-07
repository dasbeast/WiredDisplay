#import "VirtualDisplayBridge.h"
#import "CGVirtualDisplayPrivate.h"
#import <stdarg.h>
#import <stdio.h>

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *sActiveDisplays = nil;
static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *sRetiringDisplays = nil;
static dispatch_once_t sOnceToken;
static dispatch_queue_t sVirtualDisplayCallbackQueue = nil;
static dispatch_once_t sQueueOnceToken;

static void bridgeLog(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fputs("[VirtualDisplayBridge] ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
}

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *activeDisplays(void) {
    dispatch_once(&sOnceToken, ^{
        sActiveDisplays = [NSMutableDictionary dictionary];
        sRetiringDisplays = [NSMutableDictionary dictionary];
    });
    return sActiveDisplays;
}

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *retiringDisplays(void) {
    (void)activeDisplays();
    return sRetiringDisplays;
}

static dispatch_queue_t virtualDisplayCallbackQueue(void) {
    dispatch_once(&sQueueOnceToken, ^{
        sVirtualDisplayCallbackQueue = dispatch_queue_create("BK.DisplaySender.VirtualDisplayBridge", DISPATCH_QUEUE_SERIAL);
    });
    return sVirtualDisplayCallbackQueue;
}

static void scheduleRetiredDisplayPurge(NSNumber *displayKey, int64_t delayNanoseconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds), virtualDisplayCallbackQueue(), ^{
        @synchronized (activeDisplays()) {
            [retiringDisplays() removeObjectForKey:displayKey];
        }
    });
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
    descriptor.maxPixelsWide = MAX(width, 7680);
    descriptor.maxPixelsHigh = MAX(height, 4320);
    // ~27" display physical size
    descriptor.sizeInMillimeters = CGSizeMake(597, 336);
    // sRGB color primaries
    descriptor.redPrimary   = CGPointMake(0.6400, 0.3300);
    descriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
    descriptor.bluePrimary  = CGPointMake(0.1500, 0.0600);
    descriptor.whitePoint   = CGPointMake(0.3127, 0.3290);

    descriptor.queue = virtualDisplayCallbackQueue();
    descriptor.terminationHandler = ^(CGDirectDisplayID displayID, void *error) {
        NSNumber *displayKey = @(displayID);
        @synchronized (activeDisplays()) {
            [activeDisplays() removeObjectForKey:displayKey];
        }
        bridgeLog("Virtual display %u terminated", displayID);
        scheduleRetiredDisplayPurge(displayKey, 250 * NSEC_PER_MSEC);
    };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!display) {
        bridgeLog("Failed to create CGVirtualDisplay");
        return 0;
    }

    // Configure display modes
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    // Respect the caller's negotiated backing-scale preference so non-Retina receivers
    // can request a 1x surface instead of always forcing Retina.
    const BOOL effectiveHiDPI = hiDPI;
    settings.hiDPI = effectiveHiDPI ? 1 : 0;

    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];

    // Put requested mode first so it is selected by default.
    CGVirtualDisplayMode *primaryMode = [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                              height:height
                                                                         refreshRate:refreshRate];
    [modes addObject:primaryMode];

    // Additional common modes for "Show all resolutions".
    // Keep the requested mode first so it remains the startup default, but advertise both
    // lower and higher presets so the sender UI can force oddball resolutions for testing.
    static const unsigned int kPresetModes[][2] = {
        {7680, 4320},
        {6016, 3384},
        {5120, 2880},
        {5120, 3200},
        {5120, 2160},
        {4480, 2520},
        {4096, 2560},
        {4096, 2304},
        {3840, 2560},
        {3840, 2400},
        {3840, 2160},
        {3840, 1600},
        {3456, 2234},
        {3440, 1440},
        {3200, 2048},
        {3200, 1800},
        {3072, 1920},
        {3072, 1800},
        {3024, 1964},
        {3008, 1692},
        {2940, 1912},
        {2880, 1864},
        {2880, 1800},
        {2880, 1620},
        {2560, 1664},
        {2560, 1600},
        {2560, 1440},
        {2560, 1200},
        {2560, 1080},
        {2304, 1440},
        {2304, 1296},
        {2234, 1488},
        {2048, 1536},
        {2048, 1280},
        {2048, 1152},
        {1920, 1200},
        {1920, 1080},
        {1728, 1117},
        {1680, 1050},
        {1680, 945},
        {1600, 1024},
        {1600, 900},
        {1512, 982},
        {1470, 956},
        {1440, 900},
        {1366, 768},
        {1280, 800},
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
        bridgeLog("Failed to apply settings to virtual display");
        return 0;
    }

    CGDirectDisplayID displayID = display.displayID;
    bridgeLog("Created virtual display %u (%ux%u @ %.0fHz, hiDPI=%d, requestedHiDPI=%d)",
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

    // Key includes refresh bucket so 30/60/120 Hz variants are preserved separately.
    NSMutableDictionary<NSString *, NSDictionary *> *uniqueModes = [NSMutableDictionary dictionary];

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

        int scaleBucket = (int)llround(scale * 100.0);
        int refreshBucket = (int)llround(refreshRate * 100.0);
        NSString *key = [NSString stringWithFormat:@"%zux%zu-%zux%zu-%d-%d",
                         logicalWidth, logicalHeight, pixelWidth, pixelHeight, scaleBucket, refreshBucket];
        uniqueModes[key] = @{
            @"logicalWidth":  @(logicalWidth),
            @"logicalHeight": @(logicalHeight),
            @"pixelWidth":    @(pixelWidth),
            @"pixelHeight":   @(pixelHeight),
            @"scale":         @(scale),
            @"refreshRate":   @(refreshRate)
        };
    }

    CFRelease(modes);

    NSMutableArray *result = [NSMutableArray arrayWithArray:uniqueModes.allValues];

    // Sort by pixel area descending, then by higher refresh rate, then by higher scale.
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger areaA = [a[@"pixelWidth"] unsignedIntegerValue] * [a[@"pixelHeight"] unsignedIntegerValue];
        NSUInteger areaB = [b[@"pixelWidth"] unsignedIntegerValue] * [b[@"pixelHeight"] unsignedIntegerValue];
        if (areaA > areaB) return NSOrderedAscending;
        if (areaA < areaB) return NSOrderedDescending;
        double refreshA = [a[@"refreshRate"] doubleValue];
        double refreshB = [b[@"refreshRate"] doubleValue];
        if (refreshA > refreshB) return NSOrderedAscending;
        if (refreshA < refreshB) return NSOrderedDescending;
        double scaleA = [a[@"scale"] doubleValue];
        double scaleB = [b[@"scale"] doubleValue];
        if (scaleA > scaleB) return NSOrderedAscending;
        if (scaleA < scaleB) return NSOrderedDescending;
        return [a[@"logicalWidth"] compare:b[@"logicalWidth"]];
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
               logicalWidth:(unsigned int)logicalWidth
              logicalHeight:(unsigned int)logicalHeight
                pixelWidth:(unsigned int)pixelWidth
               pixelHeight:(unsigned int)pixelHeight
               refreshRate:(double)refreshRate {
    // Include HiDPI duplicate modes so callers can select a specific logical+pixel mode,
    // not just "whatever scale is highest for this pixel size".
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (!allModes) return NO;

    CGDisplayModeRef targetMode = NULL;
    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetPixelWidth(mode) == pixelWidth &&
            CGDisplayModeGetPixelHeight(mode) == pixelHeight &&
            CGDisplayModeGetWidth(mode) == logicalWidth &&
            CGDisplayModeGetHeight(mode) == logicalHeight &&
            fabs(CGDisplayModeGetRefreshRate(mode) - refreshRate) < 0.01) {
            targetMode = mode;
            break;
        }
    }

    if (!targetMode) {
        for (CFIndex i = 0; i < count; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
            if (CGDisplayModeGetPixelWidth(mode) == pixelWidth &&
                CGDisplayModeGetPixelHeight(mode) == pixelHeight &&
                CGDisplayModeGetWidth(mode) == logicalWidth &&
                CGDisplayModeGetHeight(mode) == logicalHeight) {
                targetMode = mode;
                break;
            }
        }
    }

    if (!targetMode) {
        for (CFIndex i = 0; i < count; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
            if (CGDisplayModeGetPixelWidth(mode) == pixelWidth &&
                CGDisplayModeGetPixelHeight(mode) == pixelHeight) {
                targetMode = mode;
                break;
            }
        }
    }

    if (!targetMode) {
        bridgeLog("No mode found for %ux%u (%ux%u logical) on display %u",
                  pixelWidth, pixelHeight, logicalWidth, logicalHeight, displayID);
        CFRelease(allModes);
        return NO;
    }

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        bridgeLog("CGBeginDisplayConfiguration failed: %d", err);
        CFRelease(allModes);
        return NO;
    }

    err = CGConfigureDisplayWithDisplayMode(config, displayID, targetMode, NULL);
    if (err != kCGErrorSuccess) {
        bridgeLog("CGConfigureDisplayWithDisplayMode failed: %d", err);
        CGCancelDisplayConfiguration(config);
        CFRelease(allModes);
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    CFRelease(allModes);

    if (err == kCGErrorSuccess) {
        bridgeLog("Applied mode %ux%u on display %u", pixelWidth, pixelHeight, displayID);
    } else {
        bridgeLog("CGCompleteDisplayConfiguration failed: %d", err);
    }
    return err == kCGErrorSuccess;
}

+ (void)destroyVirtualDisplay:(CGDirectDisplayID)displayID {
    NSNumber *displayKey = @(displayID);
    @synchronized (activeDisplays()) {
        CGVirtualDisplay *display = activeDisplays()[displayKey];
        if (display) {
            [activeDisplays() removeObjectForKey:displayKey];
            retiringDisplays()[displayKey] = display;
        }
    }
    bridgeLog("Destroy requested for virtual display %u", displayID);
    scheduleRetiredDisplayPurge(displayKey, 2 * NSEC_PER_SEC);
}

+ (void)destroyAllVirtualDisplays {
    @synchronized (activeDisplays()) {
        bridgeLog("Destroying %lu virtual display(s)", (unsigned long)activeDisplays().count);
        [retiringDisplays() addEntriesFromDictionary:activeDisplays()];
        [activeDisplays() removeAllObjects];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), virtualDisplayCallbackQueue(), ^{
        @synchronized (activeDisplays()) {
            [retiringDisplays() removeAllObjects];
        }
    });
}

+ (NSUInteger)activeVirtualDisplayCount {
    @synchronized (activeDisplays()) {
        return activeDisplays().count;
    }
}

@end
