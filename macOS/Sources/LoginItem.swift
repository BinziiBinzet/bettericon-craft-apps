import AppKit
import ServiceManagement

/// What macOS says about BetterIcon's login item.
enum LoginItemState {
    /// macOS opens BetterIcon at login.
    case enabled
    /// BetterIcon is registered, and the user has yet to allow it in System Settings > General > Login Items.
    case requiresApproval
    /// Not registered, removed in System Settings, or unknown to macOS.
    case off
}

/// Opens BetterIcon at login. The app uses `SystemLoginItem` on macOS 13 and later, and has no option on macOS 12. A
/// fixture installation has none either, and the checks hand the app a stand-in, so no test registers a real login item.
protocol LoginItem: AnyObject {
    var state: LoginItemState { get }
    /// Why this copy of BetterIcon cannot open at login, or nil when it can.
    var unavailable: String? { get }
    func register() throws
    func unregister() throws
    /// Open System Settings where the user allows BetterIcon to open at login.
    func openSettings()
}

enum LoginItems {
    /// Where the user allows a login item: macOS 15 renamed the pane.
    static var pane: String {
        if #available(macOS 15, *) { return "System Settings > General > Login Items & Extensions" }
        return "System Settings > General > Login Items"
    }
}

/// The login item of the running app, through ServiceManagement.
@available(macOS 13, *)
final class SystemLoginItem: LoginItem {
    private let bundle: URL
    init(bundle: URL = Bundle.main.bundleURL) { self.bundle = bundle }
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }
    var unavailable: String? {
        // Opened from the disk image, or from a download that macOS runs from a random read-only folder (App
        // Translocation): a login item would point at a copy that is gone after the next restart.
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        guard readOnly || bundle.path.contains("/AppTranslocation/") else { return nil }
        return "To open BetterIcon at login, drag it into your Applications folder and open it from there."
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LoginLaunch {
    /// Whether macOS opened BetterIcon as a login item.
    ///
    /// When macOS opens an app at login, the Apple event that starts it (open application, or reopen application when
    /// the app already runs) carries keyAELaunchedAsLogInItem in its keyAEPropData parameter. AppKit is handling that
    /// event while it calls applicationDidFinishLaunching and applicationShouldHandleReopen, so it is the current
    /// Apple event there. A start from Finder, the Dock, Spotlight or `open` carries no such value.
    static func detected(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
            [AEEventID(kAEOpenApplication), AEEventID(kAEReopenApplication)].contains(event.eventID)
        else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}
