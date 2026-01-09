import SwiftUI
import UIKit

struct MiniSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let thumbSize: CGFloat
    let trackHeight: CGFloat
    let onEditingChanged: (Bool) -> Void

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        thumbSize: CGFloat,
        trackHeight: CGFloat,
        onEditingChanged: @escaping (Bool) -> Void
    ) {
        _value = value
        self.range = range
        self.thumbSize = thumbSize
        self.trackHeight = trackHeight
        self.onEditingChanged = onEditingChanged
    }

    func makeUIView(context: Context) -> MiniUISlider {
        let slider = MiniUISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.trackHeight = trackHeight
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.setThumbImage(thumbImage(size: thumbSize), for: .normal)
        return slider
    }

    func updateUIView(_ uiView: MiniUISlider, context: Context) {
        uiView.minimumValue = Float(range.lowerBound)
        uiView.maximumValue = Float(range.upperBound)
        if uiView.value != Float(value) {
            uiView.value = Float(value)
        }
        if uiView.trackHeight != trackHeight {
            uiView.trackHeight = trackHeight
            uiView.setNeedsLayout()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onEditingChanged: onEditingChanged)
    }

    private func thumbImage(size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(ovalIn: rect)
            UIColor.label.setFill()
            path.fill()
        }
    }

    final class Coordinator: NSObject {
        private let value: Binding<Double>
        private let onEditingChanged: (Bool) -> Void

        init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
            self.value = value
            self.onEditingChanged = onEditingChanged
        }

        @objc func valueChanged(_ sender: UISlider) {
            value.wrappedValue = Double(sender.value)
        }

        @objc func touchDown(_ sender: UISlider) {
            onEditingChanged(true)
        }

        @objc func touchUp(_ sender: UISlider) {
            onEditingChanged(false)
        }
    }
}

final class MiniUISlider: UISlider {
    var trackHeight: CGFloat = 3

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let rect = super.trackRect(forBounds: bounds)
        return CGRect(x: rect.origin.x, y: bounds.midY - trackHeight / 2, width: rect.width, height: trackHeight)
    }
}
