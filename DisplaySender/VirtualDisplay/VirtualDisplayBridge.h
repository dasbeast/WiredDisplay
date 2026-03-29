#ifndef VirtualDisplayBridge_h
#define VirtualDisplayBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Obj-C bridge for creating/destroying CGVirtualDisplay instances.
/// These wrap the private CoreGraphics API so Swift can use them.
@interface VirtualDisplayBridge : NSObject

/// Creates a virtual display with the given resolution and refresh rate.
/// Returns the CGDirectDisplayID of the new display, or 0 on failure.
+ (CGDirectDisplayID)createVirtualDisplayWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                       refreshRate:(double)refreshRate
                                             hiDPI:(BOOL)hiDPI
                                              name:(NSString *)name;

/// Destroys a previously created virtual display.
+ (void)destroyVirtualDisplay:(CGDirectDisplayID)displayID;

/// Destroys all virtual displays created by this bridge.
+ (void)destroyAllVirtualDisplays;

/// Returns the number of active virtual displays.
+ (NSUInteger)activeVirtualDisplayCount;

/// Returns all display modes available on a virtual display.
/// Each element is an NSDictionary with keys:
///   "logicalWidth", "logicalHeight", "pixelWidth", "pixelHeight", "scale", "refreshRate"
+ (NSArray<NSDictionary *> *)availableModesForDisplay:(CGDirectDisplayID)displayID;

/// Returns the currently active mode for a display, or nil.
/// Keys match availableModesForDisplay:.
+ (nullable NSDictionary *)activeModeForDisplay:(CGDirectDisplayID)displayID;

/// Applies the first available mode whose logical and pixel dimensions match.
/// Falls back to pixel dimensions only if an exact logical+pixel match is unavailable.
/// Returns YES if the configuration was applied successfully.
+ (BOOL)applyModeForDisplay:(CGDirectDisplayID)displayID
               logicalWidth:(unsigned int)logicalWidth
              logicalHeight:(unsigned int)logicalHeight
                 pixelWidth:(unsigned int)pixelWidth
                pixelHeight:(unsigned int)pixelHeight
NS_SWIFT_NAME(applyMode(forDisplay:logicalWidth:logicalHeight:pixelWidth:pixelHeight:));

@end

NS_ASSUME_NONNULL_END

#endif /* VirtualDisplayBridge_h */
