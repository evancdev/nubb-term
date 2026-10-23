#import <Foundation/Foundation.h>

/// This file contains wrappers around various ObjC functions so we can catch
/// exceptions, since you can't natively catch ObjC exceptions from Swift
/// (at least at the time of writing this comment).

/// NSWindow.addTabbedWindow wrapper
FOUNDATION_EXPORT BOOL NubbAddTabbedWindowSafely(
    id _Nonnull parent,
    id _Nonnull child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
);

/// NSWindowController.showWindow wrapper
FOUNDATION_EXPORT BOOL NubbShowWindowSafely(
    id _Nonnull controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
);
