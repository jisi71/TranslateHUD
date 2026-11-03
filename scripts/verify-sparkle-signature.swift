import CryptoKit
import Foundation

let arguments = CommandLine.arguments

guard arguments.count == 4,
      let publicKey = Data(base64Encoded: arguments[1]), publicKey.count == 32,
      let signature = Data(base64Encoded: arguments[2]), signature.count == 64 else {
    fputs("Invalid Sparkle public key or signature.\n", stderr)
    exit(1)
}

do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Sparkle signature verification failed.\n", stderr)
        exit(1)
    }
    print("Sparkle signature verified against the bundled public key.")
} catch {
    fputs("Sparkle signature verification could not read the archive.\n", stderr)
    exit(1)
}
