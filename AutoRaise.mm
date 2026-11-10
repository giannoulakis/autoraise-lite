/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Some pieces of the code are based on
 * metamove by jmgao as part of XFree86
 *
 * AutoRaise Lite: modified by giannoulakis in November 2026, based on
 * AutoRaise v5.7. Stripped down to raise on hover with fixed settings:
 * no focus without raise, mouse warp, config file or command line options.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// make && open AutoRaise.app

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>

#define STACK_THRESHOLD 20

// The window under the mouse is raised once the mouse stops for one poll interval
#define POLL_MILLIS 100
// Hold this key to temporarily disable AutoRaise
#define DISABLE_KEY kCGEventFlagMaskControl

// It seems OSX Monterey introduced a transparent 3 pixel border around each window. This
// means that when two windows are visually precisely connected and not overlapping, in
// reality they are. Consequently one has to move the mouse 3 pixels further out of the
// visual area to make the connected window raise. This new OSX 'feature' also introduces
// unwanted raising of windows when visually connected to the top menu bar. To solve this
// we correct the mouse position before determining which window is underneath the mouse.
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
#define SCREEN_EDGE_CORRECTION 1 // 1 <= value <= WINDOW_CORRECTION
// If the mouse position is within WINDOW_CORRECTION pixels of a screen edge,
// treat it as if it is SCREEN_EDGE_CORRECTION pixels removed from that edge.
static CGPoint oldCorrectedPoint = {0, 0};

#define TASK_SWITCHER_MODIFIER_KEY kCGEventFlagMaskCommand // kCGEventFlagMaskControl, ...

extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above method is undocumented and subjective to incompatible changes

static AXObserverRef axObserver = NULL;
static uint64_t lastDestroyedMouseWindow_id = kCGNullWindowID;

static CFMachPortRef eventTap = NULL;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _dock_app = NULL;
static NSArray * const mainWindowAppsWithoutTitle =@[
    @"System Settings",
    @"System Information",
    @"Photos",
    @"Calculator",
    @"Podcasts",
    @"Stickies Pro",
    @"Reeder"
];
static NSArray * pwas = @[
    @"Chrome",
    @"Chromium",
    @"Vivaldi",
    @"Brave",
    @"Opera",
    @"edgemac",
    @"helium"
];
static NSString * const DockBundleId = @"com.apple.dock";
static NSString * const AssistiveControl = @"AssistiveControl";
static NSString * const MissionControl = @"Mission Control";
static NSString * const BartenderBar = @"Bartender Bar";
static NSString * const AppStoreSearchResults = @"Search results";
static NSString * const Untitled = @"Untitled"; // OSX Email search
static NSString * const Zim = @"Zim";
static NSString * const XQuartz = @"XQuartz";
static NSString * const Finder = @"Finder";
static NSString * const Pake = @"pake";
static NSString * const NoTitle = @"";
static CGPoint oldPoint = {0, 0};
static bool propagateMouseMoved = false;
static bool spaceHasChanged = false;
static int ignoreTimes = 0;
static int raiseTimes = 0;

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    // Note activateWithOptions does not work properly on OSX 11.1
    [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
        activateWithOptions: 0];
}

inline void raiseAndActivate(AXUIElementRef _window, pid_t window_pid) {
    if (AXUIElementPerformAction(_window, kAXRaiseAction) == kAXErrorSuccess) {
        activate(window_pid);
    }
}

// TODO: does not take into account different languages
inline bool titleEquals(AXUIElementRef _element, NSArray * _titles) {
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    if (_elementTitle) {
        equal = [_titles containsObject: (__bridge NSString *) _elementTitle];
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

inline bool dock_active() {
    bool active = false;
    AXUIElementRef _focusedUIElement = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focusedUIElement);
    if (_focusedUIElement) {
        active = true;
        CFRelease(_focusedUIElement);
    }
    return active;
}

inline bool mc_active() {
    bool active = false;
    CFArrayRef _children = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXChildrenAttribute, (CFTypeRef *) &_children);
    if (_children) {
        CFIndex count = CFArrayGetCount(_children);
        for (CFIndex i=0;!active && i != count;i++) {
            CFStringRef _element_role = NULL;
            AXUIElementRef _element = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            if (_element_role) {
                active = CFEqual(_element_role, kAXGroupRole) && titleEquals(_element, @[MissionControl]);
                CFRelease(_element_role);
            }
        }
        CFRelease(_children);
    }

    return active;
}

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }

        NSRect window_bounds = NSMakeRect(
            [window_bounds_dict[@"X"] intValue],
            [window_bounds_dict[@"Y"] intValue],
            [window_bounds_dict[@"Width"] intValue],
            [window_bounds_dict[@"Height"] intValue]);

        if (NSPointInRect(NSPointFromCGPoint(point), window_bounds)) {
            top_window = window;
            break;
        }
    }

    return top_window;
}

