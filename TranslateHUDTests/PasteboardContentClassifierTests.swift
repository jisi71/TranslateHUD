import XCTest
@testable import TranslateHUD

final class PasteboardContentClassifierTests: XCTestCase {
    func testReadableTextWinsOverImageTypes() {
        let reading = PasteboardContentClassifier.classify(
            string: " 你好 ",
            typeIdentifiers: ["public.png", "public.utf8-plain-text"]
        )
        XCTAssertEqual(reading, .readableText("你好"))
    }

    func testImageTypesWithoutReadableText() {
        let identifiers = [
            "public.png",
            "public.tiff",
            "public.jpeg",
            "public.image",
            "public.heic",
            "NeXT TIFF v4.0 pasteboard type",
            "Apple PNG pasteboard type"
        ]
        for identifier in identifiers {
            XCTAssertEqual(
                PasteboardContentClassifier.classify(string: nil, typeIdentifiers: [identifier]),
                .image,
                identifier
            )
            XCTAssertEqual(
                PasteboardContentClassifier.classify(string: " \n\t ", typeIdentifiers: [identifier]),
                .image,
                identifier
            )
        }
    }

    func testImageTypeWithoutAStringStaysImageEvenIfOtherTypesArePresent() {
        XCTAssertEqual(
            PasteboardContentClassifier.classify(
                string: nil,
                typeIdentifiers: ["public.png", "public.html", "public.utf8-plain-text"]
            ),
            .image
        )
    }

    func testChangedPasteboardWithoutTextOrImageIsUnavailable() {
        XCTAssertEqual(
            PasteboardContentClassifier.classify(string: nil, typeIdentifiers: ["public.url"]),
            .noReadableText
        )
        XCTAssertEqual(
            PasteboardContentClassifier.classify(string: "   ", typeIdentifiers: []),
            .noReadableText
        )
    }
}
