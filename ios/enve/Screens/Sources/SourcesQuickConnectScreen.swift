import SwiftUI

struct SourcesQuickConnectScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var isProbing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var detected: DetectedServer?
    @State private var showingManual = false
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top, spacing: 14) {
                        GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                        VStack(alignment: .leading, spacing: 6) {
                            Overline("Bring your books")
                            Text("Sign in to your server")
                                .font(.hearthScreenTitle)
                                .foregroundStyle(hearth.text)
                        }
                        Spacer(minLength: 0)
                    }

                    SourcesCard {
                        Text("Enter your library's web address and Enve figures out the rest.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                        SourcesField(
                            label: "Server address",
                            text: $address,
                            placeholder: "books.example.com",
                            keyboard: .URL,
                            disabled: isProbing
                        )
                    }

                    if let statusMessage {
                        HStack(spacing: 8) {
                            ProgressView().tint(hearth.ember)
                            Text(statusMessage)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    }
                    if let errorMessage { SourcesErrorText(message: errorMessage) }

                    connectButton

                    VStack(spacing: 10) {
                        Text("Services like Plex and Real-Debrid have their own sign-in. Set those up here.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        QuietButton(title: "Set up manually", systemImage: "slider.horizontal.3") {
                            showingManual = true
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
                .hearthReadableFrame(width: geo.size.width, maximum: 980)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { probeTask?.cancel() }
        .sheet(item: $detected) { server in
            detectedLogin(for: server).enveEnvironment()
        }
        .sheet(isPresented: $showingManual) {
            NavigationStack { AddSourceScreen() }.enveEnvironment()
        }
    }

    private var connectButton: some View {
        Button {
            probeTask = Task { await connect() }
        } label: {
            HStack(spacing: 8) {
                if isProbing {
                    ProgressView().tint(hearth.onEmber)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.hearthUI(15, weight: .semibold))
                }
                Text("Connect")
                    .font(.hearthUI(16, weight: .semibold))
            }
            .foregroundStyle(hearth.onEmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hearth.ember, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(isProbing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
    }

    @ViewBuilder
    private func detectedLogin(for server: DetectedServer) -> some View {
        if server.providerType == .plex {
            SourcesPlexScreen(onAdded: { finish() })
        } else if let capability = ConnectionCapability.capability(for: server.providerType) {
            SourcesProviderFormScreen(
                capability: capability,
                prefilledURL: server.normalizedURL,
                autoStartAuth: server.recommendedAuth,
                onAdded: { finish() }
            )
        }
    }

    private func connect() async {
        errorMessage = nil
        statusMessage = "Looking for your server…"
        isProbing = true
        defer {
            isProbing = false
            statusMessage = nil
        }

        let outcome = await ServerProbe.detect(rawURL: address)
        guard !Task.isCancelled else { return }

        switch outcome {
        case .identified(let server):
            detected = server
        case .oidcIssuerOnly:
            errorMessage = "That looks like a sign-in page, not a library server. Enter your server's address instead."
        case .unknown:
            errorMessage = "We couldn't recognize that server. Use Set up manually to choose it yourself."
        case .unreachable:
            errorMessage = "Couldn't reach that address. Check the URL and that you're on the same network as the server."
        }
    }

    private func finish() {
        detected = nil
        dismiss()
    }
}
