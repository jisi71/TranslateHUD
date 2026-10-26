import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FeedbackView: View {
    @ObservedObject private var trial = TrialAccountStore.shared
    @State private var title = ""
    @State private var bodyText = ""
    @State private var attachments: [FeedbackAttachment] = []
    @State private var picking = false
    @State private var submitting = false
    @State private var succeeded = false
    @State private var statusText = ""

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("问题描述", text: $bodyText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(5...12)
            }
            Section {
                ForEach(attachments) { item in
                    HStack(spacing: 8) {
                        Image(nsImage: item.preview)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(item.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button("移除") { remove(item.id) }
                            .buttonStyle(.bordered)
                            .disabled(submitting)
                    }
                }
                Button("添加图片") { picking = true }
                    .disabled(submitting || attachments.count >= FeedbackLimits.maxImages)
                Text("可以不附图片，最多 4 张。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(submitting ? "正在提交…" : "提交") {
                    Task { await submit() }
                }
                .disabled(submitting)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(succeeded ? Color.green : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("问题反馈")
        .disabled(submitting)
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .failure(let error):
                if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return }
                show(FeedbackCopy.badImagePick, success: false)
            case .success(let urls):
                addImages(from: urls)
            }
        }
    }

    private func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        if succeeded {
            succeeded = false
            statusText = ""
        }
    }

    private func addImages(from urls: [URL]) {
        let room = FeedbackLimits.maxImages - attachments.count
        guard room > 0 else {
            show(FeedbackCopy.tooManyImages, success: false)
            return
        }
        let overflow = urls.count > room
        var hadLarge = false
        var hadUnreadable = false
        var prepared: [FeedbackAttachment] = []
        for url in urls.prefix(room) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                hadUnreadable = true
                continue
            }
            switch FeedbackImagePrep.classify(data: data, filename: url.lastPathComponent) {
            case .image(let image):
                guard let preview = NSImage(data: image.jpeg) else {
                    hadUnreadable = true
                    continue
                }
                prepared.append(FeedbackAttachment(filename: image.filename, jpeg: image.jpeg, preview: preview))
            case .unreadable:
                hadUnreadable = true
            case .tooLarge:
                hadLarge = true
            }
        }
        attachments.append(contentsOf: prepared)
        if hadLarge {
            show(FeedbackCopy.imageLarge, success: false)
        } else if hadUnreadable {
            show(FeedbackCopy.imageBad, success: false)
        } else if overflow {
            show(FeedbackCopy.tooManyImages, success: false)
        } else if succeeded {
            succeeded = false
            statusText = ""
        }
    }

    @MainActor
    private func submit() async {
        let draft = FeedbackDraft(
            title: title,
            body: bodyText,
            appVersion: FeedbackClient.appVersion,
            deviceId: TrialConfig.deviceId,
            images: attachments.map { FeedbackImagePayload(jpeg: $0.jpeg) }
        )
        switch FeedbackClient.validate(draft) {
        case .ok:
            break
        case .title:
            show(FeedbackCopy.needTitle, success: false)
            return
        case .body:
            show(FeedbackCopy.needBody, success: false)
            return
        case .titleLong:
            show(FeedbackCopy.titleLong, success: false)
            return
        case .bodyLong:
            show(FeedbackCopy.bodyLong, success: false)
            return
        case .images:
            show(FeedbackCopy.tooManyImages, success: false)
            return
        }

        submitting = true
        defer { submitting = false }
        let token: String?
        if trial.isLoggedIn {
            do {
                token = try await trial.validAccessToken()
            } catch is CancellationError {
                return
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? FeedbackCopy.auth, success: false)
                return
            }
        } else {
            token = nil
        }
        do {
            try await FeedbackClient.submit(
                proxyBase: trial.effectiveProxyBaseURL,
                accessToken: token,
                draft: draft
            )
            title = ""
            bodyText = ""
            attachments = []
            show(FeedbackCopy.success, success: true)
        } catch is CancellationError {
            return
        } catch let error as FeedbackClientError {
            show(error.message, success: false)
        } catch {
            show(FeedbackCopy.network, success: false)
        }
    }

    private func show(_ text: String, success: Bool) {
        statusText = text
        succeeded = success
    }
}

struct FeedbackAttachment: Identifiable {
    let id = UUID()
    var filename: String
    var jpeg: Data
    var preview: NSImage
}
