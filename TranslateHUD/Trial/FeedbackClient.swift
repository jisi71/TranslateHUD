import AppKit
import Foundation

enum FeedbackLimits {
    static let maxImages = 4
    static let maxTitle = 80
    static let maxBody = 2000
    /// Decoded JPEG the app will send. The service accepts up to 2 MB.
    static let maxImageBytes = 1_500_000
    static let maxSourceBytes = 20 * 1024 * 1024
    static let maxPixel: CGFloat = 1600
}

enum FeedbackCopy {
    static let success = "已提交，谢谢。"
    static let failed = "提交没有成功，请稍后再试。"
    static let needTitle = "请填写标题。"
    static let needBody = "请填写问题描述。"
    static let titleLong = "标题太长了，请缩短后再提交。"
    static let bodyLong = "描述太长了，请缩短后再提交。"
    static let tooManyImages = "最多添加 4 张图片。"
    static let imageBad = "图片格式无法使用，请换一张。"
    static let imageLarge = "有图片太大了，请换一张小一点的。"
    static let tooLarge = "这次提交太大了，请少传几张图片。"
    static let needLogin = "请先登录后再提交反馈。"
    static let auth = "登录已失效。请重新登录后再提交反馈。"
    static let dailyLimit = "今日反馈次数已达上限。"
    static let badJson = "提交内容无法读取，请稍后再试。"
    static let network = "网络不通，请稍后再试。"
    static let needProxy = "体验服务地址还没有，暂时交不了反馈。"
    static let badImagePick = "没有读到图片，请再选一次。"

    /// Codes match `backend/src/feedbackService.js`. The response sentence is not shown.
    static func message(for code: String?) -> String? {
        switch code?.lowercased() {
        case "feedback_title": return needTitle
        case "feedback_body": return needBody
        case "feedback_title_long": return titleLong
        case "feedback_body_long": return bodyLong
        case "feedback_image_count": return tooManyImages
        case "feedback_image_type": return imageBad
        case "feedback_image_large": return imageLarge
        case "feedback_too_large": return tooLarge
        case "feedback_store": return failed
        case "feedback_login": return needLogin
        case "feedback_auth": return auth
        case "feedback_daily_limit": return dailyLimit
        case "feedback_bad_json": return badJson
        default: return nil
        }
    }
}

struct FeedbackImagePayload: Equatable, Sendable {
    var jpeg: Data
}

struct FeedbackDraft: Equatable, Sendable {
    var title: String
    var body: String
    var appVersion: String
    var deviceId: String
    var images: [FeedbackImagePayload]
}

enum FeedbackValidation: Equatable {
    case ok
    case title
    case body
    case titleLong
    case bodyLong
    case images
}

struct FeedbackClientError: Error, Equatable {
    var message: String
}

enum FeedbackClient {
    static var appVersion: String {
        let short = bundleValue("CFBundleShortVersionString")
        let build = bundleValue("CFBundleVersion")
        if short.isEmpty { return build }
        if build.isEmpty || build == short { return short }
        return "\(short) (\(build))"
    }

    static func endpoint(proxyBase: String) -> URL? {
        guard TranslationRoute.isUsableProxy(proxyBase),
              var components = URLComponents(string: proxyBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/trial/feedback"
        return components.url
    }

    static func validate(_ draft: FeedbackDraft) -> FeedbackValidation {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .title }
        if title.count > FeedbackLimits.maxTitle { return .titleLong }
        if body.isEmpty { return .body }
        if body.count > FeedbackLimits.maxBody { return .bodyLong }
        if draft.images.count > FeedbackLimits.maxImages { return .images }
        return .ok
    }

