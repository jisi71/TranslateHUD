enum TranslationAttemptPolicy {
    /// false = 普通 prompt；true = 严格 prompt。数组本身就是请求次数的唯一来源。
    static let attempts = [false, true]
    static var maximumAttempts: Int { attempts.count }

    static func shouldRetry(afterAttempt attemptIndex: Int, hasFailures: Bool) -> Bool {
        hasFailures && attemptIndex + 1 < maximumAttempts
    }
}
