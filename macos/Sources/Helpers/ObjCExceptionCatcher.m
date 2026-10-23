#import "ObjCExceptionCatcher.h"

#import <AppKit/AppKit.h>

static NSError *NubbErrorFromException(NSException *exception, NSInteger code) {
    NSString *reason = exception.reason ?: @"Unknown Objective-C exception";
    return [NSError errorWithDomain:@"Nubb.ObjCException"
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey: reason,
                               @"exception_name": exception.name,
                           }];
}

BOOL NubbAddTabbedWindowSafely(
    id parent,
    id child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
) {
    // AppKit occasionally throws NSException while adding tabbed windows,
    // in particular when creating tabs from the tab overview page since some
    // macOS update recently in 2025/2026 (unclear).
    //
    // We must catch it in Objective-C; letting this cross into Swift is unsafe.
    @try {
        [((NSWindow *)parent) addTabbedWindow:(NSWindow *)child ordered:(NSWindowOrderingMode)ordered];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = NubbErrorFromException(exception, 1);
        }

        return NO;
    }
}

BOOL NubbShowWindowSafely(
    id controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
) {
    // Selecting a newly added tab can throw from NSWindowStackController when
    // the tab group contains windows in inconsistent native fullscreen states.
    // Catch the exception here so the AppKit assertion doesn't abort the app.
    @try {
        [((NSWindowController *)controller) showWindow:sender];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = NubbErrorFromException(exception, 2);
        }

        return NO;
    }
}
