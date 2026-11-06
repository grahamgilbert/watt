import Foundation
import CryptoKit
let keyFile=URL(fileURLWithPath:CommandLine.arguments[1])
let plistFile=URL(fileURLWithPath:CommandLine.arguments[2])
guard let seed=Data(base64Encoded:try String(contentsOf:keyFile,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)),
      let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:plistFile),format:nil) as? [String:Any] else {fatalError("Invalid signing configuration")}
let key=try Curve25519.Signing.PrivateKey(rawRepresentation:seed)
guard info["SUPublicEDKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else {fatalError("Sparkle signing key does not match app public key")}
print("Sparkle signing key matches the app public key.")
