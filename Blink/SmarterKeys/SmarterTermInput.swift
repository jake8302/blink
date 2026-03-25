//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import UIKit
import Combine
import MBProgressHUD


@objc class SmarterTermInput: KBWebView {

  var kbView = KBView()
  var _proxyBarButtonItem: UIBarButtonItem!
  var _barButtonItemGroup: UIBarButtonItemGroup!
  var _dictationHUD: MBProgressHUD?

  private lazy var dictationManager: DictationManager = {
      let manager = DictationManager()
      manager.onTranscription = { [weak self] text in
          self?.handleTranscription(text)
      }
      manager.onStateChange = { [weak self] state in
          self?.handleDictationStateChange(state)
      }
      manager.onAudioLevel = { [weak self] level in
          self?._waveformView?.updateLevel(level)
      }
      manager.onError = { [weak self] message in
          print("[Dictation] Error: \(message)")
      }
      return manager
  }()

  lazy var _kbProxy: KBProxy = {
    KBProxy(kbView: self.kbView)
  }()
  
  private var _inputAccessoryView: UIView? = nil
  
  var isHardwareKB: Bool { kbView.traits.isHKBAttached }
  
  weak var device: TermDevice? = nil {
    didSet { reportStateReset() }
  }
  
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  
  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    
    
    super.init(frame: frame, configuration: configuration)


    _proxyBarButtonItem = UIBarButtonItem(customView: _kbProxy)
    _barButtonItemGroup = UIBarButtonItemGroup(barButtonItems: [_proxyBarButtonItem], representativeItem: nil)
    
    kbView.keyInput = self
    kbView.lang = textInputMode?.primaryLanguage ?? ""
    
    // Assume hardware kb by default, since sometimes we don't have kbframe change events
    // if shortcuts toggle in Settings.app is off.
    kbView.traits.isHKBAttached = true
    
    if traitCollection.userInterfaceIdiom == .pad {
//      _setupAssistantItem()
    } else {
      _setupAccessoryView()
    }
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
   
    if let value = self.window?.windowScene?.interfaceOrientation.isPortrait  {
      kbView.traits.isPortrait = value
    }
    kbView.setNeedsLayout()
  }
  
  func shouldUseWKCopyAndPaste() -> Bool {
    false
  }
  
  override func ready() {
    super.ready()
    reportLang()
    
//    device?.focus()
    kbView.isHidden = false
    kbView.invalidateIntrinsicContentSize()
  }
  
  func reset() {
    
  }
  
  func reportLang() {
    let lang = self.textInputMode?.primaryLanguage ?? ""
    kbView.lang = lang
    reportLang(lang, isHardwareKB: kbView.traits.isHKBAttached)
  }
  
  override var inputAssistantItem: UITextInputAssistantItem {
    let item = super.inputAssistantItem
    if KBTracker.shared.isHardwareKB {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    } else if _barButtonItemGroup != nil {
      item.leadingBarButtonGroups = []
      if item.trailingBarButtonGroups.first != _barButtonItemGroup || item.trailingBarButtonGroups.count != 1 {
        item.trailingBarButtonGroups = [_barButtonItemGroup]
        
        // Reload input views later. Fixes crash for detaching/attaching KB
        if let contentView = self.contentView() {
          DispatchQueue.main.async {
            contentView.reloadInputViews()
          }
        }
        
      }
      kbView.isHidden = false
      
    } else {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    }
    
    return item
  }
  
  override func becomeFirstResponder() -> Bool {
    // Don't become first responder if blocked (e.g., during Snips Input Mode)
    if device?.shouldBlockFirstResponder == true {
      return false
    }

    sync(traits: KBTracker.shared.kbTraits, device: KBTracker.shared.kbDevice, hideSmartKeysWithHKB: KBTracker.shared.hideSmartKeysWithHKB)

    let res = super.becomeFirstResponder()

    if !webViewReady {
      return res
    }

    device?.focus()
    kbView.isHidden = false
    setNeedsLayout()

    _inputAccessoryView?.isHidden = false

    return res
  }
  
  override func canBeFocused() -> Bool {
    let res = super.canBeFocused()
    if let delegate = self.window?.windowScene?.delegate as? SceneDelegate {
      if delegate.showingPaywall() {
        return false
      }
    }
    return res
    
  }
  
  var isRealFirstResponder: Bool {
    contentView()?.isFirstResponder == true
  }
  
  func reportStateReset() {
    reportStateReset(false)
    device?.view?.cleanSelection()
  }
  
  func reportStateWithSelection() {
    reportStateReset(device?.view?.hasSelection ?? false)
  }
  
  
  override func resignFirstResponder() -> Bool {
    let res = super.resignFirstResponder()
    if res {
      device?.blur()
      kbView.isHidden = true
      _inputAccessoryView?.isHidden = true
    }
    return res
  }

  func _setupAccessoryView() {
    if isHardwareKB {
      return
    }
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []

    if let _ = _inputAccessoryView as? KBAccessoryView {
    } else {
      _inputAccessoryView = KBAccessoryView(kbView: kbView)
    }
  }

  override var inputAccessoryView: UIView? {
    return _inputAccessoryView
  }

  func sync(traits: KBTraits, device: KBDevice, hideSmartKeysWithHKB: Bool) {
    kbView.kbDevice = device
    
    defer {
      
      kbView.traits = traits
      
      if let scene = window?.windowScene {
        if traitCollection.userInterfaceIdiom == .phone {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        } else if kbView.traits.isFloatingKB {
          kbView.traits.isPortrait = true
        } else {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        }
      }
      
    }
    
    if traitCollection.userInterfaceIdiom == .phone {
      if hideSmartKeysWithHKB && traits.isHKBAttached {
        _removeSmartKeys()
        return
      }
    }
    
    if traits.isFloatingKB {
      _setupAccessoryView()
      return
    }
    
    if traitCollection.userInterfaceIdiom != .pad {
//      needToReload = (_inputAccessoryView as? KBAccessoryView) == nil
      _setupAccessoryView()
    }
    
  }
  
