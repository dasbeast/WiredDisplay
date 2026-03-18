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
    descriptor.maxPixelsWide = MAX(width, 5120);
    descriptor.maxPixelsHigh = MAX(height, 2880);
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
    // Force Retina/HiDPI backing for sharper text and UI rendering.
    const BOOL effectiveHiDPI = YES;
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
        {5120, 2880},
        {4096, 2304},
        {3840, 2160},
        {3200, 1800},
        {3024, 1964},
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
    // Include HiDPI duplicate modes so we can prefer the 2x (Retina) variant when
    // both a 1x and a 2x entry exist for the same pixel dimensions.
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (!allModes) return NO;

    CGDisplayModeRef targetMode = NULL;
    double bestScale = -1.0;
    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetPixelWidth(mode) == pixelWidth &&
            CGDisplayModeGetPixelHeight(mode) == pixelHeight) {
            size_t lw = CGDisplayModeGetWidth(mode);
            double scale = lw > 0 ? (double)pixelWidth / (double)lw : 1.0;
            if (scale > bestScale) {
                bestScale = scale;
                targetMode = mode;
            }
        }
    }

    if (!targetMode) {
        bridgeLog("No mode found for %ux%u on display %u", pixelWidth, pixelHeight, displayID);
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
