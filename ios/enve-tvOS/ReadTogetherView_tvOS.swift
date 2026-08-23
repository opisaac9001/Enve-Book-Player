import AVFoundation
import SwiftUI

struct ReadTogetherView_tvOS: View {
    @State private var receiver = CompanionReceiverService_tvOS.shared

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                switch receiver.state {
                case .idle, .discovering, .connected:

                    pairingPlaceholder
                case .error(let error):
                    errorView(error)
                }
            }
            .navigationTitle("Read together")
            .task {
                await receiver.startDiscovering()
            }
        }
    }

    private var pairingPlaceholder: some View {

        HStack(alignment: .top, spacing: 48) {
            VStack(spacing: 14) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 90))
                    .foregroundStyle(.tint)
                Text("Read together\nwith iPhone")
                    .font(.system(size: 36, weight: .bold))
                    .multilineTextAlignment(.center)
            }
            .frame(width: 360)

            VStack(alignment: .leading, spacing: 14) {
                Text("Books and comics are rendered on your iPhone and mirrored here. Keep your iPhone nearby with enve open.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                stepRow(number: 1, text: "On your iPhone, open enve and join the same Wi-Fi as this Apple TV.")
                stepRow(number: 2, text: "Open a book or comic, tap the ••• menu, then tap \"Read together on Apple TV.\"")
                stepRow(number: 3, text: "The page appears here. Swipe the Apple TV remote left or right to turn pages.")
                stepRow(number: 4, text: "Keep the iPhone unlocked with enve open - closing the book ends the session.")
                statusRow
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 80)
        .padding(.top, 160)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch receiver.state {
        case .discovering:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Looking for your iPhone on this Wi-Fi network…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        case .idle:
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text("Make sure both devices are on the same Wi-Fi network.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        default:
            EmptyView()
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                Text("\(number)")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.tint)
            }
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Lost connection")
                .font(.title)
            Text(error.localizedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)
            Button("Try again") {
                Task { await receiver.startDiscovering() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompanionSessionView_tvOS: View {

    private enum FocusTarget: Hashable {
        case page, play, previous, next, speed
    }

    @State private var receiver = CompanionReceiverService_tvOS.shared
    @FocusState private var focus: FocusTarget?
    @State private var infoBarVisible = false
    @State private var infoBarHideToken = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if case .connected(let session) = receiver.state {
                sessionContent(session: session)
            } else {

                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(2)
            }
        }
    }

    @ViewBuilder
    private func sessionContent(session: CompanionSession) -> some View {
        ZStack {
            pageImageLayer(session: session)

            if let highlight = session.activeHighlight, let pageImage = session.currentPageImage {
                GeometryReader { geo in
                    let imageRect = aspectFitRect(imageSize: pageImage.size, in: geo.size)
                    Rectangle()
                        .fill(Color.yellow.opacity(0.4))
                        .frame(
                            width: highlight.width * imageRect.width,
                            height: highlight.height * imageRect.height
                        )
                        .position(
                            x: imageRect.minX + (highlight.midX * imageRect.width),
                            y: imageRect.minY + (highlight.midY * imageRect.height)
                        )
                        .animation(.easeInOut(duration: 0.2), value: highlight)
                }
                .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .focusable()
                .focused($focus, equals: .page)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        receiver.sendPageCommand(.previous)
                    case .right:
                        receiver.sendPageCommand(.next)
                    case .down:
                        if session.hasMediaOverlay {
                            focus = .play
                        } else {
                            revealInfoBar()
                        }
                    default:
                        revealInfoBar()
                    }
                }
                .onTapGesture {
                    revealInfoBar()
                }

            VStack {
                Spacer()
                bottomBar(session: session)
                    .padding(.horizontal, 60)
                    .padding(.bottom, 50)
            }
            .opacity(infoBarVisible ? 1 : 0)
            .onMoveCommand { direction in
                if direction == .up {
                    focus = .page
                }
            }
        }
        .onAppear {
            revealInfoBar()
            claimInitialFocus()
        }
        .onChange(of: focus) { _, _ in
            revealInfoBar()
        }
        .onPlayPauseCommand {
            guard session.hasMediaOverlay else { return }
            receiver.sendReadAloudCommand(.togglePlay)
            revealInfoBar()
        }
    }

    @ViewBuilder
    private func pageImageLayer(session: CompanionSession) -> some View {
        if session.isVideoStreaming {
            CompanionVideoLayerView(displayLayer: receiver.videoDecoder.displayLayer)
                .ignoresSafeArea()
        } else if let pageImage = session.currentPageImage {
            Image(uiImage: pageImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .ignoresSafeArea()
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(2)
                Text("Waiting for the first page from \(session.deviceName)…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func claimInitialFocus() {
        focus = .page
        for delayMs in [50, 200, 500, 900] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                if focus == nil { focus = .page }
            }
        }
    }

    @ViewBuilder
    private func bottomBar(session: CompanionSession) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.bookTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Reading on \(session.deviceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.hasMediaOverlay {
                readAloudControls(session: session)
            }
        }
    }

    private func readAloudControls(session: CompanionSession) -> some View {
        HStack(spacing: 16) {
            readAloudButton(
                target: .play,
                systemName: session.isMediaOverlayPlaying ? "pause.fill" : "play.fill",
                label: session.isMediaOverlayPlaying ? "Pause" : "Play"
            ) {
                receiver.sendReadAloudCommand(.togglePlay)
            }
            readAloudButton(target: .previous, systemName: "backward.fill", label: "Previous") {
                receiver.sendReadAloudCommand(.previousClip)
            }
            readAloudButton(target: .next, systemName: "forward.fill", label: "Next") {
                receiver.sendReadAloudCommand(.nextClip)
            }
            readAloudButton(
                target: .speed,
                systemName: "speedometer",
                label: String(format: "%g×", session.mediaOverlaySpeed)
            ) {
                receiver.sendReadAloudCommand(.cycleSpeed)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func readAloudButton(
        target: FocusTarget,
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            revealInfoBar()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 26, weight: .semibold))
                Text(label)
                    .font(.caption2)
            }
            .frame(width: 96, height: 80)
        }
        .buttonStyle(.bordered)
        .focused($focus, equals: target)
    }

    private func revealInfoBar() {
        infoBarHideToken &+= 1
        let token = infoBarHideToken
        withAnimation(.easeInOut(duration: 0.25)) { infoBarVisible = true }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard token == infoBarHideToken else { return }
            withAnimation(.easeInOut(duration: 0.4)) { infoBarVisible = false }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0 && imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (containerSize.width - width) / 2
        let y = (containerSize.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CompanionReadingPromptSheet_tvOS: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 110))
                .foregroundStyle(.tint)

            Text("Read \(book.title) with iPhone")
                .font(.system(size: 40, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text("Apple TV can't render ebooks or comics on its own. Your iPhone renders each page and sends it here.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            VStack(alignment: .leading, spacing: 16) {
                instructionRow(number: 1, text: "Put your iPhone on the same Wi-Fi as this Apple TV.")
                instructionRow(number: 2, text: "Open this book in enve on your iPhone.")
                instructionRow(number: 3, text: "Tap the ••• menu, then \"Read together on Apple TV.\"")
                instructionRow(number: 4, text: "Open the \"Read together\" tab here, then swipe the remote to turn pages.")
            }
            .frame(maxWidth: 760)

            Button("Got it") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
        }
        .padding(60)
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                Text("\(number)")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.tint)
            }
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompanionVideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoLayerHostView {
        let view = VideoLayerHostView()
        view.backgroundColor = .black
        view.layer.addSublayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: VideoLayerHostView, context: Context) {}

    final class VideoLayerHostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}
