import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSAcquisitionSelectionTests {
    private let base = URL(string: "https://catalog.example.invalid/opds/")!

    @Test func openAccessBeatsAPlainAcquisitionAndBothBeatAPurchase() throws {
        let links = [
            OPDSLink(href: "buy.epub", type: "application/epub+zip", rels: ["buy"]),
            OPDSLink(href: "direct.epub", type: "application/epub+zip", rels: ["http://opds-spec.org/acquisition"]),
            OPDSLink(href: "free.epub", type: "application/epub+zip", rels: ["open-access"]),
        ]

        let acquisition = try downloadable(links)

        #expect(acquisition.kind == .openAccess)
        #expect(acquisition.url.absoluteString == "https://catalog.example.invalid/opds/free.epub")
    }

    @Test(arguments: [
        ["buy"], ["borrow"], ["subscribe"], ["preview"], ["sample"],
        ["http://opds-spec.org/acquisition/buy"],
        ["http://opds-spec.org/acquisition/borrow"],
        ["http://opds-spec.org/acquisition/subscribe"],
        ["http://opds-spec.org/acquisition/sample"],
    ])
    func transactionalAndPreviewRelationsAreNeverTreatedAsDownloads(rels: [String]) {
        let selection = OPDSAcquisitionSelector.select(
            links: [OPDSLink(href: "book.epub", type: "application/epub+zip", rels: rels)],
            baseURL: base
        )

        guard case .rejected = selection else {
            Issue.record("\(rels) was accepted as a direct download")
            return
        }
    }

    @Test func aLinkCarryingBothOpenAccessAndBuyIsTreatedAsThePaidOne() {
        let selection = OPDSAcquisitionSelector.select(
            links: [OPDSLink(href: "book.epub", type: "application/epub+zip", rels: ["open-access", "buy"])],
            baseURL: base
        )

        guard case .rejected(let reason) = selection else {
            Issue.record("A buy relation was ignored because another relation looked permissive")
            return
        }
        #expect(reason.contains("purchase"))
    }

    @Test func aFormatOnlyLinkWithoutAnAcquisitionRelationStillDownloads() throws {
        let acquisition = try downloadable([OPDSLink(href: "book.epub", type: "application/epub+zip")])

        #expect(acquisition.kind == .direct)
        #expect(acquisition.format == .ebook(.epub))
    }

    @Test func coverImagesAreNeverSelectableAsAcquisitions() {
        let selection = OPDSAcquisitionSelector.select(
            links: [
                OPDSLink(href: "cover.jpg", type: "image/jpeg", rels: ["http://opds-spec.org/image"]),
                OPDSLink(href: "thumb.jpg", type: "image/jpeg", rels: ["http://opds-spec.org/image/thumbnail"]),
            ],
            baseURL: base
        )

        guard case .notAPublication = selection else {
            Issue.record("A cover image was offered as a download")
            return
        }
    }

    @Test func lcpAndAdobeProtectedAcquisitionsFailWithTheSchemeNamed() {
        let lcp = OPDSAcquisitionSelector.select(
            links: [
                OPDSLink(
                    href: "licence.lcpl",
                    type: "application/vnd.readium.lcp.license.v1.0+json",
                    rels: ["http://opds-spec.org/acquisition"],
                    properties: OPDSLinkProperties(
                        indirectAcquisition: [OPDSAcquisitionObject(type: "application/epub+zip")]
                    )
                )
            ],
            baseURL: base
        )
        let adobe = OPDSAcquisitionSelector.select(
            links: [
                OPDSLink(
                    href: "fulfil",
                    type: "application/atom+xml;type=entry;profile=opds-catalog",
                    rels: ["http://opds-spec.org/acquisition/borrow"],
                    properties: OPDSLinkProperties(
                        indirectAcquisition: [
                            OPDSAcquisitionObject(
                                type: "application/vnd.adobe.adept+xml",
                                children: [OPDSAcquisitionObject(type: "application/epub+zip")]
                            )
                        ]
                    )
                )
            ],
            baseURL: base
        )

        guard case .rejected(let lcpReason) = lcp, case .rejected(let adobeReason) = adobe else {
            Issue.record("A DRM-protected acquisition was accepted")
            return
        }
        #expect(lcpReason.contains("Readium LCP"))
        #expect(adobeReason.contains("Adobe DRM"))
    }

    @Test func aNestedIndirectChainResolvesToTheFileActuallyDelivered() throws {
        let acquisition = try downloadable([
            OPDSLink(
                href: "fulfil",
                type: "application/atom+xml;type=entry;profile=opds-catalog",
                rels: ["http://opds-spec.org/acquisition"],
                properties: OPDSLinkProperties(
                    indirectAcquisition: [
                        OPDSAcquisitionObject(
                            type: "application/zip",
                            children: [OPDSAcquisitionObject(type: "application/pdf")]
                        )
                    ]
                )
            )
        ])

        #expect(acquisition.format == .ebook(.pdf))
    }

    @Test func webpubDivinaAndAudiobookPackagesAreRecognisedButRefused() {
        for type in [
            "application/webpub+zip", "application/webpub+json",
            "application/divina+zip", "application/audiobook+zip", "application/audiobook+json",
        ] {
            let selection = OPDSAcquisitionSelector.select(
                links: [OPDSLink(href: "pub", type: type, rels: ["http://opds-spec.org/acquisition"])],
                baseURL: base
            )
            guard case .rejected(let reason) = selection else {
                Issue.record("\(type) was accepted as a readable publication")
                continue
            }
            #expect(reason.contains("not a format Enve can open"))
        }
    }

    @Test(arguments: [
        ("application/epub+zip", "epub"),
        ("application/pdf", "pdf"),
        ("application/vnd.comicbook+zip", "cbz"),
        ("application/x-cbz", "cbz"),
        ("application/vnd.comicbook-rar", "cbr"),
        ("application/x-cbr", "cbr"),
        ("application/x-mobipocket-ebook", "mobi"),
        ("application/x-mobi8-ebook", "azw3"),
        ("application/vnd.amazon.ebook", "azw3"),
        ("application/fb2+xml", "fb2"),
    ])
    func everySupportedEbookMIMEResolvesToItsFormat(type: String, expected: String) throws {
        let acquisition = try downloadable([
            OPDSLink(href: "book", type: type, rels: ["http://opds-spec.org/acquisition"])
        ])

        #expect(acquisition.format.ebookFormat?.rawValue == expected)
        #expect(acquisition.format.mediaType == .ebook)
    }

    @Test func audioAcquisitionsAreClassifiedAsAudiobooks() throws {
        let acquisition = try downloadable([
            OPDSLink(href: "chapter.m4b", type: "audio/mp4", rels: ["http://opds-spec.org/acquisition"])
        ])

        #expect(acquisition.format == .audio)
        #expect(acquisition.format.mediaType == .audiobook)
        #expect(acquisition.format.ebookFormat == nil)
    }

    @Test func anOpaqueBinaryTypeFallsBackToThePathExtension() throws {
        let acquisition = try downloadable([
            OPDSLink(href: "book.cbz", type: "application/octet-stream", rels: ["http://opds-spec.org/acquisition"])
        ])

        #expect(acquisition.format == .ebook(.cbz))
    }

    @Test func availabilityBlocksOnlyAnExplicitRefusal() throws {
        func selection(state: String) -> OPDSAcquisitionSelection {
            OPDSAcquisitionSelector.select(
                links: [
                    OPDSLink(
                        href: "book.epub",
                        type: "application/epub+zip",
                        rels: ["http://opds-spec.org/acquisition"],
                        properties: OPDSLinkProperties(availability: OPDSAvailability(state: state))
                    )
                ],
                baseURL: base
            )
        }

        for state in ["available", "ready", "something-new"] {
            guard case .downloadable = selection(state: state) else {
                Issue.record("availability state \(state) blocked an open publication")
                continue
            }
        }
        for state in ["unavailable", "reserved"] {
            guard case .rejected(let reason) = selection(state: state) else {
                Issue.record("availability state \(state) was ignored")
                continue
            }
            #expect(reason.contains(state))
        }
    }

    @Test func zeroPriceCopiesAndHoldsSurviveIntoTheRejectionMessage() throws {
        let purchase = OPDSAcquisitionSelector.select(
            links: [
                OPDSLink(
                    href: "book.epub",
                    type: "application/epub+zip",
                    rels: ["buy"],
                    properties: OPDSLinkProperties(price: OPDSPrice(currency: "USD", value: 0))
                )
            ],
            baseURL: base
        )
        let loan = OPDSAcquisitionSelector.select(
            links: [
                OPDSLink(
                    href: "book.epub",
                    type: "application/epub+zip",
                    rels: ["borrow"],
                    properties: OPDSLinkProperties(
                        holds: OPDSHolds(total: 0, position: 0),
                        copies: OPDSCopies(total: 3, available: 0)
                    )
                )
            ],
            baseURL: base
        )

        guard case .rejected(let purchaseReason) = purchase, case .rejected(let loanReason) = loan else {
            Issue.record("A transactional acquisition was accepted")
            return
        }
        #expect(purchaseReason.contains("0.00 USD"))
        #expect(loanReason.contains("0 of 3 copies available"))
        #expect(loanReason.contains("0 holds"))
        #expect(loanReason.contains("position 0 in the queue"))
    }

    @Test func propertiesDecodeFromTheOPDS2WireShape() throws {
        let link = try JSONDecoder().decode(
            OPDSLink.self,
            from: Data(
                """
                {"href":"/book","type":"application/epub+zip","rel":["http://opds-spec.org/acquisition/borrow","x-custom"],
                 "title":"Borrow","properties":{"price":{"currency":"EUR","value":0},
                 "copies":{"total":0,"available":0},"holds":{"total":0,"position":0},
                 "availability":{"state":"unavailable","detail":"All copies are out"},
                 "indirectAcquisition":[{"type":"application/vnd.adobe.adept+xml",
                 "child":[{"type":"application/epub+zip"}]}]}}
                """.utf8
            )
        )

        #expect(link.rels == ["http://opds-spec.org/acquisition/borrow", "x-custom"])
        #expect(link.title == "Borrow")
        #expect(link.type == "application/epub+zip")
        #expect(link.templated == false)
        #expect(link.properties?.price?.value == 0)
        #expect(link.properties?.price?.currency == "EUR")
        #expect(link.properties?.copies?.total == 0)
        #expect(link.properties?.copies?.available == 0)
        #expect(link.properties?.holds?.total == 0)
        #expect(link.properties?.holds?.position == 0)
        #expect(link.properties?.availability?.state == "unavailable")
        #expect(link.properties?.availability?.detail == "All copies are out")
        #expect(
            link.indirectAcquisitionTypes == [
                "application/vnd.adobe.adept+xml", "application/epub+zip",
            ]
        )
    }

    @Test func aSingleStringRelationDecodesIntoTheRelationArray() throws {
        let link = try JSONDecoder().decode(
            OPDSLink.self,
            from: Data(#"{"href":"/search{?q}","rel":"search","templated":true}"#.utf8)
        )

        #expect(link.rels == ["search"])
        #expect(link.templated)
    }

    @Test func templatedAcquisitionsAreNeverSelected() {
        let selection = OPDSAcquisitionSelector.select(
            links: [
                OPDSLink(
                    href: "book{?format}",
                    type: "application/epub+zip",
                    rels: ["http://opds-spec.org/acquisition"],
                    templated: true
                )
            ],
            baseURL: base
        )

        guard case .notAPublication = selection else {
            Issue.record("A templated acquisition URI was fetched verbatim")
            return
        }
    }

    @Test func nonHTTPSchemesAreRefused() {
        #expect(OPDSURL.resolve("mailto:librarian@example.invalid", baseURL: base) == nil)
        #expect(OPDSURL.resolve("file:///etc/passwd", baseURL: base) == nil)
        #expect(OPDSURL.resolve("/opds/page2", baseURL: base)?.absoluteString == "https://catalog.example.invalid/opds/page2")
    }

    private func downloadable(_ links: [OPDSLink]) throws -> OPDSAcquisition {
        guard case .downloadable(let acquisition) = OPDSAcquisitionSelector.select(links: links, baseURL: base) else {
            throw SelectionFailure()
        }
        return acquisition
    }

    private struct SelectionFailure: Error {}
}
