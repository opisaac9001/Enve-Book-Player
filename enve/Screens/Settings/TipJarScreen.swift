import StoreKit
import SwiftUI

struct TipJarScreen: View {
    @Environment(\.hearth) private var hearth

    private var iap: IAPManager { .shared }

    @State private var purchasing: TipChoice?
    @State private var purchaseError: String?
    @State private var showingThanks = false

    private enum TipChoice: String, CaseIterable, Identifiable {
        case small, medium, large, generous

        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: "A coffee"
            case .medium: "A fancy coffee"
            case .large: "Very generous"
            case .generous: "Extremely generous"
            }
        }

        var caption: String {
            switch self {
            case .small: "Buy the developer a coffee"
            case .medium: "Make it a good one"
            case .large: "Real support for development"
            case .generous: "Honestly, thank you"
            }
        }

        var glyph: String {
            switch self {
            case .small: "cup.and.saucer"
            case .medium: "mug"
            case .large: "heart"
            case .generous: "star"
            }
        }

        var fallbackPrice: String {
            switch self {
            case .small: "$0.99"
            case .medium: "$2.99"
            case .large: "$4.99"
            case .generous: "$9.99"
            }
        }

        var productId: String {
            switch self {
            case .small: IAPManager.tipProductIDs[0]
            case .medium: IAPManager.tipProductIDs[1]
            case .large: IAPManager.tipProductIDs[2]
            case .generous: IAPManager.tipProductIDs[3]
            }
        }
    }

    var body: some View {
        SettingsScaffold(
            overline: "About",
            title: "Tip jar",
            subtitle: "Entirely optional. Every feature stays free either way."
        ) {
            SourcesCard {
                HStack(spacing: 12) {
                    Image(systemName: "flame")
                        .font(.hearthUI(20))
                        .foregroundStyle(hearth.ember)
                    Text("Tips help fund more time for new features, fixes, and care.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SourcesCard {
                Overline("Choose an amount")
                ForEach(TipChoice.allCases) { choice in
                    tipRow(choice)
                }
                if let purchaseError { SourcesErrorText(message: purchaseError) }
            }

            SourcesCard {
                Overline("The fine print")
                tipNote("One-time payment, never a subscription")
                tipNote("Handled securely by Apple")
                tipNote("All of it goes toward development")
            }
        }
        .alert("Thank you", isPresented: $showingThanks) {
            Button("You're welcome", role: .cancel) {}
        } message: {
            Text("Your support means a great deal, and keeps Enve growing.")
        }
        .onAppear {
            Task { await iap.loadProducts() }
        }
    }

    private func tipRow(_ choice: TipChoice) -> some View {
        Button {
            purchase(choice)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if purchasing == choice {
                        ProgressView().tint(hearth.ember)
                    } else {
                        Image(systemName: choice.glyph)
                            .font(.hearthUI(17))
                            .foregroundStyle(hearth.ember)
                    }
                }
                .frame(width: 36, height: 36)
                .background {
                    Circle()
                        .fill(hearth.emberSoft)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(choice.caption)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                Text(iap.resolvedTipProduct(for: choice.productId)?.displayPrice ?? choice.fallbackPrice)
                    .font(.hearthUI(16, weight: .bold))
                    .foregroundStyle(hearth.ember)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(purchasing != nil)
    }

    private func tipNote(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.hearthUI(12))
                .foregroundStyle(hearth.statusOK)
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private func purchase(_ choice: TipChoice) {
        purchasing = choice
        purchaseError = nil
        Task {
            do {
                try await iap.purchaseTip(productID: choice.productId)
                showingThanks = true
                PlatformHaptics.notification(.success)
            } catch let error as StoreError {
                if case .userCancelled = error {

                } else {
                    purchaseError = error.localizedDescription
                }
            } catch {
                purchaseError = error.localizedDescription
            }
            purchasing = nil
        }
    }
}
