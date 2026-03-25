import UIKit

extension KBKeyValue {
    enum DictationState {
        case idle
        case downloading(progress: Double)
        case recording
        case transcribing
    }

    static func micSymbolName(for state: DictationState) -> String {
        switch state {
        case .idle, .downloading: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "mic.fill"
        }
    }

    static func micTintColor(for state: DictationState) -> UIColor {
        switch state {
        case .idle: return .label
        case .downloading: return .secondaryLabel
        case .recording: return .systemRed
        case .transcribing: return .systemOrange
        }
    }
}
