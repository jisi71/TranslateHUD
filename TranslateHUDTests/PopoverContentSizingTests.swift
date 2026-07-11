import AppKit
import SwiftUI
import XCTest
@testable import TranslateHUD

@MainActor
final class PopoverContentSizingTests: XCTestCase {
    func testShortContentUsesDynamicHeightBelowMaximum() {
        let size = fittingSize(original: "Hello world")

        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.height, 80)
        XCTAssertLessThan(size.height, PopoverContent.maxHeight)
    }

    func testLongContentIsClampedByScrollableHeight() {
        let original = Array(repeating: "A long selected line that must remain readable.", count: 80)
            .joined(separator: "\n")
        let size = fittingSize(original: original)

        XCTAssertTrue(size.height.isFinite)
        XCTAssertLessThanOrEqual(size.height, PopoverContent.maxHeight)
    }

    private func fittingSize(original: String) -> NSSize {
        let terms = TermExplanationProgress(
            explainer: EmptyTermExplainer(),
            texts: [original],
            language: .chinese
        )
        let view = PopoverContent(
            original: original,
            progress: TranslationProgress(),
            termProgress: terms,
            speech: SpeechController(),
            onCancel: {},
            onRetry: {}
        )
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: NSSize(
            width: PopoverContent.fixedWidth,
            height: PopoverContent.maxHeight
        ))
    }
}

private struct EmptyTermExplainer: TermExplainer {
    func explain(texts: [String], in language: TargetLanguage) async throws -> [TermExplanation] {
        []
    }
}
