// Copied from ghostty macos/Sources/Ghostty/Ghostty.App.swift at 518ec334a and trimmed
// for webmux; see docs/macos-client.md.
//
// A single-surface host: the `action` switch keeps quit, close_window, set_title, pwd,
// mouse_shape, mouse_visibility, mouse_over_link, cell_size, renderer_health, ring_bell,
// selection_changed, color_change, config_change, reload_config and open_url (posted as
// a notification; the shell opens links, PARITY T-24/T-25), plus scrollbar (webmux: the
// pane's overlay scrollbar, T-10). Everything else (windows,
// tabs, splits, quick terminal, command palette, inspector, secure input, readonly,
// search, progress, key sequences/tables, desktop notifications, child-exited bar,
// undo/redo, fullscreen, float, maximize, title prompt, updates) is a no-op returning
// false. Clipboard confirmations always allow (the webmux config never asks for one).
// The config comes from text (Ghostty.Config(text:)), never from files.
import AppKit
import UniformTypeIdentifiers
import GhosttyKit

protocol GhosttyAppDelegate: AnyObject {
    /// Called when a callback needs access to a specific surface. This should return nil
    /// when the surface is no longer valid.
    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView?
}

extension Ghostty {
    public class App {
        public enum Readiness: String {
            case loading, error, ready
        }

        /// Optional delegate
        weak var delegate: GhosttyAppDelegate?

        /// The readiness value of the state.
        public internal(set) var readiness: Readiness = .loading

        /// The global app configuration. This defines the app level configuration plus any behavior
        /// for new windows, tabs, etc. Note that when creating a new window, it may inherit some
        /// configuration (i.e. font size) from the previously focused window. This would override this.
        public private(set) var config: Config

        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        public internal(set) var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// True if we need to confirm before quitting.
        var needsConfirmQuit: Bool {
            guard let app = app else { return false }
            return ghostty_app_needs_confirm_quit(app)
        }

