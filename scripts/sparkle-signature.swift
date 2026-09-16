import CryptoKit
import Foundation

// Verify one file against a Sparkle EdDSA signature and the public key this app
// ships in its own Info.plist.
//
// Sparkle only accepts an update whose downloaded bytes verify against
// `SUPublicEDKey`, so a release check that compares lengths alone cannot tell
// whether the upload is the file the feed describes: any same-sized file passes
// it and every client then refuses the update. This is the check that closes
// that gap, and it is written in Swift because the key and the signature are
// Ed25519 and CryptoKit is already part of the toolchain that builds the app —
// the system `openssl` on macOS cannot verify Ed25519 at all.
//
// Usage: sparkle-signature <info.plist> <base64 signature> <file>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sparkle-signature: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: sparkle-signature <info.plist> <base64 signature> <file>")
}

let plistPath = arguments[1]
let signatureBase64 = arguments[2]
let filePath = arguments[3]

guard let plistData = FileManager.default.contents(atPath: plistPath),
      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
      let dictionary = plist as? [String: Any],
      let publicKeyBase64 = dictionary["SUPublicEDKey"] as? String else {
    fail("\(plistPath) does not carry an SUPublicEDKey string")
}

guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
    fail("SUPublicEDKey is not base64")
}
guard let signature = Data(base64Encoded: signatureBase64) else {
    fail("the signature is not base64: \(signatureBase64)")
}
guard let fileData = FileManager.default.contents(atPath: filePath) else {
    fail("cannot read \(filePath)")
}

let key: Curve25519.Signing.PublicKey
do {
    key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
} catch {
    fail("SUPublicEDKey is not an Ed25519 public key: \(error)")
}

// Ed25519 verification is over the whole file, which is what Sparkle hashes
// when it accepts an update.
guard key.isValidSignature(signature, for: fileData) else {
    fail("\(filePath) does not carry the signature \(signatureBase64.prefix(16))… for the key in \(plistPath)")
}

print("verified signature: \(filePath) (\(fileData.count) bytes, key \(publicKeyBase64))")