//  func _setupAssistantItem() {
//    let item = inputAssistantItem
//
////    let proxyItem = UIBarButtonItem(customView: _kbProxy)
////    let group = UIBarButtonItemGroup(barButtonItems: [proxyItem], presentativeItem: nil)
//
////    item.leadingBarButtonGroups = []
////    item.trailingBarButtonGroups = [group]
//
//    item.leadingBarButtonGroups = []
//    item.trailingBarButtonGroups = []
//  }
  
  func _removeSmartKeys() {
    if let _ = _inputAccessoryView as? KBAccessoryView {
      _inputAccessoryView = UIView(frame: .zero)
      self.contentView()?.reloadInputViews()      
    }
    
    guard let item = contentView()?.inputAssistantItem
      else {
        return
    }
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
    setNeedsLayout()
  }
  
  // MARK: - Legacy Keyboard Methods Removed
  // These empty override methods have been removed as keyboard tracking
  // is now handled by UIKeyboardLayoutGuide in SpaceController
  
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesBegan(presses, with: event)
    
    guard presses.count == 1, let press = presses.first, let key = press.key,
    // left or right cmd
    key.keyCode.rawValue == 227 || key.keyCode.rawValue == 231
    else {
      commandPressTimestamp = 0
      return
    }
    
    if press.timestamp - commandPressTimestamp > 0.5 {
      commandPressTimestamp = press.timestamp
      return
    }
    
    UIApplication.shared.sendAction(#selector(SpaceController.toggleQuickActionsAction), to: nil, from: nil, for: nil)
    commandPressTimestamp = 0
  }
  
  var commandPressTimestamp: TimeInterval = 0
}

// - MARK: Web communication
extension SmarterTermInput {
  
  override func onOut(_ data: String) {
    defer {
      kbView.turnOffUntracked()
    }
    
    guard
      let device = device,
      let deviceView = device.view,
      let scene = deviceView.window?.windowScene,
      scene.activationState == .foregroundActive
    else {
        return
    }
    
    deviceView.displayInput(data)
    
    device.write(data)
  }
  
  override func onCommand(_ command: String) {
    kbView.turnOffUntracked()

    if command == "toggleDictation" {
        dictationManager.toggle()
        return
    }

    guard
      let device = device,
      let scene = device.view.window?.windowScene,
      scene.activationState == .foregroundActive,
      let cmd = Command(rawValue: command),
      let spCtrl = spaceController
    else {
      return
    }

    spCtrl._onCommand(cmd)
  }
  
  var spaceController: SpaceController? {
    var n = next
    while let responder = n {
      if let spCtrl = responder as? SpaceController {
        return spCtrl
      }
      n = responder.next
    }
    return nil
  }
  
