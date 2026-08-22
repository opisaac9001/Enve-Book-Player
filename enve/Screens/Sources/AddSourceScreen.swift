import SwiftUI

struct AddSourceScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var selected: AddSourceProvider?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top, spacing: 14) {
                        GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                        VStack(alignment: .leading, spacing: 6) {
                            Overline("Bring your books")
                            Text("Add a source")
                                .font(.hearthScreenTitle)
                                .foregroundStyle(hearth.text)
                        }
                        Spacer(minLength: 0)
                    }

                    grid(
                        title: "Media servers",
                        providers: [
                            .audiobookshelf, .plex, .jellyfin, .emby, .grimmory,
                            .storyteller, .silo, .komga, .kavita, .bookOrbit, .opds,
                        ],
                        width: HearthAdaptive.contentWidth(for: geo.size.width, maximum: 980)
                    )
                    grid(
                        title: "Storage & cloud",
                        providers: [.webdav, .torbox, .premiumize, .realdebrid, .smb],
                        width: HearthAdaptive.contentWidth(for: geo.size.width, maximum: 980)
                    )
                    grid(
                        title: "Cloud drives",
                        providers: [.icloudDrive],
                        width: HearthAdaptive.contentWidth(for: geo.size.width, maximum: 980)
                    )
                    grid(
                        title: "On this device",
                        providers: [.files],
                        width: HearthAdaptive.contentWidth(for: geo.size.width, maximum: 980)
                    )
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
        .sheet(item: $selected) { provider in
            AddSourceRouter(provider: provider) {
                selected = nil
                dismiss()
            }
            .enveEnvironment()
        }
    }

    private func grid(title: String, providers: [AddSourceProvider], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline(title)
            LazyVGrid(columns: HearthAdaptive.gridColumns(width: width, minimum: 138, maximum: 5, compactFallback: 3), spacing: 12) {
                ForEach(providers) { provider in
                    AddSourceTile(provider: provider) {
                        PlatformHaptics.selection()
                        selected = provider
                    }
                }
            }
        }
    }
}

enum AddSourceProvider: String, CaseIterable, Identifiable {
    case audiobookshelf, plex, jellyfin, emby, grimmory, storyteller, silo
    case komga, kavita, bookOrbit, opds
    case webdav, torbox, premiumize, realdebrid, smb
    case googleDrive, dropbox, icloudDrive
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audiobookshelf: "Audiobookshelf"
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .grimmory: "Grimmory"
        case .storyteller: "Storyteller"
        case .silo: "Silo"
        case .komga: "Komga"
        case .kavita: "Kavita"
        case .bookOrbit: "BookOrbit"
        case .opds: "OPDS"
        case .webdav: "WebDAV"
        case .torbox: "TorBox"
        case .premiumize: "Premiumize"
        case .realdebrid: "Real-Debrid"
        case .smb: "SMB share"
        case .googleDrive: "Google Drive"
        case .dropbox: "Dropbox"
        case .icloudDrive: "iCloud Drive"
        case .files: "Files"
        }
    }

    var assetIconName: String? {
        switch self {
        case .audiobookshelf: ProviderType.audiobookshelf.assetIconName
        case .plex: ProviderType.plex.assetIconName
        case .jellyfin: ProviderType.jellyfin.assetIconName
        case .emby: ProviderType.emby.assetIconName
        case .grimmory: ProviderType.booklore.assetIconName
        case .storyteller: ProviderType.storyteller.assetIconName
        case .silo: ProviderType.silo.assetIconName
        case .komga: ProviderType.komga.assetIconName
        case .kavita: ProviderType.kavita.assetIconName
        case .bookOrbit: ProviderType.bookOrbit.assetIconName
        case .opds: ProviderType.opds.assetIconName
        case .webdav: UnifiedWebDAVPreset.generic.assetIconName
        case .torbox: ProviderType.torbox.assetIconName
        case .premiumize: UnifiedWebDAVPreset.premiumize.assetIconName
        case .realdebrid: UnifiedWebDAVPreset.realdebrid.assetIconName
        case .smb, .googleDrive, .dropbox, .icloudDrive, .files: nil
        }
    }

    var systemIconName: String {
        switch self {
        case .webdav: "externaldrive.connected.to.line.below.fill"
        case .torbox: ProviderType.torbox.iconName
        case .smb: "externaldrive.connected.to.line.below"
        case .googleDrive: "internaldrive"
        case .dropbox: "shippingbox.fill"
        case .icloudDrive: "icloud"
        case .files: "folder"
        case .grimmory: ProviderType.booklore.iconName
        case .silo: ProviderType.silo.iconName
        default: ProviderType(rawValue: rawValue)?.iconName ?? "server.rack"
        }
    }

    var capability: ConnectionCapability? {
        switch self {
        case .audiobookshelf: .audiobookshelf
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .grimmory: .booklore
        case .storyteller: .storyteller
        case .silo: .silo
        case .komga: .komga
        case .kavita: .kavita
        case .bookOrbit: .bookOrbit
        case .opds: .opds
        case .webdav, .premiumize, .realdebrid: .webdav
        case .torbox: .torbox
        case .plex, .smb, .googleDrive, .dropbox, .icloudDrive, .files: nil
        }
    }

    var cloudDrive: SourcesCloudScreen.Drive? {
        switch self {
        case .googleDrive: .googleDrive
        case .dropbox: .dropbox
        case .icloudDrive: .icloud
        default: nil
        }
    }

    var webdavPreset: UnifiedWebDAVPreset? {
        switch self {
        case .webdav: .generic
        case .premiumize: .premiumize
        case .realdebrid: .realdebrid
        default: nil
        }
    }
}

private struct AddSourceTile: View {
    let provider: AddSourceProvider
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                SourcesProviderLogo(assetName: provider.assetIconName, systemName: provider.systemIconName, size: 44)
                Text(provider.title)
                    .font(.hearthUI(12, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(PressableStyle())
    }
}

private struct AddSourceRouter: View {
    let provider: AddSourceProvider
    let onAdded: () -> Void

    var body: some View {
        if let capability = provider.capability {
            SourcesProviderFormScreen(
                capability: capability,
                initialPreset: provider.webdavPreset,
                onAdded: onAdded
            )
        } else if let drive = provider.cloudDrive {
            SourcesCloudScreen(drive: drive, onAdded: onAdded)
        } else {
            switch provider {
            case .plex:
                SourcesPlexScreen(onAdded: onAdded)
            case .smb:
                SourcesSMBScreen(onAdded: onAdded)
            case .files:
                SourcesFilesScreen(onAdded: onAdded)
            default:
                EmptyView()
            }
        }
    }
}
