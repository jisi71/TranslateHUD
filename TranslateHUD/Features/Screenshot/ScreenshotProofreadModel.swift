import Foundation

/// Edits stay local until the user accepts this snapshot.
struct ScreenshotProofreadModel {
    enum Content {
        case text(runs: [ScreenshotTextRun], heading: Int?)
        case table(ScreenshotTableEditModel)
    }

    struct Item: Identifiable {
        let id: UUID
        var content: Content
        init(id: UUID = UUID(), content: Content) { self.id = id; self.content = content }
    }

    enum EditError: Error { case invalidItem, invalidSelection, emptyDocument, unrenderable, sizeLimit }
    private(set) var items: [Item]
    private(set) var stylesNeedReview: Bool

    init(plan: ScreenshotTranslationPlan) throws {
        var droppedStyles = false
        items = try plan.blocks.map { block in
            switch block {
            case .text(let runs, let heading):
                let text = runs.map(\.text).joined()
                let normalized = ScreenshotRunEditing.normalizedRuns(runs, text: text)
                if normalized == nil { droppedStyles = true }
                return Item(content: .text(runs: normalized ?? (text.isEmpty ? [] : [.init(text: text, isStrong: false)]), heading: heading))
            case .table(let rows, let runs):
                let table = ScreenshotTable(rows: rows, normalizedBox: .zero, hasMergedCells: false)
                return Item(content: .table(try ScreenshotTableEditModel(table: table, cellRuns: runs)))
            }
        }
        stylesNeedReview = droppedStyles
    }

    mutating func setText(_ text: String, item id: UUID) throws {
        guard text.utf8.count <= 65_536 else { throw EditError.sizeLimit }
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .text(_, let heading) = items[index].content else { throw EditError.invalidItem }
        items[index].content = .text(runs: text.isEmpty ? [] : [.init(text: text, isStrong: false)], heading: heading)
    }

    mutating func setHeading(_ heading: Int?, item id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .text(let runs, _) = items[index].content else { throw EditError.invalidItem }
        items[index].content = .text(runs: runs, heading: heading)
    }

    mutating func setStrong(_ strong: Bool, selection: NSRange, item id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .text(let runs, let heading) = items[index].content else { throw EditError.invalidItem }
        let text = runs.map(\.text).joined()
        let result = try ScreenshotRunEditing.setStrong(runs: runs, text: text, selection: selection, strong: strong)
        items[index].content = .text(runs: result, heading: heading)
    }

    mutating func editTable(_ id: UUID, _ edit: (inout ScreenshotTableEditModel) throws -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .table(var table) = items[index].content else { throw EditError.invalidItem }
        try edit(&table)
        items[index].content = .table(table)
    }

    mutating func insertText(after id: UUID?) -> UUID {
        let item = Item(content: .text(runs: [], heading: nil))
        let index = id.flatMap { wanted in items.firstIndex { $0.id == wanted } }.map { $0 + 1 } ?? items.count
        items.insert(item, at: index)
        return item.id
    }

    mutating func insertTable(after id: UUID?) throws -> UUID {
        let table = try ScreenshotTableEditModel(rows: 2, columns: 2, normalizedBox: .zero)
        let item = Item(content: .table(table))
        let index = id.flatMap { wanted in items.firstIndex { $0.id == wanted } }.map { $0 + 1 } ?? items.count
        items.insert(item, at: index)
        return item.id
    }

    mutating func splitText(_ id: UUID, at selection: NSRange) throws -> UUID {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .text(let runs, let heading) = items[index].content else { throw EditError.invalidItem }
        let text = runs.map(\.text).joined()
        guard selection.length == 0, selection.location > 0, selection.location < text.utf16.count,
              let point = Range(selection, in: text)?.lowerBound,
              text.indices.contains(point) else { throw EditError.invalidSelection }
        var before: [ScreenshotTextRun] = [], after: [ScreenshotTextRun] = []
        var offset = 0
        for run in runs {
            for character in run.text {
                let part = String(character)
                if offset < selection.location { Self.append(part, strong: run.isStrong, to: &before) }
                else { Self.append(part, strong: run.isStrong, to: &after) }
                offset += part.utf16.count
            }
        }
        items[index].content = .text(runs: before, heading: heading)
        let next = Item(content: .text(runs: after, heading: nil))
        items.insert(next, at: index + 1)
        return next.id
    }

    mutating func mergeWithNext(_ id: UUID, separator: String = "") throws {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + 1),
              case .text(let first, let heading) = items[index].content,
              case .text(let second, _) = items[index + 1].content,
              separator == "" || separator == " " else { throw EditError.invalidItem }
        items[index].content = .text(runs: first + (separator.isEmpty ? [] : [.init(text: separator, isStrong: false)]) + second, heading: heading)
        items.remove(at: index + 1)
    }

    mutating func moveItem(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }

    mutating func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func plan() throws -> ScreenshotTranslationPlan {
        let blocks: [ScreenshotTranslationPlan.Block] = items.compactMap { item in
            switch item.content {
            case .text(let runs, let heading):
                return runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(runs: runs, heading: heading)
            case .table(let table):
                let snapshot = table.snapshot()
                return .table(rows: snapshot.table.rows, cellRuns: snapshot.cellRuns)
            }
        }
        let result = ScreenshotTranslationPlan(blocks: blocks)
        guard !result.sourceItems.isEmpty else { throw EditError.emptyDocument }
        guard result.sourceIsRepresentable else { throw EditError.unrenderable }
        return result
    }

    private static func append(_ text: String, strong: Bool, to runs: inout [ScreenshotTextRun]) {
        if let last = runs.last, last.isStrong == strong {
            runs[runs.count - 1] = .init(text: last.text + text, isStrong: strong)
        } else { runs.append(.init(text: text, isStrong: strong)) }
    }
}
