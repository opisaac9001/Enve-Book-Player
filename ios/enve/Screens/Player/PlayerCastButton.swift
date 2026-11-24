#if os(iOS) && canImport(GoogleCast)
@preconcurrency import GoogleCast
import SwiftUI
import UIKit

struct PlayerCastButton: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> GCKUICastButton {
        GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    }

    func updateUIView(_ button: GCKUICastButton, context: Context) {
        button.tintColor = UIColor(tint)
    }
}
#endif
