// sign-update: print the Ed25519 signature (base64) and SHA-256 of a release file.
//
//   TERN_SIGNING_KEY=<base64 private key> sign-update FILE
//
// The key is read from the environment so it never appears in a process listing.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: sign-update FILE\n".data(using: .utf8)!)
    exit(2)
}
guard let base64 = ProcessInfo.processInfo.environment["TERN_SIGNING_KEY"],
      let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write("sign-update: TERN_SIGNING_KEY isn't a valid Ed25519 private key\n".data(using: .utf8)!)
    exit(1)
}
guard let data = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
    FileHandle.standardError.write("sign-update: can't read \(CommandLine.arguments[1])\n".data(using: .utf8)!)
    exit(1)
}
let signature = try key.signature(for: data)
let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
print("signature=\(signature.base64EncodedString())")
print("sha256=\(digest)")
print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
