import Foundation
import Security

enum TranslationAttemptPolicy {
    static let maximumAttempts = 2

    static func shouldRetry(afterAttempt attemptIndex: Int, hasFailures: Bool) -> Bool {
        hasFailures && attemptIndex + 1 < maximumAttempts
    }

    static func isTransientTLSFailure(_ error: Error, hasOutput: Bool = false) -> Bool {
        let error = error as NSError
        guard !hasOutput, error.domain == NSURLErrorDomain,
              error.code == URLError.secureConnectionFailed.rawValue else { return false }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let code = error.userInfo["_kCFStreamErrorCodeKey"] as? Int
            ?? underlying?.userInfo["_kCFStreamErrorCodeKey"] as? Int
        return code == Int(errSSLPeerBadRecordMac)
    }
}
