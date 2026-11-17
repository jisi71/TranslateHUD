import Foundation

/// Split table cells without treating escaped or inline-code pipes as separators.
enum MarkdownTableCells {
    static func parse(_ line: String) -> [String] {
        var characters = Array(line.trimmingCharacters(in: .whitespaces))
        if characters.first == "|" { characters.removeFirst() }
        var cells: [String] = []
        var cell = ""
        var delimiterLength: Int?
        var index = 0
        var endedWithSeparator = false

        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                cell.append(character)
                index += 1
                cell.append(characters[index])
                endedWithSeparator = false
            } else if character == "`" {
                var end = index
                while end < characters.count, characters[end] == "`" { end += 1 }
                let length = end - index
                if delimiterLength == length {
                    delimiterLength = nil
                } else if delimiterLength == nil && hasClosingDelimiter(characters, from: end, length: length) {
                    delimiterLength = length
                }
                cell += String(repeating: "`", count: length)
                index = end - 1
                endedWithSeparator = false
            } else if character == "|", delimiterLength == nil {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                endedWithSeparator = true
            } else {
                cell.append(character)
                endedWithSeparator = false
            }
            index += 1
        }
        if !endedWithSeparator {
            cells.append(cell.trimmingCharacters(in: .whitespaces))
        }
        return cells
    }

    /// Match parse's escape and balanced-backtick semantics; code content stays literal.
    static func escapingCellPipes(_ value: String) -> String {
        let characters = Array(value)
        var result = "", delimiterLength: Int?, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                result.append(character)
                index += 1
                result.append(characters[index])
            } else if character == "`" {
                var end = index
                while end < characters.count, characters[end] == "`" { end += 1 }
                let length = end - index
                if delimiterLength == length { delimiterLength = nil }
                else if delimiterLength == nil && hasClosingDelimiter(characters, from: end, length: length) {
                    delimiterLength = length
                }
                result += String(repeating: "`", count: length)
                index = end - 1
            } else {
                if character == "|", delimiterLength == nil { result.append("\\") }
                result.append(character)
            }
            index += 1
        }
        return result
    }

    private static func hasClosingDelimiter(_ characters: [Character], from start: Int, length: Int) -> Bool {
        var index = start
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                index += 2
            } else if characters[index] == "`" {
                var end = index
                while end < characters.count, characters[end] == "`" { end += 1 }
                if end - index == length { return true }
                index = end
            } else {
                index += 1
            }
        }
        return false
    }
}