AXUIElementRef fallback(CGPoint point) {
    AXUIElementRef _window = NULL;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = NULL;
        pid_t pid = [top_window[(__bridge id) kCGWindowOwnerPID] intValue];
        AXUIElementRef _window_owner = AXUIElementCreateApplication(pid);
        AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(__bridge id) kCGWindowNumber] intValue];
            if (top_window_id) {
                for (id application_window in application_windows) {
                    CGWindowID application_window_id;
                    AXUIElementRef application_window_ax =
                        (__bridge AXUIElementRef) application_window;
                    if (_AXUIElementGetWindow(
                        application_window_ax,
                        &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == top_window_id) {
                            _window = application_window_ax;
                            CFRetain(_window);
                            break;
                        }
                    }
                }
            }
        } else {
            activate(pid);
        }
    }

    return _window;
}

AXUIElementRef get_raisable_window(AXUIElementRef _element, CGPoint point, int count) {
    AXUIElementRef _window = NULL;
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            CFRelease(_element);
        } else {
            CFStringRef _element_role = NULL;
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            bool check_attributes = !_element_role;
            if (_element_role) {
                if (CFEqual(_element_role, kAXDockItemRole) ||
                    CFEqual(_element_role, kAXMenuItemRole) ||
                    CFEqual(_element_role, kAXMenuRole) ||
                    CFEqual(_element_role, kAXMenuBarRole) ||
                    CFEqual(_element_role, kAXMenuBarItemRole)) {
                    CFRelease(_element_role);
                    CFRelease(_element);
                } else if (
                    CFEqual(_element_role, kAXWindowRole) ||
                    CFEqual(_element_role, kAXSheetRole) ||
                    CFEqual(_element_role, kAXDrawerRole)) {
                    CFRelease(_element_role);
                    _window = _element;
                } else if (CFEqual(_element_role, kAXApplicationRole)) {
                    CFRelease(_element_role);
                    if (titleEquals(_element, @[XQuartz])) {
                        pid_t application_pid;
                        if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                            pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                                frontmostApplication] processIdentifier];
                            if (application_pid != frontmost_pid) {
                                // Focus and/or raising is the responsibility of XQuartz.
                                // As such AutoRaise features (delay) do not apply.
                                activate(application_pid);
                            }
                        }
                        CFRelease(_element);
                    } else { check_attributes = true; }
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                bool no_parent = !_window;
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    if (!_window && no_parent) { _window = fallback(point); }
                }
                CFRelease(_element);
            }
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);

    AXUIElementRef _window = NULL;
    if (_element) {
        _window = get_raisable_window(_element, point, 0);
    } else if (error == kAXErrorCannotComplete || error == kAXErrorNotImplemented) {
        // fallback, happens for apps that do not support the Accessibility API
        _window = fallback(point);
    } else if (error == kAXErrorIllegalArgument) {
        // fallback, happens for Progressive Web Apps (PWAs)
        _window = fallback(point);
    } else if (error == kAXErrorNoValue) {
        // fallback, happens sometimes when switching to another app (with cmd-tab)
        _window = fallback(point);
    } else if (error == kAXErrorAPIDisabled) {
        // No fallback, and reported: every accessibility call fails from here on,
        // so AutoRaise does nothing at all. Rebuilding changes the ad hoc
        // signature, which can leave a stale Accessibility entry behind.
        static bool reported = false;
        if (!reported) {
            reported = true;
            NSLog(@"Accessibility permission is not working, AutoRaise can not do anything. "
                "If you rebuilt AutoRaise, remove it under System Settings > Privacy & "
                "Security > Accessibility and add it again.");
        }
    }
    // no fallback for kAXErrorAttributeUnsupported (volume/WiFi menubar window)
    // and kAXErrorFailure (the menubar itself)

    return _window;
}

inline bool windowPosition(AXUIElementRef _window, CGPoint * position) {
    bool found = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        found = AXValueGetValue(_pos, kAXValueTypeCGPoint, position);
        CFRelease(_pos);
    }

    return found;
}

inline bool windowSize(AXUIElementRef _window, CGSize * size) {
    bool found = false;
    AXValueRef _size = NULL;
    AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
    if (_size) {
        found = AXValueGetValue(_size, kAXValueTypeCGSize, size);
        CFRelease(_size);
    }

    return found;
}

