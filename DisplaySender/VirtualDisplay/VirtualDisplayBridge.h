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

@end

NS_ASSUME_NONNULL_END

#endif /* VirtualDisplayBridge_h */
