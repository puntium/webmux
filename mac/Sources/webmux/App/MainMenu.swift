// The menu bar, built from `MenuSpec.menuBar` (WebmuxPanels; PARITY W-41…W-45,
// macOS column). App commands target the AppDelegate; the standard roles use
// their AppKit selectors; pane commands travel the responder chain with a
// nil target (`PaneCommandTarget`) and stay disabled until the workspace
// implements them.
import AppKit
import WebmuxPanels

enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let menubar = NSMenu()
        for spec in MenuSpec.menuBar {
            let top = NSMenuItem()
            menubar.addItem(top)
            let menu = NSMenu(title: spec.title)
            top.submenu = menu
            for itemSpec in spec.items {
                if itemSpec.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                guard let command = itemSpec.command else { continue }
                if command == .settings {
                    // Services sits between Settings and the Hide group, as on
                    // every Mac app.
                    menu.addItem(make(itemSpec, command))
                    menu.addItem(.separator())
                    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
                    let servicesMenu = NSMenu(title: "Services")
                    services.submenu = servicesMenu
                    NSApp.servicesMenu = servicesMenu
                    menu.addItem(services)
                    continue
                }
                menu.addItem(make(itemSpec, command))
            }
            switch spec.title {
            case "Window": NSApp.windowsMenu = menu
            case "Help": NSApp.helpMenu = menu
            default: break
            }
        }
        return menubar
    }

    @MainActor
    private static func make(_ spec: MenuItemSpec, _ command: MenuCommand) -> NSMenuItem {
        let (action, target) = binding(command)
        let item = NSMenuItem(title: spec.title, action: action, keyEquivalent: spec.key)
        item.keyEquivalentModifierMask = spec.mods
        item.target = target
        item.representedObject = command.rawValue
        if let n = command.hostIndex { item.tag = n }
        return item
    }

    /// Selector and target for a command: nil target = the responder chain.
    @MainActor
    private static func binding(_ command: MenuCommand) -> (Selector?, AnyObject?) {
        if let sel = command.paneSelector { return (sel, nil) }
        let app = NSApp.delegate as? AppDelegate
        switch command {
        case .about: return (#selector(AppDelegate.showAbout(_:)), app)
        case .connections: return (#selector(AppDelegate.showConnections(_:)), app)
        case .reconnect: return (#selector(AppDelegate.reconnect(_:)), app)
        case .openConfigFile: return (#selector(AppDelegate.openConfigFile(_:)), app)
        case .connectionLog: return (#selector(AppDelegate.showLog(_:)), app)
        case .settings: return (#selector(AppDelegate.showSettings(_:)), app)
        case .hide: return (#selector(NSApplication.hide(_:)), nil)
        case .hideOthers: return (#selector(NSApplication.hideOtherApplications(_:)), nil)
        case .showAll: return (#selector(NSApplication.unhideAllApplications(_:)), nil)
        case .quit: return (#selector(NSApplication.terminate(_:)), nil)
        case .undo: return (Selector(("undo:")), nil)
        case .redo: return (Selector(("redo:")), nil)
        case .cut: return (#selector(NSText.cut(_:)), nil)
        case .copy: return (#selector(NSText.copy(_:)), nil)
        case .paste: return (#selector(NSText.paste(_:)), nil)
        case .pasteAndMatchStyle: return (#selector(NSTextView.pasteAsPlainText(_:)), nil)
        case .delete: return (#selector(NSText.delete(_:)), nil)
        case .selectAll: return (#selector(NSText.selectAll(_:)), nil)
        case .toggleFullScreen: return (#selector(NSWindow.toggleFullScreen(_:)), nil)
        case .minimize: return (#selector(NSWindow.performMiniaturize(_:)), nil)
        case .zoom: return (#selector(NSWindow.performZoom(_:)), nil)
        case .previousHost: return (#selector(AppDelegate.previousHost(_:)), app)
        case .nextHost: return (#selector(AppDelegate.nextHost(_:)), app)
        case .host1, .host2, .host3, .host4, .host5, .host6, .host7, .host8, .host9:
            return (#selector(AppDelegate.showHostNumber(_:)), app)
        case .bringAllToFront: return (#selector(NSApplication.arrangeInFront(_:)), nil)
        case .help: return (#selector(AppDelegate.showHelp(_:)), app)
        default: return (nil, nil)
        }
    }

    /// The first menu item titled `title`, searching every submenu (control socket).
    @MainActor
    static func item(titled title: String, in menu: NSMenu? = nil) -> NSMenuItem? {
        guard let menu = menu ?? NSApp.mainMenu else { return nil }
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = self.item(titled: title, in: sub) { return found }
        }
        return nil
    }
}
