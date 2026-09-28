import SwiftUI

/// Basic/Digest credentials belong to the connection; OAuth tokens are stored in Keychain.
struct OPDSSignInSheet: View {
    let document: OPDSAuthenticationDocument
    let connection: ServerConnection?
    let onSignedIn: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(EnveEngine.self) private var engine

    @State private var selectedFlow: OPDSAuthenticationFlow?
    @State private var login = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var flows: [OPDSAuthenticationFlow] { document.supportedFlows }

    private var flow: OPDSAuthenticationFlow? { selectedFlow ?? flows.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if flows.count > 1 { flowPicker }
                if let flow {
                    if flow.usesCredentialForm {
                        credentialForm(flow)
                    } else {
                        browserForm(flow)
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                links
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline("OPDS sign-in")
            Text(document.title)
                .font(.hearthScreenTitle)
                .foregroundStyle(hearth.text)
            if let summary = document.summary, !summary.isEmpty {
                Text(summary)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var flowPicker: some View {
        SourcesCard {
            Overline("How to sign in")
            ForEach(flows) { option in
                SettingsChoiceRow(
                    title: option.displayName,
                    caption: option.summary,
                    isSelected: flow?.id == option.id
                ) {
                    selectedFlow = option
                    errorMessage = nil
                }
            }
        }
    }

    private func credentialForm(_ flow: OPDSAuthenticationFlow) -> some View {
        SourcesCard {
            SourcesField(label: flow.loginLabel, text: $login)
            SourcesField(label: flow.passwordLabel, text: $password, secure: true)
            EmberButton(title: isWorking ? "Signing in…" : "Sign in", systemImage: nil, tint: nil) {
                Task { await signIn(with: flow) }
            }
            .disabled(isWorking || login.isEmpty || password.isEmpty)
            .opacity(isWorking || login.isEmpty || password.isEmpty ? 0.5 : 1)
        }
    }

    private func browserForm(_ flow: OPDSAuthenticationFlow) -> some View {
        SourcesCard {
            Text("This catalogue signs you in on its own website and hands Enve a token when you return.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            EmberButton(title: isWorking ? "Waiting…" : "Continue in browser", systemImage: "safari", tint: nil) {
                Task { await signInWithBrowser(flow) }
            }
            .disabled(isWorking)
            .opacity(isWorking ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var links: some View {
        if document.helpURL != nil || document.registerURL != nil {
            SourcesCard {
                if let help = document.helpURL {
                    Button("Help with this catalogue") { openURL(help) }
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.ember)
                }
                if let register = document.registerURL {
                    Button("Create an account") { openURL(register) }
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.ember)
                }
            }
        }
    }

    private func signIn(with flow: OPDSAuthenticationFlow) async {
        guard let connection else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            _ = try await OPDSAuthenticationService.shared.signIn(
                connectionId: connection.id,
                flow: flow,
                login: login,
                password: password,
                documentURL: document.documentURL,
                feedURL: OPDSProvider.feedURL(for: connection)
            )
            if flow.kind == .httpCredentials {
                var updated = connection
                updated.username = login
                updated.password = password
                updated.isConnected = true
                _ = try engine.sources.completeAuthenticatedConnection(updated)
            }
            finish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signInWithBrowser(_ flow: OPDSAuthenticationFlow) async {
        guard let connection else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            _ = try await OPDSAuthenticationService.shared.signInWithBrowser(
                connectionId: connection.id,
                flow: flow,
                documentURL: document.documentURL,
                feedURL: OPDSProvider.feedURL(for: connection)
            )
            finish()
        } catch OPDSAuthenticationError.cancelled {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        password = ""
        onSignedIn()
        dismiss()
    }
}