bool contained_within(AXUIElementRef _window1, AXUIElementRef _window2) {
    bool contained = false;
    CGSize cg_size1;
    CGSize cg_size2;
    CGPoint cg_pos1;
    CGPoint cg_pos2;

    if (windowSize(_window1, &cg_size1) && windowPosition(_window1, &cg_pos1) &&
        windowSize(_window2, &cg_size2) && windowPosition(_window2, &cg_pos2)) {
        contained = cg_pos1.x > cg_pos2.x && cg_pos1.y > cg_pos2.y &&
            cg_pos1.x + cg_size1.width < cg_pos2.x + cg_size2.width &&
            cg_pos1.y + cg_size1.height < cg_pos2.y + cg_size2.height;
    }

    return contained;
}

void findDockApplication() {
    NSArray * _apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication * app in _apps) {
        if ([app.bundleIdentifier isEqual: DockBundleId]) {
            _dock_app = AXUIElementCreateApplication(app.processIdentifier);
            break;
        }
    }
}

// The accessibility API reports positions from the top left of the main screen with
// y growing downward, NSScreen frames start at their own bottom left with y growing
// upward. This is the top left corner of a screen in accessibility coordinates.
inline CGPoint screen_origin(NSScreen * screen) {
    return CGPointMake(NSMinX(screen.frame),
        NSMaxY(NSScreen.screens[0].frame) - NSMaxY(screen.frame));
}

inline NSScreen * findScreen(CGPoint point) {
    for (NSScreen * screen in [NSScreen screens]) {
        CGPoint origin = screen_origin(screen);
        NSRect screen_bounds = NSMakeRect(
            origin.x,
            origin.y,
            NSWidth(screen.frame),
            NSHeight(screen.frame)
        );
        if (NSPointInRect(NSPointFromCGPoint(point), screen_bounds)) {
            return screen;
        }
    }
    return NULL;
}

// Tiling window managers park windows of inactive workspaces almost fully
// offscreen, leaving only the few pixels macOS insists on. Raising such a sliver
// switches workspace and parks the previous window in its place, which without
// this check makes the two raise each other indefinitely.
#define MIN_VISIBLE 4
inline bool is_offscreen_window(AXUIElementRef _window, CGPoint point) {
    bool offscreen = false;
    NSScreen * screen = findScreen(point);
    CGSize cg_size;
    CGPoint cg_pos;
    if (screen && windowSize(_window, &cg_size) && windowPosition(_window, &cg_pos)) {
        CGPoint origin = screen_origin(screen);
        NSRect visible = NSIntersectionRect(
            NSMakeRect(origin.x, origin.y,
                NSWidth(screen.frame), NSHeight(screen.frame)),
            NSMakeRect(cg_pos.x, cg_pos.y, cg_size.width, cg_size.height));
        offscreen = NSWidth(visible) < MIN_VISIBLE || NSHeight(visible) < MIN_VISIBLE;
    }

    return offscreen;
}

inline bool is_full_screen(AXUIElementRef _window) {
    bool full_screen = false;
    CGPoint cg_pos;
    CGSize cg_size;
    if (windowPosition(_window, &cg_pos)) {
        NSScreen * screen = findScreen(cg_pos);
        if (screen && windowSize(_window, &cg_size)) {
            float menuBarHeight =
                fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
            CGPoint origin = screen_origin(screen);
            full_screen = cg_pos.x == origin.x &&
                          cg_pos.y == origin.y + menuBarHeight &&
                          cg_size.width == NSWidth(screen.frame) &&
                          cg_size.height == NSHeight(screen.frame) - menuBarHeight;
        }
    }

    return full_screen;
}

inline bool is_main_window(AXUIElementRef _app, AXUIElementRef _window, bool chrome_app) {
    bool main_window = false;
    CFBooleanRef _result = NULL;
    AXUIElementCopyAttributeValue(_window, kAXMainAttribute, (CFTypeRef *) &_result);
    if (_result) {
        main_window = CFEqual(_result, kCFBooleanTrue);
        if (main_window) {
            CFStringRef _element_sub_role = NULL;
            AXUIElementCopyAttributeValue(_window, kAXSubroleAttribute, (CFTypeRef *) &_element_sub_role);
            if (_element_sub_role) {
                main_window = !CFEqual(_element_sub_role, kAXDialogSubrole);
                CFRelease(_element_sub_role);
            }
        }
        CFRelease(_result);
    }

    bool finder_app = titleEquals(_app, @[Finder]);
    main_window = main_window && (chrome_app || finder_app ||
        !titleEquals(_window, @[NoTitle]) ||
        titleEquals(_app, mainWindowAppsWithoutTitle));

    main_window = main_window || (!finder_app && is_full_screen(_window));

    return main_window;
}

