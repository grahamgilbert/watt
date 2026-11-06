import Foundation
import Security

// Apply the same production identity requirements used by both NSXPC peers.
// This checks every architecture without launching the app, helper, or any authorization UI.
func fail(_ message:String)->Never {
    FileHandle.standardError.write(Data((message+"\n").utf8));exit(1)
}
guard CommandLine.arguments.count==3 else {fail("Usage: verify-helper-signature.swift APP TEAM")}
let app=URL(fileURLWithPath:CommandLine.arguments[1])
let team=CommandLine.arguments[2]
guard team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil else {fail("Invalid Developer ID team.")}
let targets=[(app,"com.grahamgilbert.Watt"),
             (app.appendingPathComponent("Contents/Library/HelperTools/WattEnergyHelper"),"com.grahamgilbert.Watt.EnergyHelper")]
for (url,identifier) in targets {
    var code:SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL,[],&code)==errSecSuccess,let code else {fail("Cannot inspect signed code: \(identifier)")}
    let expression = #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
    var requirement:SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString,[],&requirement)==errSecSuccess,let requirement else {fail("Invalid release signing requirement.")}
    let flags=SecCSFlags(rawValue:kSecCSCheckAllArchitectures|kSecCSStrictValidate)
    let status=SecStaticCodeCheckValidity(code,flags,requirement)
    guard status==errSecSuccess else {fail("Developer ID requirement failed for \(identifier): \(status)")}
}
print("Verified Developer ID app/helper identifiers, team, and signatures across all architectures.")
