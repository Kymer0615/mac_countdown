import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class CountdownSettings: ObservableObject {
    @Published var fontStyle: String { didSet { defaults.set(fontStyle, forKey: "countdown.fontStyle"); onChange?() } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "countdown.fontSize"); onChange?() } }
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published var loginError: String?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    static let styles = ["System", "Rounded", "Serif", "Monospaced"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "countdown.fontStyle") ?? "System"
        fontStyle = Self.styles.contains(saved) ? saved : "System"
        let size = defaults.object(forKey: "countdown.fontSize") as? Double ?? 13
        fontSize = size.isFinite ? min(22, max(10, size)) : 13
    }

    var appKitFont: NSFont {
        let base = NSFont.systemFont(ofSize: fontSize)
        let design: NSFontDescriptor.SystemDesign
        switch fontStyle {
        case "Rounded": design = .rounded
        case "Serif": design = .serif
        case "Monospaced": design = .monospaced
        default: design = .default
        }
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
    }

    var swiftUIFont: Font { Font(appKitFont) }
    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }
    func setStartAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { loginError = error.localizedDescription }
        refreshLoginStatus()
    }
}
