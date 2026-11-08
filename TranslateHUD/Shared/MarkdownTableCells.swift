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
