import Foundation
import Security
import CryptoKit

/// Client side of the host's self-signed TLS: accept the server only if its
/// leaf certificate's SHA-256 matches the fingerprint pinned at pairing.
/// No CA, no hostname check — the fingerprint is the identity. Shared with
/// the iOS client.
final class PinnedTLSDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String
    /// What the server actually presented, for "security code" display / errors.
    private(set) var presentedFingerprint: String?

    init(fingerprint: String) {
        self.fingerprint = fingerprint.lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let presented = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        presentedFingerprint = presented
        if presented == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
