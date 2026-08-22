import AVKit
import SwiftUI
import UIKit

struct PlayerAirPlayButton: UIViewRepresentable {
    let tint: Color
    let activeTint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.backgroundColor = .clear
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(activeTint)
    }
}