  override func onSelection(_ args: [AnyHashable : Any]) {
    if let dir = args["dir"] as? String, let gran = args["gran"] as? String {
      device?.view?.modifySelection(inDirection: dir, granularity: gran)
    } else if let op = args["command"] as? String {
      switch op {
      case "change": device?.view?.modifySideOfSelection()
      case "copy": copy(self)
      case "paste": device?.view?.pasteSelection(self)
      case "cancel": fallthrough
      default:  device?.view?.cleanSelection()
      }
    }
  }
  
  override func onMods() {
    kbView.stopRepeats()
  }
  
  override func onIME(_ event: String, data: String) {
    if event == "compositionstart" && data.isEmpty {
    } else if event == "compositionend" {
      kbView.traits.isIME = false
    } else { // "compositionupdate"
      kbView.traits.isIME = true
    }
  }
  
  func stuckKey() -> KeyCode? {
    let mods: UIKeyModifierFlags = [.shift, .control, .alternate, .command]
    let stuck = mods.intersection(trackingModifierFlags)
    
    // Return command key first
    if stuck.contains(.command) {
      return KeyCode.commandLeft
    }

    if stuck.contains(.shift) {
      return KeyCode.shiftLeft
    }
    if stuck.contains(.control) {
      return KeyCode.controlLeft
    }
    
    if stuck.contains(.alternate) {
      return KeyCode.optionLeft
    }
    
    return nil
  }
}
// - MARK: Config

extension SmarterTermInput {
  
  @objc private func _updateSettings() {
//    let hideSmartKeysWithHKB = !BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigShowSmartKeysWithXKeyBoard)
//    
//    if hideSmartKeysWithHKB != hideSmartKeysWithHKB {
//      _hideSmartKeysWithHKB = hideSmartKeysWithHKB
//      if traitCollection.userInterfaceIdiom == .pad {
//        _setupAssistantItem()
//      } else {
//        _setupAccessoryView()
//      }
//      _refreshInputViews()
//    }
  }
}


// - MARK: Commands

extension SmarterTermInput {
  
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    switch action {
    case #selector(UIResponder.paste(_:)):
      // do not touch UIPasteboard before actual paste to skip exta notification.
      return true// UIPasteboard.general.string != nil
    case
      #selector(UIResponder.copy(_:)),
      #selector(Self.copyRaw(_:)),
      #selector(UIResponder.cut(_:)):
      // When the action is requested from the keyboard, the sender will be nil.
      // In that case we let it go through to the WKWebView.
      // Otherwise, we check if there is a selection.
      return (sender == nil) || (sender != nil && device?.view?.hasSelection == true)
    case
         #selector(TermView.pasteSelection(_:)),
         #selector(Self.soSelection(_:)),
         #selector(Self.googleSelection(_:)),
         #selector(Self.shareSelection(_:)):
      return sender != nil && device?.view?.hasSelection == true
    case #selector(Self.copyLink(_:)),
         #selector(Self.openLink(_:)):
      return sender != nil && device?.view?.detectedLink != nil
    default:
//      if #available(iOS 15.0, *) {
//        switch action {
//          case #selector(UIResponder.pasteAndMatchStyle(_:)),
//               #selector(UIResponder.pasteAndSearch(_:)),
//               #selector(UIResponder.pasteAndGo(_:)): return false
//          case _: break
//        }
//      }
      return super.canPerformAction(action, withSender: sender)
    }
  }
  
  override func copy(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.copy(sender)
    } else {
      device?.view?.copy(sender)
    }
  }

  @objc func copyRaw(_ sender: Any?) {
    device?.view?.copyRaw(sender)
  }

  override func paste(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.paste(sender)
    } else {
      device?.view?.paste(sender)
    }
  }

  @objc func copyLink(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let url = deviceView.detectedLink
      else {
        return
    }
    UIPasteboard.general.url = url
    deviceView.cleanSelection()
  }
  
  @objc func openLink(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let url = deviceView.detectedLink
      else {
        return
    }
    deviceView.cleanSelection()
    
    blink_openurl(url)
  }
  
  @objc func pasteSelection(_ sender: Any) {
    device?.view?.pasteSelection(sender)
  }
  
  @objc func googleSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://google.com/search?q=\(query)")
    else {
        return
    }
    
    blink_openurl(url)
  }
  
  @objc func soSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://stackoverflow.com/search?q=\(query)")
    else {
        return
    }
    
    blink_openurl(url)
  }
  
  @objc func shareSelection(_ sender: Any) {
    guard
      let vc = device?.delegate?.viewController(),
      let deviceView = device?.view,
      let text = deviceView.selectedText
    else {
        return
    }
    
    let ctrl = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    ctrl.popoverPresentationController?.sourceView = deviceView
    ctrl.popoverPresentationController?.sourceRect = deviceView.selectionRect
    vc.present(ctrl, animated: true, completion: nil)
  }
}


