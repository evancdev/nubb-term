import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import NubbKit
import AppKit

protocol NubbAppDelegate: AnyObject {
    /// Called when a callback needs access to a specific surface. This should return nil
    /// when the surface is no longer valid.
    func findSurface(forUUID uuid: UUID) -> Nubb.SurfaceView?
}

extension Nubb {
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Optional delegate
        weak var delegate: NubbAppDelegate?

        /// The readiness value of the state.
        @Published var readiness: Readiness = .loading

        /// The global app configuration. This defines the app level configuration plus any behavior
        /// for new windows, tabs, etc. Note that when creating a new window, it may inherit some
        /// configuration (i.e. font size) from the previously focused window. This would override this.
        @Published private(set) var config: Config

        /// Preferred config file than the default ones
        private var configPath: String?
        /// The nubb app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        @Published var app: nubb_app_t? {
            didSet {
                guard let old = oldValue else { return }
                nubb_app_free(old)
            }
        }

        /// True if we need to confirm before quitting.
        var needsConfirmQuit: Bool {
            guard let app = app else { return false }
            return nubb_app_needs_confirm_quit(app)
        }

        init(configPath: String? = nil) {
            self.configPath = configPath
            // Initialize the global configuration.
            self.config = Config(at: configPath)
            if self.config.config == nil {
                readiness = .error
                return
            }

            // Create our "runtime" config. The "runtime" is the configuration that nubb
            // uses to interface with the application runtime environment.
            var runtime_cfg = nubb_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
                    App.readClipboard(
                        userdata,
                        location: loc,
                        state: state,
                        mimes: mimes,
                        mimesLen: mimesLen,
                        list: list) },
                confirm_read_clipboard_cb: { userdata, confirm, state, request in
                    App.confirmReadClipboard(
                        userdata,
                        confirm: confirm,
                        state: state,
                        request: request) },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            // Create the nubb app.
            guard let app = nubb_app_new(&runtime_cfg, config.config) else {
                logger.critical("nubb_app_new failed")
                readiness = .error
                return
            }
            self.app = app
            // Set our initial focus state
            nubb_app_set_focus(app, NSApp.isActive)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(notification:)),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive(notification:)),
                name: NSApplication.didResignActiveNotification,
                object: nil)
            self.readiness = .ready
        }

        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: App Operations

        func appTick() {
            guard let app = self.app else { return }
            nubb_app_tick(app)
        }

        private static func openConfig(_ app: nubb_app_t) {
            guard let app_ud = nubb_app_userdata(app) else { return }
            let app = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
            app.openConfig()
        }

        func openConfig() {
            let str = configPath ?? Nubb.AllocatedString(nubb_config_open_path()).string
            guard !str.isEmpty else { return }
            let fileURL = URL(fileURLWithPath: str).absoluteString
            var action = nubb_action_open_url_s()
            action.kind = NUBB_ACTION_OPEN_URL_KIND_TEXT
            fileURL.withCString { cStr in
                action.url = cStr
                action.len = UInt(fileURL.count)
                _ = App.openURL(action)
            }
        }

        /// Reload the configuration.
        func reloadConfig(soft: Bool = false) {
            guard let app = self.app else { return }

            // Soft updates just call with our existing config
            if soft {
                nubb_app_update_config(app, config.config!)
                return
            }

            // Hard or full updates have to reload the full configuration
            let newConfig = Config(at: configPath)
            guard newConfig.loaded else {
                Nubb.logger.warning("failed to reload configuration")
                return
            }

            nubb_app_update_config(app, newConfig.config!)
            /// applied config will be updated in ``Self.configChange(_:target:v:)``
        }

        func reloadConfig(surface: nubb_surface_t, soft: Bool = false) {
            // Soft updates just call with our existing config
            if soft {
                nubb_surface_update_config(surface, config.config!)
                return
            }

            // Hard or full updates have to reload the full configuration.
            // NOTE: We never set this on self.config because this is a surface-only
            // config. We free it after the call.
            let newConfig = Config(at: configPath)
            guard newConfig.loaded else {
                Nubb.logger.warning("failed to reload configuration")
                return
            }

            nubb_surface_update_config(surface, newConfig.config!)
        }

        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        func requestClose(surface: nubb_surface_t) {
            nubb_surface_request_close(surface)
        }

        func newTab(surface: nubb_surface_t) {
            let action = "new_tab"
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func newWindow(surface: nubb_surface_t) {
            let action = "new_window"
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func split(surface: nubb_surface_t, direction: nubb_action_split_direction_e) {
            nubb_surface_split(surface, direction)
        }

        func splitMoveFocus(surface: nubb_surface_t, direction: SplitFocusDirection) {
            nubb_surface_split_focus(surface, direction.toNative())
        }

        func splitResize(surface: nubb_surface_t, direction: SplitResizeDirection, amount: UInt16) {
            nubb_surface_split_resize(surface, direction.toNative(), amount)
        }

        func splitEqualize(surface: nubb_surface_t) {
            nubb_surface_split_equalize(surface)
        }

        func splitToggleZoom(surface: nubb_surface_t) {
            let action = "toggle_split_zoom"
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func toggleFullscreen(surface: nubb_surface_t) {
            let action = "toggle_fullscreen"
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        enum FontSizeModification {
            case increase(Int)
            case decrease(Int)
            case reset
        }

        func changeFontSize(surface: nubb_surface_t, _ change: FontSizeModification) {
            let action: String
            switch change {
            case .increase(let amount):
                action = "increase_font_size:\(amount)"
            case .decrease(let amount):
                action = "decrease_font_size:\(amount)"
            case .reset:
                action = "reset_font_size"
            }
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func toggleTerminalInspector(surface: nubb_surface_t) {
            let action = "inspector:toggle"
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        func resetTerminal(surface: nubb_surface_t) {
            let action = "reset"
            if !nubb_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify Nubb so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            nubb_app_keyboard_changed(app)
        }

        // Called when the app becomes active.
        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            nubb_app_set_focus(app, true)
        }

        // Called when the app becomes inactive.
        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            nubb_app_set_focus(app, false)
        }

        // MARK: Nubb Callbacks (macOS)

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            let surface = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Notification.nubbCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: nubb_clipboard_e,
            state: UnsafeMutableRawPointer?,
            mimes: UnsafePointer<UnsafePointer<CChar>?>?,
            mimesLen: Int,
            list: Bool
        ) -> nubb_clipboard_read_result_e {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else {
                return NUBB_CLIPBOARD_READ_UNSUPPORTED
            }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.nubb(location) else {
                return NUBB_CLIPBOARD_READ_UNSUPPORTED
            }

            // Gather the representation for each requested MIME type that
            // the pasteboard can serve. We only ever read the requested
            // representations so unrelated (potentially large) clipboard
            // contents are never loaded.
            var contents: [Nubb.ClipboardContent] = []
            var seen = Set<String>()
            if let mimes {
                for i in 0..<mimesLen {
                    guard let ptr = mimes[i] else { continue }
                    let mime = String(cString: ptr)
                    guard !seen.contains(mime) else { continue }
                    seen.insert(mime)
                    guard let data = pasteboard.nubbData(forMime: mime) else { continue }
                    contents.append(.init(mime: mime, data: data))
                }
            }

            // The listing of available types, only gathered when requested.
            let available: [String] = list ? pasteboard.nubbAvailableMimes() : []

            // With nothing to serve and no listing requested there is
            // nothing to complete the read with.
            if contents.isEmpty && !list {
                return NUBB_CLIPBOARD_READ_UNAVAILABLE
            }

            completeClipboardRequest(
                surface,
                contents: contents,
                available: available,
                state: state)
            return NUBB_CLIPBOARD_READ_STARTED
        }

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            confirm: UnsafePointer<nubb_clipboard_confirm_s>?,
            state: UnsafeMutableRawPointer?,
            request: nubb_clipboard_request_e
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }
            guard let confirm,
                  let kind = Nubb.ClipboardRequest.from(request: request) else {
                nubb_surface_deny_clipboard_request(surface, state)
                return
            }
            let c = confirm.pointee

            // Copy the borrowed C representations: the confirmation is
            // asynchronous and completes with exactly what the user
            // approved, so the clipboard is never re-read.
            var reps: [Nubb.ClipboardContent] = []
            if let contents = c.contents {
                for i in 0..<c.contents_len {
                    let content = contents[i]
                    let data: Data = if content.len > 0 {
                        Data(bytes: content.data, count: content.len)
                    } else {
                        Data()
                    }
                    reps.append(.init(mime: String(cString: content.mime), data: data))
                }
            }
            var avail: [String] = []
            if let available = c.available {
                for i in 0..<c.available_len {
                    guard let ptr = available[i] else { continue }
                    avail.append(String(cString: ptr))
                }
            }

            // The dialog can only display text: show the text
            // representation when there is one and summarize the rest.
            let display = reps.first(where: { $0.mime == "text/plain" })
                .flatMap { String(data: $0.data, encoding: .utf8) }
                ?? reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

            // Decode an image representation so the dialog can preview
            // exactly what would be disclosed rather than a byte count.
            let previewImage: NSImage? = reps.lazy
                .filter { $0.mime.hasPrefix("image/") }
                .compactMap { NSImage(data: $0.data) }
                .first

            // libnubb reaches this callback only when the request attempted
            // by readClipboard requires confirmation. Reads allowed by policy
            // complete immediately and never become pending Swift state.
            let request = Nubb.ClipboardConfirmationRequest(
                surface: surfaceView,
                contents: display,
                kind: kind,
                canRemember: c.can_remember,
                previewImage: previewImage
            ) { surfaceView, confirmed, remember in
                guard let surface = surfaceView.surface else { return }
                if confirmed {
                    completeClipboardRequest(
                        surface,
                        contents: reps,
                        available: avail,
                        state: state,
                        confirmed: true,
                        remember: remember)
                } else {
                    nubb_surface_deny_clipboard_request(surface, state)
                }
            }
            surfaceView.pendingClipboardConfirmation = request
        }

        private static func completeClipboardRequest(
            _ surface: nubb_surface_t,
            contents: [Nubb.ClipboardContent],
            available: [String],
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false,
            remember: Bool = false
        ) {
            // Copy everything into C memory for the duration of the call.
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            var cDatas: [UnsafeMutableRawPointer] = []
            defer {
                cStrings.forEach { free($0) }
                cDatas.forEach { $0.deallocate() }
            }

            var cContents: [nubb_clipboard_content_s] = []
            for entry in contents {
                guard let mime = strdup(entry.mime) else { continue }
                cStrings.append(mime)
                let buf = UnsafeMutableRawPointer.allocate(
                    byteCount: max(entry.data.count, 1),
                    alignment: 1)
                cDatas.append(buf)
                entry.data.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        buf.copyMemory(from: base, byteCount: src.count)
                    }
                }
                cContents.append(nubb_clipboard_content_s(
                    mime: mime,
                    data: buf.assumingMemoryBound(to: CChar.self),
                    len: entry.data.count))
            }

            var cAvailable: [UnsafePointer<CChar>?] = []
            for mime in available {
                guard let str = strdup(mime) else { continue }
                cStrings.append(str)
                cAvailable.append(UnsafePointer(str))
            }

            cContents.withUnsafeBufferPointer { contentsBuf in
                cAvailable.withUnsafeBufferPointer { availableBuf in
                    var complete = nubb_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availableBuf.baseAddress,
                        available_len: availableBuf.count,
                        confirmed: confirmed,
                        remember: remember)
                    nubb_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: nubb_clipboard_e,
            content: UnsafePointer<nubb_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let pasteboard = NSPasteboard.nubb(location) else { return }
            guard let content = content, len > 0 else { return }

            // Convert the C array to Swift array
            let contentArray = (0..<len).compactMap { i in
                Nubb.ClipboardContent.from(content: content[i])
            }
            guard !contentArray.isEmpty else { return }

            // Assert there is only one text/plain entry. For security reasons we need
            // to guarantee this for now since our confirmation dialog only shows one.
            assert(contentArray.filter({ $0.mime == "text/plain" }).count <= 1,
                   "clipboard contents should have at most one text/plain entry")

            if !confirm {
                // Apply writes allowed by policy immediately. Only writes that
                // require confirmation continue to the pending request below.
                let types = contentArray.compactMap { item in
                    NSPasteboard.PasteboardType(mimeType: item.mime)
                }
                pasteboard.declareTypes(types, owner: nil)

                // Set data for each type
                for item in contentArray {
                    guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                    pasteboard.setData(item.data, forType: type)
                }
                return
            }

            // For confirmation, use the text/plain content if it exists
            guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }),
                  let textPlainString = textPlainContent.string else {
                return
            }

            let request = Nubb.ClipboardConfirmationRequest(
                surface: surfaceView,
                contents: textPlainString,
                kind: .osc_52_write
            ) { _, confirmed, _ in
                guard confirmed else { return }
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(textPlainString, forType: .string)
            }
            surfaceView.pendingClipboardConfirmation = request
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread. There is probably some improvements we can make
            // to coalesce multiple ticks but I don't think it matters from a performance
            // standpoint since we don't do this much.
            DispatchQueue.main.async { state.appTick() }
        }

        /// Determine if a given notification should be presented to the user when Nubb is running in the foreground.
        func shouldPresentNotification(notification: UNNotification) -> Bool {
            let userInfo = notification.request.content.userInfo

            // We always require the notification to be attached to a surface.
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = delegate?.findSurface(forUUID: uuid),
                  let window = surface.window else { return false }

            // If we don't require focus then we're good!
            let requireFocus = userInfo["requireFocus"] as? Bool ?? true
            if !requireFocus { return true }

            return !window.isKeyWindow || !surface.focused
        }

        /// Returns the NubbState from the given userdata value.
        static private func appState(fromView view: SurfaceView) -> App? {
            guard let surface = view.surface else { return nil }
            guard let app = nubb_surface_app(surface) else { return nil }
            guard let app_ud = nubb_app_userdata(app) else { return nil }
            return Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }

        static private func surfaceView(from surface: nubb_surface_t) -> SurfaceView? {
            guard let surface_ud = nubb_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
        }

        // MARK: Actions (macOS)

        static func action(_ app: nubb_app_t, target: nubb_target_s, action: nubb_action_s) -> Bool {
            // Make sure it a target we understand so all our action handlers can assert
            switch target.tag {
            case NUBB_TARGET_APP, NUBB_TARGET_SURFACE:
                break

            default:
                Nubb.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
                return false
            }

            // Action dispatch
            switch action.tag {
            case NUBB_ACTION_QUIT:
                quit(app)

            case NUBB_ACTION_NEW_WINDOW:
                newWindow(app, target: target)

            case NUBB_ACTION_NEW_TAB:
                newTab(app, target: target)

            case NUBB_ACTION_NEW_SPLIT:
                newSplit(app, target: target, direction: action.action.new_split)

            case NUBB_ACTION_CLOSE_TAB:
                closeTab(app, target: target, mode: action.action.close_tab_mode)

            case NUBB_ACTION_CLOSE_WINDOW:
                closeWindow(app, target: target)

            case NUBB_ACTION_TOGGLE_FULLSCREEN:
                toggleFullscreen(app, target: target, mode: action.action.toggle_fullscreen)

            case NUBB_ACTION_MOVE_TAB:
                return moveTab(app, target: target, move: action.action.move_tab)

            case NUBB_ACTION_MOVE_TAB_TO_NEW_WINDOW:
                return moveTabToNewWindow(app, target: target)

            case NUBB_ACTION_GOTO_TAB:
                return gotoTab(app, target: target, tab: action.action.goto_tab)

            case NUBB_ACTION_GOTO_SPLIT:
                return gotoSplit(app, target: target, direction: action.action.goto_split)

            case NUBB_ACTION_GOTO_WINDOW:
                return gotoWindow(app, target: target, direction: action.action.goto_window)

            case NUBB_ACTION_RESIZE_SPLIT:
                return resizeSplit(app, target: target, resize: action.action.resize_split)

            case NUBB_ACTION_EQUALIZE_SPLITS:
                equalizeSplits(app, target: target)

            case NUBB_ACTION_TOGGLE_SPLIT_ZOOM:
                return toggleSplitZoom(app, target: target)

            case NUBB_ACTION_INSPECTOR:
                controlInspector(app, target: target, mode: action.action.inspector)

            case NUBB_ACTION_RENDER_INSPECTOR:
                renderInspector(app, target: target)

            case NUBB_ACTION_EXPORT_TERMINAL_IO:
                return exportTerminalIO(app, target: target, v: action.action.export_terminal_io)

            case NUBB_ACTION_DESKTOP_NOTIFICATION:
                showDesktopNotification(app, target: target, n: action.action.desktop_notification)

            case NUBB_ACTION_SET_TITLE:
                setTitle(app, target: target, v: action.action.set_title)

            case NUBB_ACTION_SET_TAB_TITLE:
                return setTabTitle(app, target: target, v: action.action.set_tab_title)

            case NUBB_ACTION_PROMPT_TITLE:
                return promptTitle(app, target: target, v: action.action.prompt_title)

            case NUBB_ACTION_PWD:
                pwdChanged(app, target: target, v: action.action.pwd)

            case NUBB_ACTION_OPEN_CONFIG:
                openConfig(app)

            case NUBB_ACTION_FLOAT_WINDOW:
                toggleFloatWindow(app, target: target, mode: action.action.float_window)

            case NUBB_ACTION_SECURE_INPUT:
                toggleSecureInput(app, target: target, mode: action.action.secure_input)

            case NUBB_ACTION_MOUSE_SHAPE:
                setMouseShape(app, target: target, shape: action.action.mouse_shape)

            case NUBB_ACTION_MOUSE_VISIBILITY:
                setMouseVisibility(app, target: target, v: action.action.mouse_visibility)

            case NUBB_ACTION_MOUSE_OVER_LINK:
                setMouseOverLink(app, target: target, v: action.action.mouse_over_link)

            case NUBB_ACTION_INITIAL_SIZE:
                setInitialSize(app, target: target, v: action.action.initial_size)

            case NUBB_ACTION_RESET_WINDOW_SIZE:
                resetWindowSize(app, target: target)

            case NUBB_ACTION_RESIZE_WINDOW:
                return resizeWindow(app, target: target, v: action.action.resize_window)

            case NUBB_ACTION_CELL_SIZE:
                setCellSize(app, target: target, v: action.action.cell_size)

            case NUBB_ACTION_RENDERER_HEALTH:
                rendererHealth(app, target: target, v: action.action.renderer_health)

            case NUBB_ACTION_TOGGLE_COMMAND_PALETTE:
                toggleCommandPalette(app, target: target)

            case NUBB_ACTION_TOGGLE_MAXIMIZE:
                toggleMaximize(app, target: target)

            case NUBB_ACTION_TOGGLE_QUICK_TERMINAL:
                toggleQuickTerminal(app, target: target)

            case NUBB_ACTION_TOGGLE_VISIBILITY:
                toggleVisibility(app, target: target)

            case NUBB_ACTION_TOGGLE_BACKGROUND_OPACITY:
                toggleBackgroundOpacity(app, target: target)

            case NUBB_ACTION_KEY_SEQUENCE:
                keySequence(app, target: target, v: action.action.key_sequence)

            case NUBB_ACTION_KEY_TABLE:
                keyTable(app, target: target, v: action.action.key_table)

            case NUBB_ACTION_PROGRESS_REPORT:
                progressReport(app, target: target, v: action.action.progress_report)

            case NUBB_ACTION_CONFIG_CHANGE:
                configChange(app, target: target, v: action.action.config_change)

            case NUBB_ACTION_RELOAD_CONFIG:
                configReload(app, target: target, v: action.action.reload_config)

            case NUBB_ACTION_COLOR_CHANGE:
                colorChange(app, target: target, change: action.action.color_change)

            case NUBB_ACTION_RING_BELL:
                ringBell(app, target: target)

            case NUBB_ACTION_SELECTION_CHANGED:
                selectionChanged(app, target: target)

            case NUBB_ACTION_READONLY:
                setReadonly(app, target: target, v: action.action.readonly)

            case NUBB_ACTION_OPEN_URL:
                return openURL(action.action.open_url)

            case NUBB_ACTION_UNDO:
                return undo(app, target: target)

            case NUBB_ACTION_REDO:
                return redo(app, target: target)

            case NUBB_ACTION_SCROLLBAR:
                scrollbar(app, target: target, v: action.action.scrollbar)

            case NUBB_ACTION_CLOSE_ALL_WINDOWS:
                closeAllWindows(app, target: target)

            case NUBB_ACTION_START_SEARCH:
                startSearch(app, target: target, v: action.action.start_search)

            case NUBB_ACTION_END_SEARCH:
                return endSearch(app, target: target)

            case NUBB_ACTION_SEARCH_TOTAL:
                searchTotal(app, target: target, v: action.action.search_total)

            case NUBB_ACTION_SEARCH_SELECTED:
                searchSelected(app, target: target, v: action.action.search_selected)

            case NUBB_ACTION_COMMAND_FINISHED:
                commandFinished(app, target: target, v: action.action.command_finished)

            case NUBB_ACTION_PRESENT_TERMINAL:
                return presentTerminal(app, target: target)

            case NUBB_ACTION_SHOW_CHILD_EXITED:
                return showChildExited(app, target: target, v: action.action.child_exited)

            case NUBB_ACTION_COPY_TITLE_TO_CLIPBOARD:
                return copyTitleToClipboard(app, target: target)

            default:
                Nubb.logger.warning("unknown action action=\(action.tag.rawValue, privacy: .public)")
                return false
            }

            // If we reached here then we assume performed since all unknown actions
            // are captured in the switch and return false.
            return true
        }

        private static func quit(_ app: nubb_app_t) {
            // We want to quit, start that process
            NSApplication.shared.terminate(nil)
        }

        private static func openURL(
            _ v: nubb_action_open_url_s
        ) -> Bool {
            let action = Nubb.Action.OpenURL(c: v)

            // OSC 8 targets are producer-controlled terminal output. Keep them
            // out of the unrestricted generic opener so unsafe local files and
            // deceptive targets cannot reach Launch Services directly.
            if action.kind == .osc8 {
                return openUntrustedURL(action.url)
            }

            // If the URL doesn't have a valid scheme we assume its a file path. The URL
            // initializer will gladly take invalid URLs (e.g. plain file paths) and turn
            // them into schema-less URLs, but these won't open properly in text editors.
            // See: https://github.com/ghostty-org/ghostty/issues/8763
            let url: URL
            if let candidate = URL(string: action.url), candidate.scheme != nil {
                url = candidate
            } else {
                // Expand ~ to the user's home directory so that file paths
                // like ~/Documents/file.txt resolve correctly.
                let expandedPath = NSString(string: action.url).standardizingPath
                url = URL(filePath: expandedPath)
            }

            // Unknown URLs are as untrusted as OSC 8 but may be plain paths,
            // which UntrustedURL rejects, so check the file URL built above.
            // Values with unsafe characters are passed unchanged so they are
            // rejected before percent-encoding hides them.
            if action.kind == .unknown {
                let hasScheme = URL(string: action.url)?.scheme != nil
                let target = hasScheme || UntrustedURL.containsUnsafeCharacters(action.url)
                    ? action.url
                    : url.absoluteString
                return openUntrustedURL(target)
            }

            switch action.kind {
            case .text:
                // Open with the default editor for `*.ghostty` file or just system text editor
                let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension) ?? NSWorkspace.shared.defaultTextEditor
                if let textEditor = editor {
                    NSWorkspace.shared.open([url], withApplicationAt: textEditor, configuration: NSWorkspace.OpenConfiguration())
                    return true
                }

            case .html:
                // The extension will be HTML and we do the right thing automatically.
                break

            case .osc8, .unknown:
                assertionFailure("Untrusted URLs must use the safe-opening policy")
                return true
            }

            // Open with the default application for the URL
            NSWorkspace.shared.open(url)
            return true
        }

        private static func openUntrustedURL(_ value: String) -> Bool {
            let target = UntrustedURL(value)
            switch target.decision {
            case .allow(let url):
                _ = NSWorkspace.shared.open(url)

            case .confirm(let url):
                UntrustedURLAlert.presentConfirmation(
                    for: url,
                    displayString: target.displayString
                )

            case .deny(let reason):
                UntrustedURLAlert.presentBlock(
                    reason: reason,
                    displayString: target.displayString
                )
            }

            // Always report OSC 8 actions as handled. Returning false would
            // cause the core to retry with the unrestricted fallback opener.
            return true
        }

        private static func undo(_ app: nubb_app_t, target: nubb_target_s) -> Bool {
            let undoManager: UndoManager?
            switch target.tag {
            case NUBB_TARGET_APP:
                undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                undoManager = surfaceView.undoManager

            default:
                assertionFailure()
                return false
            }

            guard let undoManager, undoManager.canUndo else { return false }
            undoManager.undo()
            return true
        }

        private static func redo(_ app: nubb_app_t, target: nubb_target_s) -> Bool {
            let undoManager: UndoManager?
            switch target.tag {
            case NUBB_TARGET_APP:
                undoManager = (NSApp.delegate as? AppDelegate)?.undoManager

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                undoManager = surfaceView.undoManager

            default:
                assertionFailure()
                return false
            }

            guard let undoManager, undoManager.canRedo else { return false }
            undoManager.redo()
            return true
        }

        private static func newWindow(_ app: nubb_app_t, target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                NotificationCenter.default.post(
                    name: Notification.nubbNewWindow,
                    object: nil,
                    userInfo: [:]
                )

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.nubbNewWindow,
                    object: surfaceView,
                    userInfo: [
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: nubb_surface_inherited_config(surface, NUBB_SURFACE_CONTEXT_WINDOW)),
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func newTab(_ app: nubb_app_t, target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                NotificationCenter.default.post(
                    name: Notification.nubbNewTab,
                    object: nil,
                    userInfo: [:]
                )

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let appState = self.appState(fromView: surfaceView) else { return }
                guard appState.config.windowDecorations else {
                    let alert = NSAlert()
                    alert.messageText = "Tabs are disabled"
                    alert.informativeText = "Enable window decorations to use tabs"
                    alert.addButton(withTitle: "OK")
                    alert.alertStyle = .warning
                    _ = alert.runModal()
                    return
                }

                NotificationCenter.default.post(
                    name: Notification.nubbNewTab,
                    object: surfaceView,
                    userInfo: [
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: nubb_surface_inherited_config(surface, NUBB_SURFACE_CONTEXT_TAB)),
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func newSplit(
            _ app: nubb_app_t,
            target: nubb_target_s,
            direction: nubb_action_split_direction_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                // New split does nothing with an app target
                Nubb.logger.warning("new split does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: Notification.nubbNewSplit,
                    object: surfaceView,
                    userInfo: [
                        "direction": direction,
                        Notification.NewSurfaceConfigKey: SurfaceConfiguration(from: nubb_surface_inherited_config(surface, NUBB_SURFACE_CONTEXT_SPLIT)),
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func presentTerminal(
            _ app: nubb_app_t,
            target: nubb_target_s
        ) -> Bool {
            switch target.tag {
            case NUBB_TARGET_APP:
                return false

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                NotificationCenter.default.post(
                    name: Notification.nubbPresentTerminal,
                    object: surfaceView
                )
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func closeTab(_ app: nubb_app_t, target: nubb_target_s, mode: nubb_action_close_tab_mode_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("close tabs does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                switch mode {
                case NUBB_ACTION_CLOSE_TAB_MODE_THIS:
                    NotificationCenter.default.post(
                        name: .nubbCloseTab,
                        object: surfaceView
                    )
                    return

                case NUBB_ACTION_CLOSE_TAB_MODE_OTHER:
                    NotificationCenter.default.post(
                        name: .nubbCloseOtherTabs,
                        object: surfaceView
                    )
                    return

                case NUBB_ACTION_CLOSE_TAB_MODE_RIGHT:
                    NotificationCenter.default.post(
                        name: .nubbCloseTabsOnTheRight,
                        object: surfaceView
                    )
                    return

                default:
                    assertionFailure()
                }

            default:
                assertionFailure()
            }
        }

        private static func closeWindow(_ app: nubb_app_t, target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("close window does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: .nubbCloseWindow,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func closeAllWindows(_ app: nubb_app_t, target: nubb_target_s) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.closeAllWindows(nil)
        }

        private static func toggleFullscreen(
            _ app: nubb_app_t,
            target: nubb_target_s,
            mode raw: nubb_action_fullscreen_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle fullscreen does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let mode = FullscreenMode.from(nubb: raw) else {
                    Nubb.logger.warning("unknown fullscreen mode raw=\(raw.rawValue, privacy: .public)")
                    return
                }
                NotificationCenter.default.post(
                    name: Notification.nubbToggleFullscreen,
                    object: surfaceView,
                    userInfo: [
                        Notification.FullscreenModeKey: mode,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleCommandPalette(
            _ app: nubb_app_t,
            target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle command palette does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .nubbCommandPaletteDidToggle,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleMaximize(
            _ app: nubb_app_t,
            target: nubb_target_s
        ) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle maximize does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .nubbMaximizeDidToggle,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleVisibility(
            _ app: nubb_app_t,
            target: nubb_target_s
        ) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.toggleVisibility(self)
        }

        private static func ringBell(
            _ app: nubb_app_t,
            target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                // Technically we could still request app attention here but there
                // are no known cases where the bell is rang with an app target so
                // I think its better to warn.
                Nubb.logger.warning("ring bell does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .nubbBellDidRing,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func selectionChanged(
            _ app: nubb_app_t,
            target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("selection changed does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .nubbSelectionDidChange,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func setReadonly(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_readonly_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("set readonly does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .nubbDidChangeReadonly,
                    object: surfaceView,
                    userInfo: [
                        SwiftUI.Notification.Name.ReadonlyKey: v == NUBB_READONLY_ON,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func moveTab(
            _ app: nubb_app_t,
            target: nubb_target_s,
            move: nubb_action_move_tab_s) -> Bool {
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("move tab does nothing with an app target")
                    return false

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // See gotoTab for notes on this check.
                    guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    NotificationCenter.default.post(
                        name: .nubbMoveTab,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.NubbMoveTabKey: Action.MoveTab(c: move),
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func moveTabToNewWindow(
            _ app: nubb_app_t,
            target: nubb_target_s) -> Bool {
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("move tab to new window does nothing with an app target")
                    return false

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // See gotoTab for notes on this check. A lone tab is already
                    // a window of its own, so there is nothing to move.
                    guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    surfaceView.window?.moveTabToNewWindow(nil)

                default:
                    assertionFailure()
                }

                return true
        }

        private static func gotoTab(
            _ app: nubb_app_t,
            target: nubb_target_s,
            tab: nubb_action_goto_tab_e) -> Bool {
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("goto tab does nothing with an app target")
                    return false

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }

                    // Similar to goto_split (see comment there) about our performability,
                    // we should make this more accurate later.
                    guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }

                    NotificationCenter.default.post(
                        name: Notification.nubbGotoTab,
                        object: surfaceView,
                        userInfo: [
                            Notification.GotoTabKey: tab,
                        ]
                    )

                default:
                    assertionFailure()
                }

                return true
        }

        private static func gotoSplit(
            _ app: nubb_app_t,
            target: nubb_target_s,
            direction: nubb_action_goto_split_e) -> Bool {
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("goto split does nothing with an app target")
                    return false

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let controller = surfaceView.window?.windowController as? BaseTerminalController else { return false }

                    // If the window has no splits, the action is not performable
                    guard controller.surfaceTree.isSplit else { return false }

                    // Convert the C API direction to our Swift type
                    guard let splitDirection = SplitFocusDirection.from(direction: direction) else { return false }

                    // Find the current node in the tree
                    guard let targetNode = controller.surfaceTree.root?.node(view: surfaceView) else { return false }

                    // Check if a split actually exists in the target direction before
                    // returning true. This ensures performable keybinds only consume
                    // the key event when we actually perform navigation.
                    let focusDirection: SplitTree<Nubb.SurfaceView>.FocusDirection = splitDirection.toSplitTreeFocusDirection()
                    guard controller.surfaceTree.focusTarget(for: focusDirection, from: targetNode) != nil else {
                        return false
                    }

                    // We have a valid target, post the notification to perform the navigation
                    NotificationCenter.default.post(
                        name: Notification.nubbFocusSplit,
                        object: surfaceView,
                        userInfo: [
                            Notification.SplitDirectionKey: splitDirection as Any,
                        ]
                    )

                    return true

                default:
                    assertionFailure()
                    return false
                }
        }

        private static func gotoWindow(
            _ app: nubb_app_t,
            target: nubb_target_s,
            direction: nubb_action_goto_window_e
        ) -> Bool {
            // Collect candidate windows: visible terminal windows that are either
            // standalone or the currently selected tab in their tab group. This
            // treats each native tab group as a single "window" for navigation
            // purposes, since goto_tab handles per-tab navigation.
            let candidates: [NSWindow] = NSApplication.shared.windows.filter { window in
                guard window.windowController is BaseTerminalController else { return false }
                guard window.isVisible, !window.isMiniaturized else { return false }
                // For native tabs, only include the selected tab in each group
                if let group = window.tabGroup, group.selectedWindow !== window {
                    return false
                }
                return true
            }

            // Need at least two windows to navigate between
            guard candidates.count > 1 else { return false }

            // Find starting index from the current key/main window
            let startIndex = candidates.firstIndex(where: { $0.isKeyWindow })
                ?? candidates.firstIndex(where: { $0.isMainWindow })
                ?? 0

            let step: Int
            switch direction {
            case NUBB_GOTO_WINDOW_NEXT:
                step = 1
            case NUBB_GOTO_WINDOW_PREVIOUS:
                step = -1
            default:
                return false
            }

            // Iterate with wrap-around until we find a valid window or return to start
            let count = candidates.count
            var index = (startIndex + step + count) % count

            while index != startIndex {
                let candidate = candidates[index]
                if candidate.isVisible, !candidate.isMiniaturized {
                    candidate.makeKeyAndOrderFront(nil)
                    // Also focus the terminal surface within the window
                    if let controller = candidate.windowController as? BaseTerminalController,
                       let surface = controller.focusedSurface {
                        Nubb.moveFocus(to: surface)
                    }
                    return true
                }
                index = (index + step + count) % count
            }

            return false
        }

        private static func resizeSplit(
            _ app: nubb_app_t,
            target: nubb_target_s,
            resize: nubb_action_resize_split_s) -> Bool {
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("resize split does nothing with an app target")
                    return false

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let controller = surfaceView.window?.windowController as? BaseTerminalController else { return false }

                    // If the window has no splits, the action is not performable
                    guard controller.surfaceTree.isSplit else { return false }

                    guard let resizeDirection = SplitResizeDirection.from(direction: resize.direction) else { return false }
                    NotificationCenter.default.post(
                        name: Notification.didResizeSplit,
                        object: surfaceView,
                        userInfo: [
                            Notification.ResizeSplitDirectionKey: resizeDirection,
                            Notification.ResizeSplitAmountKey: resize.amount,
                        ]
                    )
                    return true

                default:
                    assertionFailure()
                    return false
                }
        }

        private static func equalizeSplits(
            _ app: nubb_app_t,
            target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("equalize splits does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didEqualizeSplits,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func toggleSplitZoom(
            _ app: nubb_app_t,
            target: nubb_target_s) -> Bool {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle split zoom does nothing with an app target")
                return false

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.window?.windowController as? BaseTerminalController else { return false }

                // If the window has no splits, the action is not performable
                guard controller.surfaceTree.isSplit else { return false }

                NotificationCenter.default.post(
                    name: Notification.didToggleSplitZoom,
                    object: surfaceView
                )
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func controlInspector(
            _ app: nubb_app_t,
            target: nubb_target_s,
            mode: nubb_action_inspector_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle inspector does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didControlInspector,
                    object: surfaceView,
                    userInfo: ["mode": mode]
                )

            default:
                assertionFailure()
            }
        }

        private static func exportTerminalIO(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_export_terminal_io_s
        ) -> Bool {
            guard target.tag == NUBB_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface),
                  let window = surfaceView.window,
                  let contents = v.contents
            else { return false }

            // The action data is borrowed for the duration of this callback,
            // so copy it before presenting the asynchronous save panel.
            let data = Data(bytes: contents, count: v.len)
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = "nubb-terminal-io.txt"
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    do {
                        try data.write(to: url, options: .atomic)
                    } catch {
                        Nubb.logger.error(
                            "Failed to export terminal IO events: \(error, privacy: .public)"
                        )
                    }
                }
            }

            return true
        }

        private static func showDesktopNotification(
            _ app: nubb_app_t,
            target: nubb_target_s,
            n: nubb_action_desktop_notification_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("desktop notification does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: n.title!, encoding: .utf8) else { return }
                guard let body = String(cString: n.body!, encoding: .utf8) else { return }
                showDesktopNotification(surfaceView, title: title, body: body)

            default:
                assertionFailure()
            }
        }

        private static func showDesktopNotification(
            _ surfaceView: SurfaceView,
            title: String,
            body: String,
            requireFocus: Bool = true) {
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error = error {
                    Nubb.logger.error("Error while requesting notification authorization: \(error, privacy: .public)")
                }
            }

            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else { return }
                surfaceView.showUserNotification(
                    title: title,
                    body: body,
                    requireFocus: requireFocus
                )
            }
        }

        private static func commandFinished(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_command_finished_s
        ) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("command finished does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                // Determine if we even care about command finish notifications
                guard let config = (NSApplication.shared.delegate as? AppDelegate)?.nubb.config else { return }
                switch config.notifyOnCommandFinish {
                case .never:
                    return

                case .unfocused:
                    if surfaceView.focused { return }

                case .always:
                    break
                }

                // Determine if the command was slow enough
                let duration = Duration.nanoseconds(v.duration)
                guard Duration.nanoseconds(v.duration) >= config.notifyOnCommandFinishAfter else { return }

                let actions = config.notifyOnCommandFinishAction

                if actions.contains(.bell) {
                    NotificationCenter.default.post(
                        name: .nubbBellDidRing,
                        object: surfaceView
                    )
                }

                if actions.contains(.notify) {
                    let title: String
                    if v.exit_code < 0 {
                        title = "Command Finished"
                    } else if v.exit_code == 0 {
                        title = "Command Succeeded"
                    } else {
                        title = "Command Failed"
                    }

                    let body: String
                    let formattedDuration = duration.formatted(
                        .units(
                            allowed: [.hours, .minutes, .seconds, .milliseconds],
                            width: .abbreviated,
                            fractionalPart: .hide
                        )
                    )
                    if v.exit_code < 0 {
                        body = "Command took \(formattedDuration)."
                    } else {
                        body = "Command took \(formattedDuration) and exited with code \(v.exit_code)."
                    }

                    showDesktopNotification(
                        surfaceView,
                        title: title,
                        body: body,
                        requireFocus: false
                    )
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleFloatWindow(
            _ app: nubb_app_t,
            target: nubb_target_s,
            mode mode_raw: nubb_action_float_window_e
        ) {
            guard let mode = SetFloatWIndow.from(mode_raw) else { return }

            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle float window does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let window = surfaceView.window as? TerminalWindow else { return }

                switch mode {
                case .on:
                    window.level = .floating

                case .off:
                    window.level = .normal

                case .toggle:
                    window.level = window.level == .floating ? .normal : .floating
                }

                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.syncFloatOnTopMenu(window)
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleBackgroundOpacity(
            _ app: nubb_app_t,
            target: nubb_target_s
        ) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("toggle background opacity does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface,
                    let surfaceView = self.surfaceView(from: surface),
                    let controller = surfaceView.window?.windowController as? BaseTerminalController else { return }

                controller.toggleBackgroundOpacity()

            default:
                assertionFailure()
            }
        }

        private static func toggleSecureInput(
            _ app: nubb_app_t,
            target: nubb_target_s,
            mode mode_raw: nubb_action_secure_input_e
        ) {
            guard let mode = SetSecureInput.from(mode_raw) else { return }

            switch target.tag {
            case NUBB_TARGET_APP:
                guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
                appDelegate.setSecureInput(mode)

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let appState = self.appState(fromView: surfaceView) else { return }
                guard appState.config.autoSecureInput else { return }

                switch mode {
                case .on:
                    surfaceView.passwordInput = true

                case .off:
                    surfaceView.passwordInput = false

                case .toggle:
                    surfaceView.passwordInput = !surfaceView.passwordInput
                }

            default:
                assertionFailure()
            }
        }

        private static func toggleQuickTerminal(
            _ app: nubb_app_t,
            target: nubb_target_s
        ) {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
            appDelegate.toggleQuickTerminal(self)
        }

        private static func setTitle(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_set_title_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("set title does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: v.title!, encoding: .utf8) else { return }
                surfaceView.setTitle(title)

            default:
                assertionFailure()
            }
        }

        private static func setTabTitle(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_set_title_s
        ) -> Bool {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("set tab title does nothing with an app target")
                return false

            case NUBB_TARGET_SURFACE:
                guard let title = String(cString: v.title!, encoding: .utf8) else { return false }
                let titleOverride = title.isEmpty ? nil : title
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let window = surfaceView.window,
                      let controller = window.windowController as? BaseTerminalController
                else { return false }
                controller.titleOverride = titleOverride
                return true

            default:
                assertionFailure()
                return false
            }
        }

        private static func showChildExited(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_surface_message_childexited_s,
        ) -> Bool {
            switch target.tag {
            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                // We handle this when the window is visible and timetime_ms is greater than 0,
                // which will rule out exit codes on launch
                guard surfaceView.window != nil, v.timetime_ms > 0 else { return false }
                guard let config = (NSApplication.shared.delegate as? AppDelegate)?.nubb.config else { return false }
                surfaceView.setChildExitedMessage(.init(v, threshold: config.abnormalCommandExitRuntime))
                return true
            default:
                return false
            }
        }

        private static func copyTitleToClipboard(
            _ app: nubb_app_t,
            target: nubb_target_s) -> Bool {
            switch target.tag {
            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                let title = surfaceView.title
                if title.isEmpty { return false }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(title, forType: .string)
                return true

            default:
                return false
            }
        }

        private static func promptTitle(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_prompt_title_e) -> Bool {
            let promptTitle = Action.PromptTitle(v)
            switch promptTitle {
            case .surface:
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("set title prompt does nothing with an app target")
                    return false

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    surfaceView.promptTitle()
                    return true

                default:
                    assertionFailure()
                    return false
                }

            case .tab:
                switch target.tag {
                case NUBB_TARGET_APP:
                    guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
                          let controller = window.windowController as? BaseTerminalController
                    else { return false }
                    controller.promptTabTitle()
                    return true

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return false }
                    guard let surfaceView = self.surfaceView(from: surface) else { return false }
                    guard let window = surfaceView.window,
                          let controller = window.windowController as? BaseTerminalController
                    else { return false }
                    controller.promptTabTitle()
                    return true

                default:
                    assertionFailure()
                    return false
                }
            }
        }

        private static func pwdChanged(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_pwd_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("pwd change does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let pwd = String(cString: v.pwd!, encoding: .utf8) else { return }
                surfaceView.pwd = pwd

            default:
                assertionFailure()
            }
        }

        private static func setMouseShape(
            _ app: nubb_app_t,
            target: nubb_target_s,
            shape: nubb_action_mouse_shape_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("set mouse shapes nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.setCursorShape(shape)

            default:
                assertionFailure()
            }
        }

        private static func setMouseVisibility(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_mouse_visibility_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("set mouse shapes nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                switch v {
                case NUBB_MOUSE_VISIBLE:
                    surfaceView.setCursorVisibility(true)

                case NUBB_MOUSE_HIDDEN:
                    surfaceView.setCursorVisibility(false)

                default:
                    return
                }

            default:
                assertionFailure()
            }
        }

        private static func setMouseOverLink(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_mouse_over_link_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("mouse over link does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard v.len > 0 else {
                    surfaceView.hoverUrl = nil
                    return
                }

                let buffer = Data(bytes: v.url!, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)

            default:
                assertionFailure()
            }
        }

        private static func setInitialSize(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_initial_size_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("initial size does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.initialSize = NSSize(width: Double(v.width), height: Double(v.height))

            default:
                assertionFailure()
            }
        }

        private static func resetWindowSize(
            _ app: nubb_app_t,
            target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("reset window size does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .nubbResetWindowSize,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func resizeWindow(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_resize_window_s) -> Bool {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("resize window does nothing with an app target")
                return false

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }
                guard let controller = surfaceView.window?.windowController as? TerminalController else { return false }
                return controller.resizeWindow(
                    surfaceView,
                    to: NSSize(width: Double(v.width), height: Double(v.height))
                )

            default:
                assertionFailure()
                return false
            }
        }

        private static func setCellSize(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_cell_size_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("mouse over link does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
                }

            default:
                assertionFailure()
            }
        }

        private static func renderInspector(
            _ app: nubb_app_t,
            target: nubb_target_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("mouse over link does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.inspectorNeedsDisplay,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func rendererHealth(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_renderer_health_e) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("mouse over link does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: [
                        "health": v,
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func keySequence(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_key_sequence_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("key sequence does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                DispatchQueue.main.async {
                    if v.active {
                        NotificationCenter.default.post(
                            name: Notification.didContinueKeySequence,
                            object: surfaceView,
                            userInfo: [
                                Notification.KeySequenceKey: keyboardShortcut(for: v.trigger) as Any
                            ]
                        )
                    } else {
                        NotificationCenter.default.post(
                            name: Notification.didEndKeySequence,
                            object: surfaceView
                        )
                    }
                }

            default:
                assertionFailure()
            }
        }

        private static func keyTable(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_key_table_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("key table does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let action = Nubb.Action.KeyTable(c: v) else { return }

                NotificationCenter.default.post(
                    name: Notification.didChangeKeyTable,
                    object: surfaceView,
                    userInfo: [Notification.KeyTableKey: action]
                )

            default:
                assertionFailure()
            }
        }

        private static func progressReport(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_progress_report_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("progress report does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let config = (NSApplication.shared.delegate as? AppDelegate)?.nubb.config else { return }

                guard config.progressStyle else {
                    Nubb.logger.debug("progress_report action blocked by config")
                    DispatchQueue.main.async {
                        surfaceView.progressReport = nil
                    }
                    return
                }

                let progressReport = Nubb.Action.ProgressReport(c: v)
                DispatchQueue.main.async {
                    if progressReport.state == .remove {
                        surfaceView.progressReport = nil
                    } else {
                        surfaceView.progressReport = progressReport
                    }
                }

            default:
                assertionFailure()
            }
        }

        private static func scrollbar(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_scrollbar_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("scrollbar does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let scrollbar = Nubb.Action.Scrollbar(c: v)
                NotificationCenter.default.post(
                    name: .nubbDidUpdateScrollbar,
                    object: surfaceView,
                    userInfo: [
                        SwiftUI.Notification.Name.ScrollbarKey: scrollbar
                    ]
                )

            default:
                assertionFailure()
            }
        }

        private static func startSearch(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_start_search_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("start_search does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let startSearch = Nubb.Action.StartSearch(c: v)
                DispatchQueue.main.async {
                    if let searchState = surfaceView.searchState {
                        if let needle = startSearch.needle, !needle.isEmpty {
                            searchState.setNeedle(needle)
                        }
                    } else {
                        surfaceView.searchState = Nubb.SurfaceView.SearchState(from: startSearch)
                    }

                    NotificationCenter.default.post(name: .nubbSearchFocus, object: surfaceView)
                }

            default:
                assertionFailure()
            }
        }

        private static func endSearch(
            _ app: nubb_app_t,
            target: nubb_target_s) -> Bool {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("end_search does nothing with an app target")
                return false

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return false }
                guard let surfaceView = self.surfaceView(from: surface) else { return false }

                DispatchQueue.main.async {
                    surfaceView.endSearch()
                }
                return true
            default:
                assertionFailure()
                return false
            }
        }

        private static func searchTotal(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_search_total_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("search_total does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let total: UInt? = v.total >= 0 ? UInt(v.total) : nil
                DispatchQueue.main.async {
                    surfaceView.searchState?.total = total
                }

            default:
                assertionFailure()
            }
        }

        private static func searchSelected(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_search_selected_s) {
            switch target.tag {
            case NUBB_TARGET_APP:
                Nubb.logger.warning("search_selected does nothing with an app target")
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                let selected: UInt? = v.selected >= 0 ? UInt(v.selected) : nil
                DispatchQueue.main.async {
                    surfaceView.searchState?.selected = selected
                }

            default:
                assertionFailure()
            }
        }

        private static func configReload(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_reload_config_s) {
            logger.info("config reload notification")

            guard let app_ud = nubb_app_userdata(app) else { return }
            let nubb = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()

            switch target.tag {
            case NUBB_TARGET_APP:
                nubb.reloadConfig(soft: v.soft)
                return

            case NUBB_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                nubb.reloadConfig(surface: surface, soft: v.soft)

            default:
                assertionFailure()
            }
        }

        private static func configChange(
            _ app: nubb_app_t,
            target: nubb_target_s,
            v: nubb_action_config_change_s) {
                logger.info("config change notification")

                // Clone the config so we own the memory. It'd be nicer to not have to do
                // this but since we async send the config out below we have to own the lifetime.
                // A future improvement might be to add reference counting to config or
                // something so apprt's do not have to do this.
                let config = Config(clone: v.config)

                switch target.tag {
                case NUBB_TARGET_APP:
                    // Notify the world that the app config changed
                    NotificationCenter.default.post(
                        name: .nubbConfigDidChange,
                        object: nil,
                        userInfo: [
                            SwiftUI.Notification.Name.NubbConfigChangeKey: config,
                        ]
                    )

                    // We also REPLACE our app-level config when this happens. This lets
                    // all the various things that depend on this but are still theme specific
                    // such as split border color work.
                    guard let app_ud = nubb_app_userdata(app) else { return }
                    let nubb = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
                    nubb.config = config

                    return

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .nubbConfigDidChange,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.NubbConfigChangeKey: config,
                        ]
                    )

                default:
                    assertionFailure()
                }
            }

        private static func colorChange(
            _ app: nubb_app_t,
            target: nubb_target_s,
            change: nubb_action_color_change_s) {
                switch target.tag {
                case NUBB_TARGET_APP:
                    Nubb.logger.warning("color change does nothing with an app target")
                    return

                case NUBB_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .nubbColorDidChange,
                        object: surfaceView,
                        userInfo: [
                            SwiftUI.Notification.Name.NubbColorChangeKey: Action.ColorChange(c: change)
                        ]
                    )

                default:
                    assertionFailure()
                }
        }

        // MARK: User Notifications

        /// Handle a received user notification. This is called when a user notification is clicked or dismissed by the user
        func handleUserNotification(response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo
            guard let uuidString = userInfo["surface"] as? String,
                  let uuid = UUID(uuidString: uuidString),
                  let surface = delegate?.findSurface(forUUID: uuid) else { return }

            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier, Nubb.userNotificationActionShow:
                // The user clicked on a notification
                surface.handleUserNotification(notification: response.notification, focus: true)
            case UNNotificationDismissActionIdentifier:
                // The user dismissed the notification
                surface.handleUserNotification(notification: response.notification, focus: false)
            default:
                break
            }
        }
    }
}
