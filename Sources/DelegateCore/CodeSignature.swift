import Foundation
import Security

/// Podpis kodu programu agenta. Dla agentów bez sumy SHA-256 w rejestrze ważny podpis Developer ID
/// potwierdza wydawcę (np. „Google LLC”), co jest mocniejsze niż suma z wpisu, który ktoś mógł podmienić.
/// Podpis ad-hoc (bez certyfikatu) niczego nie potwierdza.
public struct CodeSignature: Sendable, Equatable {
    /// Podpis jest ważny i wystawiony certyfikatem Developer ID od Apple.
    public var isDeveloperID: Bool
    /// Nazwa z certyfikatu, np. „Developer ID Application: Google LLC (EQHXZ8M8AV)”.
    public var signer: String?
    public var teamID: String?

    /// Wydawca bez prefiksu i identyfikatora zespołu: „Google LLC”.
    public var publisher: String? {
        guard var s = signer else { return nil }
        if let r = s.range(of: "Developer ID Application: ") { s = String(s[r.upperBound...]) }
        if let team = teamID, s.hasSuffix(" (\(team))") { s = String(s.dropLast(team.count + 3)) }
        return s
    }

    /// Wymaganie Developer ID: łańcuch od Apple, pośredni certyfikat Developer ID, liść „Developer ID Application”.
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    public static func check(_ url: URL) -> CodeSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return CodeSignature(isDeveloperID: false, signer: nil, teamID: nil)
        }
        var requirement: SecRequirement?
        SecRequirementCreateWithString(developerIDRequirement as CFString, [], &requirement)
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let valid = SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let signer = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return CodeSignature(isDeveloperID: valid, signer: signer, teamID: team)
    }
}
