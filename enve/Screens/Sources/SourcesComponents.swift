import Combine
import SwiftUI
import UIKit

struct SourcesCard<Content: View>: View {
    let content: Content
    @Environment(\.hearth) private var hearth

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                HearthChromeBackground(
                    shape: .rounded(Hearth.radiusCard),
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated,
                    interactive: false
                )
            }
    }
}

struct SourcesField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var disabled = false

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Overline(label)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                }
            }
            .font(.hearthBody)
            .foregroundStyle(hearth.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                HearthChromeBackground(
                    shape: .rounded(12),
                    fill: hearth.bg,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated
                )
            }
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
        }
    }
}

struct SourcesToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 12)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(hearth.ember)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
            if let subtitle {
                Text(subtitle)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }
}

struct SourcesProviderLogo: View {
    let assetName: String?
    let systemName: String
    var size: CGFloat = 36

    @Environment(\.hearth) private var hearth

    var body: some View {
        Group {
            if let assetName, UIImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                Image(systemName: systemName)
                    .font(.hearthUI(size * 0.42, weight: .medium))
                    .foregroundStyle(hearth.ember)
            }
        }
        .frame(width: size, height: size)
        .background {
            HearthChromeBackground(
                shape: .rounded(size * 0.28),
                fill: hearth.bg,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                interactive: false
            )
        }
    }
}

struct SourcesErrorText: View {
    let message: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        Text(message)
            .font(.hearthCaption)
            .foregroundStyle(hearth.statusError)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum SourcesURLScheme: String, CaseIterable {
    case https = "https://"
    case http = "http://"
}

struct SourcesCustomHeader: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}
