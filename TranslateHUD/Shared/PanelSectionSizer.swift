import CoreGraphics

/// How a translation-panel section behaves when the body is taller than the screen allows.
enum PanelSectionRole: Equatable {
    /// Selected text. Capped on its own so a long source does not push the translation away.
    case source
    /// Streaming or finished translation. Grows with the text, then scrolls.
    case translation
    /// Loading, success, timeout, and error status. Kept whole until the text areas are at their floors.
    case status
    case actions
    /// Term explanations and the optional context / screenshot block.
    case extra
    case divider
}

struct PanelSectionMeasurement: Equatable {
    var role: PanelSectionRole
    var idealHeight: CGFloat
}

struct PanelHeightBudget: Equatable {
    /// Maximum outer window height.
    var panelMax: CGFloat
    /// Maximum height of the region between the header and the footer, including its padding.
    var bodyMax: CGFloat
    /// Maximum height of that region's content, after padding.
    var contentMax: CGFloat
    /// Maximum height of the source block even when the panel still has spare room.
    var sourceMax: CGFloat
}

enum PanelSectionSizer {
    /// Smallest viewport a section keeps while it still has taller content to scroll.
    /// Sections whose text is already shorter than this stay at their text height.
    static func floor(role: PanelSectionRole, ideal: CGFloat) -> CGFloat {
        let preferred: CGFloat
        switch role {
        case .source: preferred = 60
        case .translation: preferred = 72
        case .status: preferred = 44
        case .actions: preferred = 36
        case .extra: preferred = 40
        case .divider: preferred = 1
        }
        return min(max(ideal, 0), preferred)
    }

    static func stackedHeight(_ heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !heights.isEmpty else { return 0 }
        return heights.reduce(0, +) + spacing * CGFloat(heights.count - 1)
    }

    /// Assigns each section the height of its own content.
    /// Source is capped at `sourceCap`. Anything still past `limit` scrolls inside the
    /// translation, then the source, then extras, and only then the status message.
    static func resolve(
        sections: [PanelSectionMeasurement],
        limit: CGFloat,
        sourceCap: CGFloat,
        spacing: CGFloat
    ) -> [CGFloat] {
        guard !sections.isEmpty else { return [] }
        let usableLimit = (limit.isFinite && limit >= 0) ? limit : .greatestFiniteMagnitude
        let cap = (sourceCap.isFinite && sourceCap > 0) ? sourceCap : usableLimit

        var heights = sections.map { section -> CGFloat in
            let ideal = section.idealHeight.isFinite ? max(0, section.idealHeight) : 0
            switch section.role {
            case .source:
                return min(ideal, cap)
            case .divider:
                return ideal > 0 && ideal < 3 ? ideal : 1
            case .translation, .status, .actions, .extra:
                return ideal
            }
        }

        var overflow = stackedHeight(heights, spacing: spacing) - usableLimit
        if overflow > 0.5 {
            let order: [PanelSectionRole] = [.translation, .source, .extra, .status, .actions]
            for role in order where overflow > 0.5 {
                overflow = shrink(&heights, sections: sections, role: role, overflow: overflow)
            }
        }
        correctOverflow(&heights, sections: sections, limit: usableLimit, spacing: spacing)
        return heights
    }

    private static func shrink(
        _ heights: inout [CGFloat],
        sections: [PanelSectionMeasurement],
        role: PanelSectionRole,
        overflow: CGFloat
    ) -> CGFloat {
        let indexes = heights.indices.filter { sections[$0].role == role }
        let rooms = indexes.map { index in
            max(0, heights[index] - floor(role: role, ideal: sections[index].idealHeight))
        }
        let slack = rooms.reduce(0, +)
        guard slack > 0.5, overflow > 0 else { return overflow }
        let cut = min(overflow, slack)
        var remaining = cut
        for (offset, index) in indexes.enumerated() {
            let room = rooms[offset]
            guard room > 0, remaining > 0 else { continue }
            let isLast = offset == indexes.count - 1
            let share = cut * (room / slack)
            let delta = min(room, min(remaining, isLast ? remaining : share))
            heights[index] -= delta
            remaining -= delta
        }
        return overflow - (cut - remaining)
    }

    private static func correctOverflow(
        _ heights: inout [CGFloat],
        sections: [PanelSectionMeasurement],
        limit: CGFloat,
        spacing: CGFloat
    ) {
        var extra = stackedHeight(heights, spacing: spacing) - limit
        guard extra > 0.5 else { return }
        let indexes = heights.indices
            .filter { sections[$0].role != .divider && heights[$0] > 1 }
            .sorted { heights[$0] > heights[$1] }
        for index in indexes {
            guard extra > 0.5 else { break }
            let removable = max(0, heights[index] - 1)
            let delta = min(removable, extra)
            heights[index] -= delta
            extra -= delta
        }
    }
}
