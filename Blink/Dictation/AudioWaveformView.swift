import UIKit

class AudioWaveformView: UIView {
    private let barCount = 5
    private let barSpacing: CGFloat = 2.5
    private var barLayers: [CALayer] = []
    private var targetHeights: [CGFloat]
    private var currentHeights: [CGFloat]
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        targetHeights = Array(repeating: 0.15, count: barCount)
        currentHeights = Array(repeating: 0.15, count: barCount)
        super.init(frame: frame)
        setupBars()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupBars() {
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = UIColor.systemRed.cgColor
            bar.cornerRadius = 1.5
            layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func layoutBars() {
        let totalSpacing = barSpacing * CGFloat(barCount - 1)
        let barWidth: CGFloat = 3
        let totalWidth = barWidth * CGFloat(barCount) + totalSpacing
        let startX = (bounds.width - totalWidth) / 2

        for (i, bar) in barLayers.enumerated() {
            let h = bounds.height * currentHeights[i]
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - h) / 2
            bar.frame = CGRect(x: x, y: y, width: barWidth, height: max(h, 3))
        }
    }

    func updateLevel(_ level: Float) {
        let clamped = CGFloat(max(0, min(1, level)))
        let minH: CGFloat = 0.15
        for i in 0..<barCount {
            // Center bars taller, edges shorter
            let centerBias: CGFloat = 1.0 - abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount) / 2) * 0.4
            let jitter = CGFloat.random(in: 0.85...1.15)
            targetHeights[i] = max(minH, clamped * centerBias * jitter)
        }
        startAnimating()
    }

    private func startAnimating() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(link:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc fileprivate func tick() {
        let smoothing: CGFloat = 0.3
        var settled = true
        for i in 0..<barCount {
            let diff = targetHeights[i] - currentHeights[i]
            if abs(diff) > 0.005 {
                currentHeights[i] += diff * smoothing
                settled = false
            } else {
                currentHeights[i] = targetHeights[i]
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBars()
        CATransaction.commit()

        if settled {
            stopAnimating()
        }
    }

    deinit {
        stopAnimating()
    }
}

private class DisplayLinkProxy {
    weak var target: AudioWaveformView?
    init(_ target: AudioWaveformView) { self.target = target }
    @objc func tick(link: CADisplayLink) {
        guard let target else { link.invalidate(); return }
        target.tick()
    }
}