extension SmarterTermInput: TermInput {
  var secureTextEntry: Bool {
    get {
      false
    }
    set(secureTextEntry) {
      
    }
  }
  
}

class VSCodeInput: SmarterTermInput {
  override func shouldUseWKCopyAndPaste() -> Bool {
    true
  }

  override func canBeFocused() -> Bool {
    let res = super.canBeFocused()

    if res == false {
      return KBTracker.shared.input == self
    }

    return res
  }
}

// MARK: - Dictation

extension SmarterTermInput {
    private var _micSpinner: UIActivityIndicatorView? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.micSpinner) as? UIActivityIndicatorView }
        set { objc_setAssociatedObject(self, &AssociatedKeys.micSpinner, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var _waveformView: AudioWaveformView? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.waveform) as? AudioWaveformView }
        set { objc_setAssociatedObject(self, &AssociatedKeys.waveform, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func handleTranscription(_ text: String) {
        guard !text.isEmpty else { return }
        sendDictationText(text)
    }

    func handleDictationStateChange(_ state: DictationManager.State) {
        let dictationState: KBKeyValue.DictationState
        switch state {
        case .idle:
            dictationState = .idle
            _dictationHUD?.hide(animated: true)
            _dictationHUD = nil
        case .downloading(let p):
            dictationState = .downloading(progress: p)
            showDownloadProgress(p)
        case .recording:
            dictationState = .recording
            _dictationHUD?.hide(animated: true)
            _dictationHUD = nil
        case .transcribing:
            dictationState = .transcribing
        }

        updateMicButton(for: dictationState)
    }

    private func showDownloadProgress(_ progress: Double) {
        guard let spCtrl = spaceController else { return }
        if _dictationHUD == nil {
            let hud = MBProgressHUD.showAdded(to: spCtrl.view, animated: true)
            hud.mode = .indeterminate
            hud.label.text = "Loading speech model..."
            hud.detailsLabel.text = "First launch may take a few minutes"
            _dictationHUD = hud
        }
    }

    func sendDictationText(_ text: String) {
        let bracketedPaste = "\u{1b}[200~\(text)\u{1b}[201~"
        onOut(bracketedPaste)
    }

    private func findMicView(in view: UIView) -> KBKeyViewSymbol? {
        for subview in view.subviews {
            if let keyView = subview as? KBKeyViewSymbol,
               keyView.key.shape.primaryValue == .mic {
                return keyView
            }
            if let found = findMicView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func updateMicButton(for state: KBKeyValue.DictationState) {
        guard let micView = findMicView(in: kbView) else { return }

        switch state {
        case .recording:
            micView._imageView.isHidden = true
            removeSpinner()
            if _waveformView == nil {
                let wv = AudioWaveformView(frame: micView.bounds.insetBy(dx: 4, dy: 6))
                wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                micView.addSubview(wv)
                _waveformView = wv
            }
        case .transcribing:
            micView._imageView.isHidden = true
            removeWaveform()
            if _micSpinner == nil {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.color = .label
                micView.addSubview(spinner)
                spinner.center = CGPoint(x: micView.bounds.midX, y: micView.bounds.midY)
                spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
                _micSpinner = spinner
            }
            _micSpinner?.startAnimating()
        default:
            removeSpinner()
            removeWaveform()
            micView._imageView.isHidden = false
            let symbolName = KBKeyValue.micSymbolName(for: state)
            micView._imageView.image = UIImage(systemName: symbolName)
            micView._imageView.tintColor = KBKeyValue.micTintColor(for: state)
        }
    }

    private func removeSpinner() {
        _micSpinner?.stopAnimating()
        _micSpinner?.removeFromSuperview()
        _micSpinner = nil
    }

    private func removeWaveform() {
        _waveformView?.stopAnimating()
        _waveformView?.removeFromSuperview()
        _waveformView = nil
    }
}

private enum AssociatedKeys {
    static var micSpinner = 0
    static var waveform = 0
}
