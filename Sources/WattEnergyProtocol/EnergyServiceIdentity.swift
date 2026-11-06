import Foundation
import Security

public enum EnergyServiceIdentity {
    public static func currentTeam(identifier:String)->String? {
        var code:SecCode?
        guard SecCodeCopySelf([], &code)==errSecSuccess,let code else {return nil}
        var staticCode:SecStaticCode?
        guard SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode else {return nil}
        var information:CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,
              let info=information as? [String:Any],info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let team=info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil,
              let requirement=makeRequirement(identifier:identifier,team:team),
              SecCodeCheckValidity(code,[],requirement)==errSecSuccess else {return nil}
        return team
    }
    public static func requirementString(identifier:String,team:String)->String {
        // Fixed bundle identifiers and a validated certificate team prevent requirement injection.
        precondition(identifier.range(of:"^[A-Za-z0-9.-]+$",options:.regularExpression) != nil)
        precondition(team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil)
        return #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
    }
    public static func validate(pid:pid_t,identifier:String,team:String)->Bool {
        guard pid>0,let requirement=makeRequirement(identifier:identifier,team:team) else {return false}
        var code:SecCode?
        let attributes=[kSecGuestAttributePid as String:NSNumber(value:pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil,attributes,[],&code)==errSecSuccess,let code else {return false}
        return SecCodeCheckValidity(code,[],requirement)==errSecSuccess
    }
    private static func makeRequirement(identifier:String,team:String)->SecRequirement? {
        var requirement:SecRequirement?
        guard SecRequirementCreateWithString(requirementString(identifier:identifier,team:team) as CFString,[],&requirement)==errSecSuccess else {return nil}
        return requirement
    }
}
