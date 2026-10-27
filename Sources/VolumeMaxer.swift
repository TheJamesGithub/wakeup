import MediaPlayer
import SwiftUI
import UIKit

/// Invisible view that keeps the phone's media volume pinned at max while it's
/// on screen (the mission screen). Turning the volume down won't stick.
struct VolumeMaxer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        v.alpha = 0.0001
        v.isUserInteractionEnabled = false
        context.coordinator.start(with: v)
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var timer: Timer?

        func start(with view: MPVolumeView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak view] _ in
                guard let view else { return }
                guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
                if slider.value < 1.0 {
                    slider.setValue(1.0, animated: false)
                    slider.sendActions(for: .valueChanged)
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }
}
