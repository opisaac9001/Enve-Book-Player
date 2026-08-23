import UIKit

@MainActor
final class ReadiumFootnoteViewController: UIViewController {
    private let content: String
    private let referrer: String?

    init(content: String, referrer: String?) {
        self.content = content
        self.referrer = referrer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        navigationItem.title = Self.title(from: referrer)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.attributedText = Self.attributedText(from: content)
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 18, bottom: 28, right: 18)

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        preferredContentSize = CGSize(width: 560, height: 380)
    }

    private static func title(from referrer: String?) -> String {
        let candidate = referrer.map { plainText(from: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate,
            candidate.range(of: #"\p{L}{2}"#, options: .regularExpression) != nil
        else {
            return "Footnote"
        }
        return candidate
    }

    private static func plainText(from html: String) -> String {
        attributedText(from: html).string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attributedText(from html: String) -> NSAttributedString {
        guard let data = html.data(using: .utf8),
            let imported = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
        else {
            return NSAttributedString(
                string: html,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                ]
            )
        }
        let range = NSRange(location: 0, length: imported.length)
        let baseFont = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        imported.enumerateAttribute(.font, in: range) { value, attributeRange, _ in
            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let preserved = traits.intersection([.traitBold, .traitItalic])
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(preserved) ?? baseFont.fontDescriptor
            imported.addAttribute(
                .font,
                value: UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: 0)),
                range: attributeRange
            )
        }
        imported.addAttribute(.foregroundColor, value: UIColor.label, range: range)
        imported.enumerateAttribute(.link, in: range) { value, attributeRange, _ in
            guard value != nil else { return }
            imported.addAttributes(
                [
                    .foregroundColor: UIColor(red: 245 / 255, green: 146 / 255, blue: 26 / 255, alpha: 1),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: attributeRange
            )
        }
        return imported
    }
}
