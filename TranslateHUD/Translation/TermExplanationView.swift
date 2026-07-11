import SwiftUI

struct TermExplanationView: View {
    @ObservedObject var progress: TermExplanationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                progress.toggleExpanded()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: progress.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Image(systemName: "text.book.closed")
                    Text("名词解释")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if progress.isExpanded {
                explanationState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var explanationState: some View {
        switch progress.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在查找术语…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { progress.cancelRequest() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        case .success(let terms):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(terms) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.term)
                            .font(.callout.weight(.semibold))
                            .textSelection(.enabled)
                        Text(item.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .empty:
            Text("没有需要解释的专有名词或术语。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer()
                Button("重试") { progress.retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
