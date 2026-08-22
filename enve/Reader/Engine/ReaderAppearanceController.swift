import SwiftUI

@MainActor
final class ReaderAppearanceController {
    var onChange: (() -> Void)?
    var onApply: ((ClassicReaderAppearance) -> Void)?
    var onAppearanceChange: ((ClassicReaderAppearance) -> Void)?

    var appearance: ClassicReaderAppearance {
        willSet {
            if newValue != appearance {
                onChange?()
            }
        }
        didSet {
            guard oldValue != appearance else { return }
            scheduleUpdate()
        }
    }

    private(set) var systemColorScheme: ColorScheme
    private let persist: (ClassicReaderAppearance) -> Void
    private var updateTask: Task<Void, Never>?

    init(
        appearance: ClassicReaderAppearance = .load(),
        systemColorScheme: ColorScheme = .dark,
        persist: @escaping (ClassicReaderAppearance) -> Void = { $0.persist() },
        hasUsableFontFamily: (String) -> Bool = { ReaderFontLibrary.shared.hasUsableFontFamily(named: $0) }
    ) {
        let sanitized = Self.sanitize(appearance, hasUsableFontFamily: hasUsableFontFamily)
        self.appearance = sanitized
        self.systemColorScheme = systemColorScheme
        self.persist = persist
        if sanitized != appearance {
            persist(sanitized)
        }
    }

    var preferredColorScheme: ColorScheme? {
        guard appearance.themeMode == .fixed else { return nil }
        return appearance.theme == .midnight ? .dark : .light
    }

    var effectiveAppearance: ClassicReaderAppearance {
        appearance.resolved(for: systemColorScheme)
    }

    func updateSystemColorScheme(_ colorScheme: ColorScheme) {
        guard systemColorScheme != colorScheme else { return }
        let usesAutomaticTheme = appearance.themeMode == .automatic
        if usesAutomaticTheme {
            onChange?()
        }
        systemColorScheme = colorScheme
        if usesAutomaticTheme {
            onApply?(effectiveAppearance)
        }
    }

    func flushPendingUpdate() {
        guard updateTask != nil else { return }
        updateTask?.cancel()
        updateTask = nil
        commit(appearance)
    }

    private func scheduleUpdate() {
        updateTask?.cancel()
        let current = appearance
        updateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            updateTask = nil
            commit(current)
        }
    }

    private func commit(_ appearance: ClassicReaderAppearance) {
        persist(appearance)
        onApply?(appearance.resolved(for: systemColorScheme))
        onAppearanceChange?(appearance)
    }

    private static func sanitize(
        _ appearance: ClassicReaderAppearance,
        hasUsableFontFamily: (String) -> Bool
    ) -> ClassicReaderAppearance {
        guard appearance.usesCustomFont else { return appearance }
        guard let familyName = appearance.customFontFamilyName,
            !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasUsableFontFamily(familyName)
        else {
            var sanitized = appearance
            sanitized.usesCustomFont = false
            sanitized.customFontFamilyName = nil
            return sanitized
        }
        return appearance
    }
}