        /// webmux: the configuration is handed in (built from text by the shell).
        public init(config: Config) {
            self.config = config
            guard let cConfig = self.config.config else {
                readiness = .error
                return
            }

            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app, target: target, action: action) },
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

            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, cConfig) else {
                logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app
            // Set our initial focus state
            ghostty_app_set_focus(app, NSApp.isActive)

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

        public func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        /// webmux: replace the configuration (e.g. the light/dark palette) for the app and
        /// every surface. `applied config will be updated in ``Self.configChange(_:target:v:)``.
        public func update(config newConfig: Config) {
            guard let app = self.app, let c = newConfig.config else { return }
            ghostty_app_update_config(app, c)
        }

        /// Reload the configuration: webmux has no config files, so a reload re-applies
        /// the configuration we already hold.
        func reloadConfig(soft: Bool = false) {
            guard let app = self.app, let c = config.config else { return }
            ghostty_app_update_config(app, c)
        }

        func reloadConfig(surface: ghostty_surface_t, soft: Bool = false) {
            guard let c = config.config else { return }
            ghostty_surface_update_config(surface, c)
        }

        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }

        func resetTerminal(surface: ghostty_surface_t) {
            let action = "reset"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify Ghostty so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        // Called when the app becomes active.
        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }

        // Called when the app becomes inactive.
        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }

        // MARK: Ghostty Callbacks (macOS)

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            guard let surface = self.surfaceUserdata(from: userdata) else { return }
            NotificationCenter.default.post(name: Notification.ghosttyCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer,
            mimes: UnsafePointer<UnsafePointer<CChar>>,
            mimesLen: Int,
            list: Bool
        ) -> ghostty_clipboard_read_result_e {
            guard let surfaceView = self.surfaceUserdata(from: userdata),
                  let surface = surfaceView.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.ghostty(location) else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }

            // Gather the representation for each requested MIME type that
            // the pasteboard can serve. We only ever read the requested
            // representations so unrelated (potentially large) clipboard
            // contents are never loaded.
            var contents: [Ghostty.ClipboardContent] = []
            var seen = Set<String>()
            for i in 0..<mimesLen {
                let mime = String(cString: mimes[i])
                guard !seen.contains(mime) else { continue }
                seen.insert(mime)
                guard let data = pasteboard.ghosttyData(forMime: mime) else { continue }
                contents.append(.init(mime: mime, data: data))
            }

            // The listing of available types, only gathered when requested.
            let available: [String] = list ? pasteboard.ghosttyAvailableMimes() : []

            // With nothing to serve and no listing requested there is
            // nothing to complete the read with.
            if contents.isEmpty && !list {
                return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
            }

            completeClipboardRequest(
                surface,
                contents: contents,
                available: available,
                state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        /// webmux: the configuration never asks for confirmation (clipboard-read = deny,
        /// clipboard-paste-protection = false), so if the core still asks, allow: the
        /// Electron client has no confirmation dialog either (C-01).
        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
            state: UnsafeMutableRawPointer,
            request: ghostty_clipboard_request_e
        ) {
            guard let surfaceView = self.surfaceUserdata(from: userdata),
                  let surface = surfaceView.surface else { return }
            let c = confirm.pointee

            let reps: [Ghostty.ClipboardContent] = if let contents = c.contents {
                (0..<c.contents_len).map { Ghostty.ClipboardContent.from(content: contents[$0]) }
            } else {
                []
            }
            var avail: [String] = []
            if let available = c.available {
                for i in 0..<c.available_len {
                    avail.append(String(cString: available[i]))
                }
            }

            completeClipboardRequest(
                surface,
                contents: reps,
                available: avail,
                state: state,
                confirmed: true,
                remember: false)
        }

        private static func completeClipboardRequest(
            _ surface: ghostty_surface_t,
            contents: [Ghostty.ClipboardContent],
            available: [String],
            state: UnsafeMutableRawPointer,
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

            var cContents: [ghostty_clipboard_content_s] = []
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
                cContents.append(ghostty_clipboard_content_s(
                    mime: mime,
                    data: buf.assumingMemoryBound(to: CChar.self),
                    len: entry.data.count))
            }

            var cAvailable: [UnsafePointer<CChar>] = []
            for mime in available {
                guard let str = strdup(mime) else { continue }
                cStrings.append(str)
                cAvailable.append(UnsafePointer(str))
            }

            cContents.withUnsafeBufferPointer { contentsBuf in
                cAvailable.withUnsafeBufferPointer { availableBuf in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availableBuf.baseAddress,
                        available_len: availableBuf.count,
                        confirmed: confirmed,
                        remember: remember)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>,
            len: Int,
            confirm: Bool
        ) {
            guard let pasteboard = NSPasteboard.ghostty(location) else { return }
            guard len > 0 else { return }

            // Convert the C array to Swift array
            let contentArray = (0..<len).map { i in
                Ghostty.ClipboardContent.from(content: content[i])
            }

            // webmux: writes that would ask for confirmation are applied as well
            // (clipboard-write = allow; there is no confirmation dialog, C-01).
            let types = contentArray.compactMap { item in
                NSPasteboard.PasteboardType(mimeType: item.mime)
            }
            pasteboard.declareTypes(types, owner: nil)

            // Set data for each type
            for item in contentArray {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setData(item.data, forType: type)
            }

            // webmux: tell the pane (an OSC 52 write shows a status message, C-01).
            if location == GHOSTTY_CLIPBOARD_STANDARD, let surfaceView = self.surfaceUserdata(from: userdata) {
                DispatchQueue.main.async { [weak surfaceView] in
                    surfaceView?.clipboardDidWrite()
                }
            }
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread. There is probably some improvements we can make
            // to coalesce multiple ticks but I don't think it matters from a performance
            // standpoint since we don't do this much.
            DispatchQueue.main.async { state.appTick() }
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
            guard let userdata else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        }

        static private func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
            guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
        }

        // MARK: Actions (macOS)

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Make sure it a target we understand so all our action handlers can assert
            switch target.tag {
            case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
                break

            default:
                Ghostty.logger.warning("unknown action target=\(target.tag.rawValue, privacy: .public)")
                return false
            }

            // Action dispatch
            switch action.tag {
            case GHOSTTY_ACTION_QUIT:
                quit(app)

            case GHOSTTY_ACTION_CLOSE_WINDOW:
                closeWindow(app, target: target)

            case GHOSTTY_ACTION_SET_TITLE:
                setTitle(app, target: target, v: action.action.set_title)

            case GHOSTTY_ACTION_PWD:
                pwdChanged(app, target: target, v: action.action.pwd)

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                setMouseShape(app, target: target, shape: action.action.mouse_shape)

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                setMouseVisibility(app, target: target, v: action.action.mouse_visibility)

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                setMouseOverLink(app, target: target, v: action.action.mouse_over_link)

            case GHOSTTY_ACTION_CELL_SIZE:
                setCellSize(app, target: target, v: action.action.cell_size)

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                rendererHealth(app, target: target, v: action.action.renderer_health)

            case GHOSTTY_ACTION_RING_BELL:
                ringBell(app, target: target)

            case GHOSTTY_ACTION_SELECTION_CHANGED:
                selectionChanged(app, target: target)

            case GHOSTTY_ACTION_COLOR_CHANGE:
                colorChange(app, target: target, change: action.action.color_change)

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                configChange(app, target: target, v: action.action.config_change)

            case GHOSTTY_ACTION_RELOAD_CONFIG:
                configReload(app, target: target, v: action.action.reload_config)

            case GHOSTTY_ACTION_OPEN_URL:
                return openURL(app, target: target, v: action.action.open_url)

            // webmux: the pane draws its own overlay scrollbar (PARITY T-10).
            case GHOSTTY_ACTION_SCROLLBAR:
                scrollbarChanged(app, target: target, v: action.action.scrollbar)

            default:
                // webmux: windows, tabs, splits, quick terminal, palette, inspector,
                // secure input, readonly, search, progress, key tables, desktop
                // notifications, child-exited, undo/redo, fullscreen... are not
                // performable in this shell.
                Ghostty.logger.debug("unhandled action action=\(action.tag.rawValue, privacy: .public)")
                return false
            }

            // If we reached here then we assume performed since all unknown actions
            // are captured in the switch and return false.
            return true
        }

        private static func quit(_ app: ghostty_app_t) {
            // We want to quit, start that process
            NSApplication.shared.terminate(nil)
        }

        /// webmux: the shell decides how a link opens (link chooser, PARITY T-24/T-25),
        /// so the URL is handed on as a notification and never opened here.
        private static func openURL(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_open_url_s
        ) -> Bool {
            let action = Ghostty.Action.OpenURL(c: v)
            var object: SurfaceView? = nil
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                object = self.surfaceView(from: surface)
            }
            NotificationCenter.default.post(
                name: .ghosttyOpenURL,
                object: object,
                userInfo: [Foundation.Notification.Name.GhosttyOpenURLKey: action]
            )
            return true
        }

        /// webmux: scrollback geometry for the pane's scrollbar (T-10).
        private static func scrollbarChanged(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_scrollbar_s
        ) {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let surfaceView = self.surfaceView(from: surface) else { return }
            let scrollbar = Ghostty.Action.Scrollbar(c: v)
            DispatchQueue.main.async { [weak surfaceView] in
                surfaceView?.scrollbarDidChange(scrollbar)
            }
        }

        private static func closeWindow(_ app: ghostty_app_t, target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("close window does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }

                NotificationCenter.default.post(
                    name: .ghosttyCloseWindow,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func ringBell(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                // Technically we could still request app attention here but there
                // are no known cases where the bell is rang with an app target so
                // I think its better to warn.
                Ghostty.logger.warning("ring bell does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttyBellDidRing,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func selectionChanged(
            _ app: ghostty_app_t,
            target: ghostty_target_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("selection changed does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                NotificationCenter.default.post(
                    name: .ghosttySelectionDidChange,
                    object: surfaceView
                )

            default:
                assertionFailure()
            }
        }

        private static func setTitle(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_set_title_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set title does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let title = String(cString: v.title, encoding: .utf8) else { return }
                surfaceView.setTitle(title)

            default:
                assertionFailure()
            }
        }

        private static func pwdChanged(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_pwd_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("pwd change does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard let pwd = String(cString: v.pwd, encoding: .utf8) else { return }
                surfaceView.pwd = pwd

            default:
                assertionFailure()
            }
        }

        private static func setMouseShape(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            shape: ghostty_action_mouse_shape_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set mouse shapes nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                surfaceView.setCursorShape(shape)

            default:
                assertionFailure()
            }
        }

        private static func setMouseVisibility(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_mouse_visibility_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("set mouse shapes nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                switch v {
                case GHOSTTY_MOUSE_VISIBLE:
                    surfaceView.setCursorVisibility(true)

                case GHOSTTY_MOUSE_HIDDEN:
                    surfaceView.setCursorVisibility(false)

                default:
                    return
                }

            default:
                assertionFailure()
            }
        }

        private static func setMouseOverLink(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_mouse_over_link_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("mouse over link does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                guard let surfaceView = self.surfaceView(from: surface) else { return }
                guard v.len > 0 else {
                    surfaceView.hoverUrl = nil
                    return
                }

                let buffer = Data(bytes: v.url, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)

            default:
                assertionFailure()
            }
        }

        private static func setCellSize(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_cell_size_s) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("cell size does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
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

        private static func rendererHealth(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_renderer_health_e) {
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                Ghostty.logger.warning("renderer health does nothing with an app target")
                return

            case GHOSTTY_TARGET_SURFACE:
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

        private static func configReload(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_reload_config_s) {
            logger.info("config reload notification")

            guard let app_ud = ghostty_app_userdata(app) else { return }
            let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()

            switch target.tag {
            case GHOSTTY_TARGET_APP:
                ghostty.reloadConfig(soft: v.soft)
                return

            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface else { return }
                ghostty.reloadConfig(surface: surface, soft: v.soft)

            default:
                assertionFailure()
            }
        }

        private static func configChange(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_config_change_s) {
                logger.info("config change notification")

                // Clone the config so we own the memory. It'd be nicer to not have to do
                // this but since we async send the config out below we have to own the lifetime.
                // A future improvement might be to add reference counting to config or
                // something so apprt's do not have to do this.
                let config = Config(clone: v.config)

                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    // Notify the world that the app config changed
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [
                            Foundation.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )

                    // We also REPLACE our app-level config when this happens. This lets
                    // all the various things that depend on this but are still theme specific
                    // such as split border color work.
                    guard let app_ud = ghostty_app_userdata(app) else { return }
                    let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
                    ghostty.config = config

                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [
                            Foundation.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )

                default:
                    assertionFailure()
                }
            }

        private static func colorChange(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            change: ghostty_action_color_change_s) {
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    Ghostty.logger.warning("color change does nothing with an app target")
                    return

                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface else { return }
                    guard let surfaceView = self.surfaceView(from: surface) else { return }
                    NotificationCenter.default.post(
                        name: .ghosttyColorDidChange,
                        object: surfaceView,
                        userInfo: [
                            Foundation.Notification.Name.GhosttyColorChangeKey: Action.ColorChange(c: change)
                        ]
                    )

                default:
                    assertionFailure()
                }
        }
    }
}
