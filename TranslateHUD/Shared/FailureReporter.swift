import Foundation

/// Fire-and-forget failure log. Posting never throws into the HUD, and a
/// logging failure is ignored so the toast or panel still shows the normal error.
@MainActor
enum FailureReporter {
    private static let countsKey = "failureReport.dailyCounts"
    private static var counts: [String: Int] = loadCounts()

    static func report(_ error: Error, surface: FailureEvent.Surface, path: FailureEvent.Path? = nil) {
        guard postsEnabled else { return }
        guard let event = FailureEvent.make(error: error, meta: liveMeta(surface: surface, path: path)) else { return }
        deliver(event)
    }

    static func reportSelection(_ result: SelectionFetchResult) {
        guard postsEnabled else { return }
        guard let event = FailureEvent.makeSelection(result, meta: liveMeta(surface: .selectionTranslate, path: nil)) else { return }
        deliver(event)
    }

    private static func deliver(_ event: FailureEvent) {
        var event = event
        guard FailureRateLimit.allow(
            kind: event.kind,
            surface: event.surface.rawValue,
            category: event.category,
            now: event.occurredAt,
            counts: &counts
        ) else { return }
        saveCounts()
        // Auth failures often mean the saved token is already dead. Sending it
        // would 401 and drop the record. Leave those anonymous.
        let token: String?
        if event.category == "permission" || event.category == "auth" {
            token = nil
            event.displayId = nil
        } else {
            token = TrialAccountStore.shared.freshAccessToken()
        }
        let payload = event
        let proxy = TrialAccountStore.shared.effectiveProxyBaseURL
        Task.detached(priority: .utility) {
            await FailureTransport.send(event: payload, token: token, proxyBase: proxy)
        }
    }

    private static func liveMeta(surface: FailureEvent.Surface, path: FailureEvent.Path?) -> FailureReportMeta {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let token = TrialAccountStore.shared.freshAccessToken()
        return FailureReportMeta(
            now: Date(),
            surface: surface,
            path: path ?? currentPath(),
            appVersion: version,
            appBuild: build,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            displayId: token == nil ? nil : TrialAccountStore.shared.displayId,
            deviceId: TrialConfig.deviceId
        )
    }

    private static func currentPath() -> FailureEvent.Path {
        let input = TranslationSession.currentInput(sourceText: nil)
        if TranslationRoute.endpoint(input) == .ownKey { return .ownKey }
        return .trial
    }

    private static var postsEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil { return false }
        if NSClassFromString("XCTestCase") != nil { return false }
        return true
    }

    private static func loadCounts() -> [String: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: countsKey) ?? [:]
        var counts: [String: Int] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber { counts[key] = number.intValue }
        }
        return counts
    }

    private static func saveCounts() {
        UserDefaults.standard.set(counts, forKey: countsKey)
    }
}

enum FailureTransport {
    static func endpoint(proxyBase: String) -> URL? {
        guard TranslationRoute.isUsableProxy(proxyBase),
              var components = URLComponents(string: proxyBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/trial/errors"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func send(event: FailureEvent, token: String?, proxyBase: String) async {
        guard let url = endpoint(proxyBase: proxyBase) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let body = try? FailureEvent.encode(event) else { return }
        request.httpBody = body
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            return
        }
    }
}
