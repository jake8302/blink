import Foundation

struct DictationSettings {
    private static let quickModeKey = "dictation_quick_mode"

    static var isQuickMode: Bool {
        get { UserDefaults.standard.bool(forKey: quickModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: quickModeKey) }
    }
}
