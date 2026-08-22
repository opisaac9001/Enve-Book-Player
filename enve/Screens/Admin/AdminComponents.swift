import SwiftUI
import UIKit

struct AdminSubScreen<Content: View>: View {
    let overline: String
    let title: String
    @ViewBuilder var content: Content

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 4) {
                        Overline(overline)
                        Text(title)
                            .font(.hearthDisplay(26))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                    }
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct AdminStat: View {
    let value: String
    let label: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.hearthDisplay(24))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdminInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color?

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            Spacer()
            Text(value)
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(valueColor ?? hearth.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(minHeight: 28)
    }
}

struct AdminTag: View {
    let text: String
    var color: Color?

    @Environment(\.hearth) private var hearth

    var body: some View {
        Text(text)
            .font(.hearthUI(11, weight: .semibold))
            .foregroundStyle(color ?? hearth.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((color ?? hearth.textSecondary).opacity(0.14), in: Capsule())
    }
}

struct AdminEmptyText: View {
    let text: String

    @Environment(\.hearth) private var hearth

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.hearthCaption)
            .foregroundStyle(hearth.textTertiary)
            .padding(.vertical, 6)
    }
}

struct AdminLoadingRow: View {
    let text: String

    @Environment(\.hearth) private var hearth

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(hearth.ember)
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .padding(.vertical, 8)
    }
}

struct AdminLinkRow<Destination: View>: View {
    let systemImage: String
    let title: String
    let caption: String
    @ViewBuilder var destination: Destination

    @Environment(\.hearth) private var hearth

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(hearth.emberSoft)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text(caption)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct AdminProgressLine: View {
    let fraction: Double

    @Environment(\.hearth) private var hearth

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(hearth.hairline)
                Capsule()
                    .fill(hearth.ember)
                    .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

struct AdminBars: View {
    let values: [Double]
    var height: CGFloat = 96

    @Environment(\.hearth) private var hearth

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { index in
                Capsule()
                    .fill(values[index] > 0 ? hearth.ember : hearth.hairline)
                    .frame(height: max(3, height * values[index] / peak))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

struct AdminRemoteThumb: View {
    let url: URL?
    let headers: [String: String]
    var width: CGFloat = 88
    var height: CGFloat = 128

    @Environment(\.hearth) private var hearth
    @State private var image: Image?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                .fill(hearth.bg)
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "book.closed")
                    .font(.hearthUI(18))
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
        .task(id: url) { await adminLoadThumb() }
    }

    private func adminLoadThumb() async {
        guard let url else { return }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let loaded = UIImage(data: data)
        else { return }
        image = Image(uiImage: loaded)
    }
}

extension View {

    func adminMessageAlert(error: Binding<String?>, success: Binding<String?>) -> some View {
        alert(
            "Server",
            isPresented: Binding(
                get: { error.wrappedValue != nil || success.wrappedValue != nil },
                set: { presented in
                    if !presented {
                        error.wrappedValue = nil
                        success.wrappedValue = nil
                    }
                }
            )
        ) {
            Button("OK") {
                error.wrappedValue = nil
                success.wrappedValue = nil
            }
        } message: {
            Text(error.wrappedValue ?? success.wrappedValue ?? "")
        }
    }
}

struct AdminActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.hearthUI(19, weight: .medium))
                    .foregroundStyle(tint ?? hearth.ember)
                Text(title)
                    .font(.hearthUI(12, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

struct AdminDestructiveButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.hearthUI(14, weight: .medium))
                }
                Text(title)
                    .font(.hearthUI(15, weight: .medium))
            }
            .foregroundStyle(hearth.statusError)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background {
                Capsule()
                    .fill(hearth.bgElevated)
                    .overlay(Capsule().strokeBorder(hearth.statusError.opacity(0.35), lineWidth: 1))
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct AdminSheet<Content: View>: View {
    let title: String
    let confirmTitle: String
    var confirmDisabled = false
    let onConfirm: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Overline("Server hub")
                        Text(title)
                            .font(.hearthDisplay(24))
                            .foregroundStyle(hearth.text)
                    }
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 12) {
                QuietButton(title: "Cancel") { dismiss() }
                Spacer()
                EmberButton(title: confirmTitle) { onConfirm() }
                    .disabled(confirmDisabled)
                    .opacity(confirmDisabled ? 0.45 : 1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .presentationDragIndicator(.visible)
    }
}

enum AdminFormat {

    static func hours(_ seconds: Double) -> String {
        HearthFormat.duration(seconds)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
