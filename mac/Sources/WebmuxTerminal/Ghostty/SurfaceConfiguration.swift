// Copied from ghostty macos/Sources/Ghostty/Surface View/SurfaceView.swift (the
// `SurfaceConfiguration` struct only; the SwiftUI views were dropped) at 518ec334a and
// trimmed for webmux; see docs/macos-client.md.
//
// webmux additions: the `webmux` attachment (socket path, session id, userdata and the
// event callback) that `withCValue` copies into the fork's trailing
// `ghostty_surface_config_s` fields. `NSScreen.main!` became `NSScreen.main ?? 2`.
import AppKit
import System
import GhosttyKit

extension Ghostty {
    /// The webmux session a surface attaches to instead of a local pty
    /// (gtk/ghostty/WEBMUX.md "macOS: GhosttyKit"). The strings only need to
    /// live until `ghostty_surface_new` returns; `userdata` must stay valid
    /// until the surface is freed.
    struct WebmuxAttachment {
        var socketPath: String
        var sessionId: String
        var userdata: UnsafeMutableRawPointer?
        var eventCallback: ghostty_webmux_event_cb?
    }

    public struct SurfaceConfiguration {
        /// Explicit font size to use in points
        public var fontSize: Float32?

        /// Explicit working directory. This is normalized on assignment to
        /// remove any redundant and trailing path separators.
        var workingDirectory: String? {
            get { normalizedWorkingDirectory }
            set { normalizedWorkingDirectory = newValue.map { FilePath($0).string } }
        }
        private var normalizedWorkingDirectory: String?

        /// Explicit command to set
        var command: String?

        /// Environment variables to set for the terminal
        var environmentVariables: [String: String] = [:]

        /// Extra input to send as stdin
        var initialInput: String?

        /// Wait after the command
        var waitAfterCommand: Bool = false

        /// Context for surface creation
        var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

        /// webmux: attach to a session instead of spawning a local shell.
        var webmux: WebmuxAttachment?

        public init() {}

        init(from config: ghostty_surface_config_s) {
            self.fontSize = config.font_size
            if let workingDirectory = config.working_directory {
                self.workingDirectory = String.init(cString: workingDirectory, encoding: .utf8)
            }
            if let command = config.command {
                self.command = String.init(cString: command, encoding: .utf8)
            }

            // Convert the C env vars to Swift dictionary
            if config.env_var_count > 0, let envVars = config.env_vars {
                for i in 0..<config.env_var_count {
                    let envVar = envVars[i]
                    if let key = String(cString: envVar.key, encoding: .utf8),
                       let value = String(cString: envVar.value, encoding: .utf8) {
                        self.environmentVariables[key] = value
                    }
                }
            }
            self.context = config.context
        }

        /// Provides a C-compatible ghostty configuration within a closure. The configuration
        /// and all its string pointers are only valid within the closure.
        func withCValue<T>(view: SurfaceView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)

            // Zero is our default value that means to inherit the font size.
            config.font_size = fontSize ?? 0

            // Set wait after command
            config.wait_after_command = waitAfterCommand

            // Set context
            config.context = context

            // webmux: the attachment, if any.
            config.webmux_userdata = webmux?.userdata
            config.webmux_event_cb = webmux?.eventCallback
            let webmuxSocketPath: String? = webmux?.socketPath
            let webmuxSessionId: String? = webmux?.sessionId

            // Use withCString to ensure strings remain valid for the duration of the closure
            return try workingDirectory.withCString { cWorkingDir in
                config.working_directory = cWorkingDir

                return try command.withCString { cCommand in
                    config.command = cCommand

                    return try initialInput.withCString { cInput in
                        config.initial_input = cInput

                        return try webmuxSocketPath.withCString { cSocket in
                            config.webmux_socket_path = cSocket

                            return try webmuxSessionId.withCString { cSession in
                                config.webmux_session_id = cSession

                                // Convert dictionary to arrays for easier processing
                                let keys = Array(environmentVariables.keys)
                                let values = Array(environmentVariables.values)

                                // Create C strings for all keys and values
                                return try keys.withCStrings { keyCStrings in
                                    return try values.withCStrings { valueCStrings in
                                        // Create array of ghostty_env_var_s
                                        var envVars = [ghostty_env_var_s]()
                                        envVars.reserveCapacity(environmentVariables.count)
                                        for i in 0..<environmentVariables.count {
                                            envVars.append(ghostty_env_var_s(
                                                key: keyCStrings[i],
                                                value: valueCStrings[i]
                                            ))
                                        }

                                        return try envVars.withUnsafeMutableBufferPointer { buffer in
                                            config.env_vars = buffer.baseAddress
                                            config.env_var_count = environmentVariables.count
                                            return try body(&config)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