inline bool is_pwa(NSString * bundleIdentifier) {
    NSArray * components = [bundleIdentifier componentsSeparatedByString: @"."];
    bool pake = components.count == 3 && [components[1] isEqual: Pake];
    // browser channels (canary, beta, dev) insert one component before "app"
    return pake || (components.count > 4 && [pwas containsObject: components[2]] &&
        ([components[3] isEqual: @"app"] ||
        (components.count > 5 && [components[4] isEqual: @"app"])));
}

//-----------------------------------------------notifications----------------------------------------------

void spaceChanged();
void onTick();

@interface MDWorkspaceWatcher:NSObject {}
- (id)init;
@end

static MDWorkspaceWatcher * workspaceWatcher = NULL;

@implementation MDWorkspaceWatcher
- (id)init {
    if ((self = [super init])) {
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver: self
            selector: @selector(spaceChanged:)
            name: NSWorkspaceActiveSpaceDidChangeNotification
            object: nil];
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver: self];
}

- (void)spaceChanged:(NSNotification *)notification {
    spaceChanged();
}

- (void)onTick:(NSNumber *)timerInterval {
    [self performSelector: @selector(onTick:)
        withObject: timerInterval
        afterDelay: timerInterval.floatValue];
    onTick();
}
@end // MDWorkspaceWatcher

//------------------------------------------where it all happens--------------------------------------------

void spaceChanged() {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
}

void AXCallback(AXObserverRef observer, AXUIElementRef _element, CFStringRef notification, void * destroyedMouseWindow_id) {
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        lastDestroyedMouseWindow_id = (uint64_t) destroyedMouseWindow_id;
    }
}

