import Foundation

/// Local changes to bold runs, using AppKit's UTF-16 selection coordinates.
enum ScreenshotRunEditing {
    enum Failure: Error, Equatable {
        case invalidSelection
        case invalidRuns
    }

    static func setStrong(runs: [ScreenshotTextRun], text: String, selection: NSRange, strong: Bool) throws -> [ScreenshotTextRun] {
        guard let input = normalizedRuns(runs, text: text) else { throw Failure.invalidRuns }
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.location <= text.utf16.count,
              selection.length <= text.utf16.count - selection.location,
              let range = Range(selection, in: text),
              (range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound)),
              (range.upperBound == text.endIndex || text.indices.contains(range.upperBound)) else { throw Failure.invalidSelection }
        let selected = text[range]
        if strong && (selected.rangeOfCharacter(from: .newlines) != nil || selected.allSatisfy(\.isWhitespace)) {
            throw Failure.invalidSelection
        }
        var result: [ScreenshotTextRun] = []
        var buffer = ""
        var bufferStrong: Bool?
        var offset = 0
        for run in input {
            for character in run.text {
                let value = String(character), end = offset + value.utf16.count
                let isSelected = offset >= selection.location && end <= selection.location + selection.length
                let nextStrong = isSelected ? strong : run.isStrong
                if let current = bufferStrong, current != nextStrong {
                    result.append(ScreenshotTextRun(text: buffer, isStrong: current))
                    buffer = ""
                }
                bufferStrong = nextStrong
                buffer.append(character)
                offset = end
            }
        }
        if let current = bufferStrong, !buffer.isEmpty { result.append(.init(text: buffer, isStrong: current)) }
        guard let normalized = normalizedRuns(result, text: text) else { throw Failure.invalidRuns }
        return normalized
    }

    static func validRuns(_ runs: [ScreenshotTextRun], text: String) -> Bool {
        guard structurallyValid(runs, text: text) else { return false }
        return !runs.contains { $0.isStrong && $0.text.allSatisfy(\.isWhitespace) }
    }

    /// Whitespace alone has no visible weight and cannot form a Markdown bold span.
    static func normalizedRuns(_ runs: [ScreenshotTextRun], text: String) -> [ScreenshotTextRun]? {
        guard structurallyValid(runs, text: text) else { return nil }
        var result: [ScreenshotTextRun] = []
        var buffer = ""
        var bufferStrong: Bool?
        for run in runs {
            let nextStrong = run.isStrong && !run.text.allSatisfy(\.isWhitespace)
            if let current = bufferStrong, current != nextStrong {
                result.append(.init(text: buffer, isStrong: current))
                buffer = ""
            }
            bufferStrong = nextStrong
            buffer.append(contentsOf: run.text)
        }
        if let current = bufferStrong, !buffer.isEmpty { result.append(.init(text: buffer, isStrong: current)) }
        return result
    }

    private static func structurallyValid(_ runs: [ScreenshotTextRun], text: String) -> Bool {
        guard runs.map(\.text).joined().utf8.elementsEqual(text.utf8),
              runs.allSatisfy({ !$0.text.isEmpty }) else { return text.isEmpty && runs.isEmpty }
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text { offset += String(character).utf8.count; boundaries.insert(offset) }
        offset = 0
        for run in runs {
            if run.isStrong && run.text.rangeOfCharacter(from: .newlines) != nil && !run.text.allSatisfy(\.isWhitespace) { return false }
            offset += run.text.utf8.count
            guard boundaries.contains(offset) else { return false }
        }
        return true
    }
}
