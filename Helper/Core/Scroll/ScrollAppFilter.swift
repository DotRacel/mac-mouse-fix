//
// --------------------------------------------------------------------------
// ScrollAppFilter.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// 'App Exceptions' for scrolling – apps where we turn off smooth scrolling [Nov 2026]
///
/// Config (`Scroll.appExceptions`):
///     ( { bundleID = "com.foo.bar"; }, { path = "/path/to/executable"; } )
///         `path` is for apps without a bundleID (e.g. Minecraft Java Edition)
///
/// Behavior:
///     For these apps, `Scroll.m` lets the original scroll event through instead of synthesizing smooth scroll events.
///     -> The app gets native, discrete scroll wheel input at macOS speed. 'Reverse Direction' still applies (by inverting the original event).
///         Speed and keyboard modifiers don't apply, since they only work through the events we synthesize.
///     This is intended for apps that need native wheel input: remote desktops, VMs, iPhone Mirroring, 3D/CAD apps, games. See upstream issues #973, #2108, #1971.
///
/// Which app receives the scroll event?
///     We use the app owning the window under the mouse pointer, since that's where macOS sends scroll events, even when the window isn't frontmost.
///     We can't read `kCGMouseEventWindowUnderMousePointer` because we listen at `kCGHIDEventTap`, before the WindowServer routes the event.
///     The lookup is a bit slow, so we cache the decision while the user keeps scrolling without moving the pointer.

import Cocoa

@objc class ScrollAppFilter: NSObject {

    /// Parsed config
    private static var bundleIDs = Set<String>()
    private static var paths = Set<String>()

    /// Decision cache
    private static var cacheIsValid = false
    private static var cachedIsException = false
    private static var lastTickTime: CFTimeInterval = 0
    private static var lastLocation = CGPoint.zero

    /// If there's no scroll tick for this long, we look up the app again (Same as `consecutiveScrollTickIntervalMax`)
    private static let sessionTimeout: CFTimeInterval = 200.0/1000.0

    // MARK: Interface

    @objc static func reload() {

        /// Call this whenever the `Scroll` config changes

        assertRunLoop(configRunLoop())

        let apps = config("Scroll.appExceptions") as? [NSDictionary] ?? [] /// Optional – older configs don't have this key
        bundleIDs = Set(apps.compactMap { $0["bundleID"] as? String }.filter { !$0.isEmpty })
        paths     = Set(apps.compactMap { $0["path"] as? String }.filter { !$0.isEmpty })
        cacheIsValid = false

        DDLogInfo("ScrollAppFilter: reloaded - bundleIDs: \(bundleIDs), paths: \(paths)")
    }

    @objc static func isAppException(_ event: CGEvent, tickTime: CFTimeInterval) -> Bool {

        /// Returns true if the scroll event goes to an app where we shouldn't smooth scroll.

        assertRunLoop(IOThread.runLoop())

        /// Fast path
        guard !bundleIDs.isEmpty || !paths.isEmpty else { return false }

        /// Use cached decision while scrolling continuously at the same pointer location
        let location = event.location
        let isSameSession = cacheIsValid
                            && (tickTime - lastTickTime) < sessionTimeout
                            && location == lastLocation
        lastTickTime = tickTime
        lastLocation = location
        if isSameSession { return cachedIsException }

        /// Look up app
        let app = HelperUtility.appUnderMousePointer(with: event) ?? NSWorkspace.shared.frontmostApplication
        let isException = appIsListed(app)

        /// Log changes
        if !cacheIsValid || isException != cachedIsException {
            DDLogDebug("ScrollAppFilter: isException: \(isException) for app: \(app?.bundleIdentifier ?? app?.executableURL?.path ?? "nil")")
        }

        cachedIsException = isException
        cacheIsValid = true
        return isException
    }

    // MARK: Helpers

    private static func appIsListed(_ app: NSRunningApplication?) -> Bool {

        guard let app = app else { return false }

        if let bundleID = app.bundleIdentifier {
            if bundleIDs.contains(bundleID) { return true }
            /// Also match helper processes which own windows for the main app, like `com.valvesoftware.steam.helper` for `com.valvesoftware.steam`
            for listed in bundleIDs where bundleID.hasPrefix(listed + ".") { return true }
        }
        if let url = app.executableURL {
            if paths.contains(url.path) || paths.contains(url.resolvingSymlinksInPath().path) { return true }
        }
        return false
    }
}