void onTick() {
    // determine if mouseMoved
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    float mouse_x_diff = mousePoint.x-oldPoint.x;
    float mouse_y_diff = mousePoint.y-oldPoint.y;
    oldPoint = mousePoint;

    bool mouseStopped = mouse_x_diff == 0 && mouse_y_diff == 0;
    bool mouseMoved = !mouseStopped || propagateMouseMoved;
    propagateMouseMoved = false;

    // the correction should be applied before we return
    // under certain conditions in the code after it. This
    // ensures oldCorrectedPoint always has a recent value.
    if (mouseMoved) {
        NSScreen * screen = findScreen(mousePoint);
        mousePoint.x += mouse_x_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
        mousePoint.y += mouse_y_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
        if (screen) {
            CGPoint origin = screen_origin(screen);

            if (oldPoint.x > origin.x + NSWidth(screen.frame) - WINDOW_CORRECTION) {
                mousePoint.x = origin.x + NSWidth(screen.frame) - SCREEN_EDGE_CORRECTION;
            } else if (oldPoint.x < origin.x + WINDOW_CORRECTION - 1) {
                mousePoint.x = origin.x + SCREEN_EDGE_CORRECTION;
            }

            if (oldPoint.y > origin.y + NSHeight(screen.frame) - WINDOW_CORRECTION) {
                mousePoint.y = origin.y + NSHeight(screen.frame) - SCREEN_EDGE_CORRECTION;
            } else {
                float menuBarHeight = fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                if (mousePoint.y < origin.y + menuBarHeight + MENUBAR_CORRECTION) {
                    mousePoint.y = origin.y;
                }
            }
        }
        oldCorrectedPoint = mousePoint;
    } else {
        mousePoint = oldCorrectedPoint;
    }

    if (ignoreTimes) {
        ignoreTimes--;
        return;
    } else if (spaceHasChanged) {
        // spaceHasChanged has priority
        // over waiting for the mouse to stop
        if (mouseMoved) { return; }
        raiseTimes = 3;
        spaceHasChanged = false;
    } else if (!mouseStopped) {
        // propagate the mouseMoved event
        // to raise once the mouse stops
        propagateMouseMoved = true;
        return;
    }

    // mouseMoved: we have to decide if the window needs raising
    // raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || raiseTimes) {
        CGEventRef _keyDownEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventFlags flags = CGEventGetFlags(_keyDownEvent);
        if (_keyDownEvent) { CFRelease(_keyDownEvent); }

        // don't raise for as long as something is being dragged (resizing a window for instance)
        bool abort = (flags & DISABLE_KEY) == DISABLE_KEY ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
            dock_active() || mc_active();

        if (abort) {
            raiseTimes = 0;
            return;
        }

        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            pid_t mouseWindow_pid;
            if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
                CGWindowID mouseWindow_id;
                _AXUIElementGetWindow(_mouseWindow, &mouseWindow_id);
                // Watch the window under the mouse: once it is closed it must not be
                // raised again, or it never closes (macOS Tahoe and later)
                bool mouseWindowPresent = mouseWindow_id != lastDestroyedMouseWindow_id;
                if (mouseWindowPresent) {
                    static CGWindowID previous_id = kCGNullWindowID;
                    if (mouseWindow_id != previous_id) {
                        previous_id = mouseWindow_id;

                        lastDestroyedMouseWindow_id = kCGNullWindowID;
                        raiseTimes = 0;

                        if (axObserver) {
                            CFRelease(axObserver);
                            axObserver = NULL;
                        }

                        AXObserverCreate(
                            mouseWindow_pid,
                            AXCallback,
                            &axObserver
                        );

                        AXObserverAddNotification(
                            axObserver,
                            _mouseWindow,
                            kAXUIElementDestroyedNotification,
                            (void *) ((uint64_t) mouseWindow_id)
                        );

                        CFRunLoopAddSource(
                            CFRunLoopGetCurrent(),
                            AXObserverGetRunLoopSource(axObserver),
                            kCFRunLoopCommonModes
                        );
                    }
                }

                bool needs_raise = mouseWindowPresent;
                AXUIElementRef _mouseWindowApp = AXUIElementCreateApplication(mouseWindow_pid);
                if (needs_raise && titleEquals(_mouseWindow, @[NoTitle, Untitled])) {
                    needs_raise = is_main_window(_mouseWindowApp, _mouseWindow, is_pwa(
                        [NSRunningApplication runningApplicationWithProcessIdentifier:
                        mouseWindow_pid].bundleIdentifier));
                } else if (needs_raise && (
                    titleEquals(_mouseWindow, @[BartenderBar, Zim, AppStoreSearchResults]) ||
                    titleEquals(_mouseWindowApp, @[AssistiveControl]))) {
                    needs_raise = false;
                }
                CFRelease(_mouseWindowApp);
                if (needs_raise && is_offscreen_window(_mouseWindow, mousePoint)) {
                    needs_raise = false;
                }
                if (needs_raise) {
                    pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                        frontmostApplication] processIdentifier];
                    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
                    AXUIElementRef _focusedWindow = NULL;
                    AXUIElementCopyAttributeValue(
                        _frontmostApp,
                        kAXFocusedWindowAttribute,
                        (CFTypeRef *) &_focusedWindow);
                    if (_focusedWindow) {
                        CGWindowID focusedWindow_id;
                        _AXUIElementGetWindow(_focusedWindow, &focusedWindow_id);
                        needs_raise = mouseWindow_id != focusedWindow_id &&
                            !contained_within(_focusedWindow, _mouseWindow);
                        CFRelease(_focusedWindow);
                    } else {
                        AXUIElementRef _activatedWindow = NULL;
                        AXUIElementCopyAttributeValue(_frontmostApp,
                            kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
                        if (_activatedWindow) {
                          needs_raise = false;
                          CFRelease(_activatedWindow);
                        }
                    }
                    CFRelease(_frontmostApp);
                }

                if (needs_raise) {
                    if (raiseTimes) { raiseTimes--; }
                    else { raiseTimes = 3; }
                    raiseAndActivate(_mouseWindow, mouseWindow_pid);
                } else {
                    raiseTimes = 0;
                }
            }
            CFRelease(_mouseWindow);
        }
    }
}

CGEventRef eventTapHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    CGEventFlags flags = CGEventGetFlags(event);
    bool commandPressed = (flags & TASK_SWITCHER_MODIFIER_KEY) == TASK_SWITCHER_MODIFIER_KEY;

    // after cmd-tab, leave the activated app alone for a few ticks
    static bool commandTabPressed = false;
    if (!commandPressed && commandTabPressed) {
        commandTabPressed = false;
        ignoreTimes = 3;
    }

    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            commandTabPressed = commandTabPressed || commandPressed;
        }
    } else if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(eventTap, true);
    }

    return event;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);

        CFRunLoopSourceRef runLoopSource = NULL;
        eventTap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            CGEventMaskBit(kCGEventKeyDown) |
            CGEventMaskBit(kCGEventFlagsChanged),
            eventTapHandler,
            NULL
        );
        if (eventTap) {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }

        workspaceWatcher = [[MDWorkspaceWatcher alloc] init];
        [workspaceWatcher onTick: [NSNumber numberWithFloat: POLL_MILLIS/1000.0]];

        findDockApplication();
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