    static func bodyData(for draft: FeedbackDraft) throws -> Data {
        let payload: [String: Any] = [
            "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            "body": draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
            "appVersion": draft.appVersion,
            "deviceId": draft.deviceId,
            "images": draft.images.map { image in
                [
                    "contentType": "image/jpeg",
                    "data": image.jpeg.base64EncodedString()
                ]
            }
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func submit(
        proxyBase: String,
        accessToken: String?,
        draft: FeedbackDraft,
        session: URLSession = .shared
    ) async throws {
        switch validate(draft) {
        case .ok:
            break
        case .title:
            throw FeedbackClientError(message: FeedbackCopy.needTitle)
        case .body:
            throw FeedbackClientError(message: FeedbackCopy.needBody)
        case .titleLong:
            throw FeedbackClientError(message: FeedbackCopy.titleLong)
        case .bodyLong:
            throw FeedbackClientError(message: FeedbackCopy.bodyLong)
        case .images:
            throw FeedbackClientError(message: FeedbackCopy.tooManyImages)
        }
        guard let accessToken, !accessToken.isEmpty else {
            throw FeedbackClientError(message: FeedbackCopy.needLogin)
        }
        guard let url = endpoint(proxyBase: proxyBase) else {
            throw FeedbackClientError(message: FeedbackCopy.needProxy)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try bodyData(for: draft)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FeedbackClientError(message: FeedbackCopy.network)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw FeedbackClientError(message: failureMessage(data: data))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            throw FeedbackClientError(message: FeedbackCopy.failed)
        }
    }

    static func failureMessage(data: Data) -> String {
        guard data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return FeedbackCopy.failed
        }
        let code = error["code"] as? String
        return FeedbackCopy.message(for: code) ?? FeedbackCopy.failed
    }

    private static func bundleValue(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") { return "" }
        return trimmed
    }
}

enum FeedbackImagePrep {
    struct Prepared: Equatable {
        var filename: String
        var jpeg: Data
    }

    enum Result: Equatable {
        case image(Prepared)
        case unreadable
        case tooLarge
    }

    static func classify(data: Data, filename: String) -> Result {
        if data.count > FeedbackLimits.maxSourceBytes { return .tooLarge }
        switch encode(data) {
        case .jpeg(let jpeg):
            let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            return .image(Prepared(filename: name.isEmpty ? "图片.jpg" : name, jpeg: jpeg))
        case .tooLarge:
            return .tooLarge
        case .unreadable:
            return .unreadable
        }
    }

    private enum Encoded {
        case jpeg(Data)
        case tooLarge
        case unreadable
    }

    private static func encode(_ data: Data) -> Encoded {
        guard let image = NSImage(data: data), image.isValid else { return .unreadable }
        let pixels = pixelSize(of: image)
        guard pixels.width >= 1, pixels.height >= 1 else { return .unreadable }
        var quality: CGFloat = 0.72
        var longestCap = FeedbackLimits.maxPixel
        var last: Data?
        for _ in 0..<4 {
            guard let jpeg = render(image, pixelSize: pixels, longestCap: longestCap, quality: quality) else {
                return .unreadable
            }
            last = jpeg
            if jpeg.count <= FeedbackLimits.maxImageBytes { return .jpeg(jpeg) }
            quality = max(0.35, quality - 0.15)
            longestCap *= 0.7
        }
        if let last, last.count <= FeedbackLimits.maxImageBytes { return .jpeg(last) }
        return last == nil ? .unreadable : .tooLarge
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        var widest: CGFloat = 0
        var tallest: CGFloat = 0
        for rep in image.representations {
            if rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                widest = max(widest, CGFloat(rep.pixelsWide))
                tallest = max(tallest, CGFloat(rep.pixelsHigh))
            }
        }
        if widest >= 1, tallest >= 1 { return CGSize(width: widest, height: tallest) }
        return image.size
    }

    private static func render(_ image: NSImage, pixelSize: CGSize, longestCap: CGFloat, quality: CGFloat) -> Data? {
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return nil }
        let scale = min(1, longestCap / longest)
        let width = max(1, Int((pixelSize.width * scale).rounded()))
        let height = max(1, Int((pixelSize.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 24
        ) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
