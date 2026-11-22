import SwiftUI
import UIKit

struct KSVideoSurfaceView: UIViewRepresentable {
    @ObservedObject var playerManager: PlayerEngineManager
    let mediaID: String
    let activeEngine: ActiveEngineKind
    let isAudioOnly: Bool

    func makeUIView(context: Context) -> PlayerHostUIView {
        let view = PlayerHostUIView()
        view.backgroundColor = .black
        playerManager.attachSurfaceView(into: view)
        return view
    }

    func updateUIView(_ uiView: PlayerHostUIView, context: Context) {
        playerManager.attachSurfaceView(into: uiView)
    }
}

final class PlayerHostUIView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.frame = bounds }
    }
}
