//
//  CertificateManager.swift
//  TetherFramework
//
//  Self-signed X.509 certificate generation, Keychain identity management,
//  and SHA-256 fingerprint computation — all in pure Swift (no OpenSSL).
//
//  Shared between the main app and the Share Extension via a common
//  App Group (group.net.jeedup.Tether) and Keychain access group.
//

import Foundation
import Security
import CryptoKit

#if canImport(UIKit)
import UIKit
#endif

// Manages the app's TLS identity (self-signed RSA cert + private key)
// and the set of known remote host fingerprints.
//
// All Keychain items are stored in the shared access group so both the
// main app and the Share Extension can read them.
// All UserDefaults are stored in the shared App Group suite.
@Observable
public final class CertificateManager {
    // Shared App Group identifier — must match both targets' entitlements.
    //
    // xtool re-signs a sideloaded build with the bundle id and the app group both
    // prefixed "XTL-<id>.", so the group follows the prefix of the running bundle.
    public static let appGroupID: String = {
        let base = "net.jeedup.Tether"
        if let prefix = Bundle.main.bundleIdentifier?.split(separator: ".").first,
           prefix.hasPrefix("XTL-") {
            return "group.\(prefix).\(base)"
        }
        return "group.\(base)"
    }()

    // The Keychain access group entitlement uses $(AppIdentifierPrefix), which
    // the OS expands to your Team ID at runtime (e.g. "ABCDE12345.net.jeedup.Tether").
    // We resolve it dynamically so the correct string is used in both development
    // and TestFlight/App Store builds. Hardcoding would break distribution builds.
    private static let keychainAccessGroup: String = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.jeedup.Tether.__groupProbe",
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let attrs = item as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String {
            return group
        }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.jeedup.Tether.__groupProbe",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data([0]),
            kSecReturnAttributes as String: true,
        ]
        var addResult: CFTypeRef?
        SecItemAdd(addQuery as CFDictionary, &addResult)
        if let attrs = addResult as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String {
            return group
        }
        return "net.jeedup.Tether"
    }()

    private static let keyTag = "net.jeedup.Tether.key"
    private static let certLabel = "net.jeedup.Tether.cert"
    private static let certCommonName = "Tether-iOS"
    private static let knownHostsKey = "TetherKnownHosts"
    private static let localDeviceNameKey = "TetherLocalDeviceName"
    private static let lastConnectedFingerprintKey = "TetherLastConnectedFingerprint"

    // Shared UserDefaults suite backed by the App Group container.
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    // SHA-256 fingerprint of our own certificate (lowercase hex, no separators).
    public private(set) var myFingerprint: String = ""

    // Step and OSStatus of the last identity bootstrap failure, for diagnostics.
    public private(set) var lastIdentityError: String?

    // Map of known host fingerprints → device name.
    public private(set) var knownHosts: [String: String] = [:]

    // The fingerprint of the host we most recently connected to.
    public var lastConnectedFingerprint: String? {
        didSet {
            Self.sharedDefaults.set(lastConnectedFingerprint, forKey: Self.lastConnectedFingerprintKey)
        }
    }

    // Name of this device as presented to others.
    public var localDeviceName: String = "" {
        didSet {
            Self.sharedDefaults.set(localDeviceName, forKey: Self.localDeviceNameKey)
        }
    }

    // The `SecIdentity` used for mTLS client authentication.
    private var identity: SecIdentity?

    public init() {}

    // MARK: - Initialization

    // Load or create the TLS identity and populate known hosts.
    public func initialize() {
        lastIdentityError = nil
        loadKnownHosts()
        loadLocalDeviceName()
        lastConnectedFingerprint = Self.sharedDefaults.string(forKey: Self.lastConnectedFingerprintKey)

        if let existing = loadIdentityFromKeychain() {
            identity = existing
            myFingerprint = fingerprintFromIdentity(existing) ?? ""
            return
        }

        // First launch — generate a new self-signed identity.
        guard let newIdentity = generateAndStoreIdentity() else {
            return
        }
        identity = newIdentity
        myFingerprint = fingerprintFromIdentity(newIdentity) ?? ""
    }

    // Returns the `SecIdentity` for use with `Network.framework` TLS options.
    public func getIdentity() -> SecIdentity? {
        identity
    }

    // MARK: - Known Hosts

    public func isHostKnown(_ fingerprint: String) -> Bool {
        knownHosts[fingerprint] != nil
    }

    public func addKnownHost(fingerprint: String, name: String) {
        knownHosts[fingerprint] = name
        saveKnownHosts()
    }

    public func removeKnownHost(fingerprint: String) {
        knownHosts.removeValue(forKey: fingerprint)
        saveKnownHosts()
    }

    // MARK: - Fingerprint

    // Compute the SHA-256 fingerprint of a DER-encoded certificate.
    // Output matches the daemon's `generate_fingerprint`: lowercase hex, no separators.
    public static func fingerprint(ofCertificate cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: der)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private — Keychain

    // Record the failing bootstrap step so the UI can report it. The first failure of a
    // run is the most specific, so later ones do not overwrite it.
    @discardableResult
    private func identityFailure(_ step: String) -> SecIdentity? {
        if lastIdentityError == nil {
            lastIdentityError = step
        }
        print("CertificateManager: \(step)")
        return nil
    }

    // Identity searches do not reliably filter on key attributes, so enumerate the
    // identities in our access group and match on our certificate's common name.
    private func loadIdentityFromKeychain() -> SecIdentity? {
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var identityResult: CFTypeRef?
        guard SecItemCopyMatching(identityQuery as CFDictionary, &identityResult) == errSecSuccess,
              let identities = identityResult as? [SecIdentity]
        else {
            return nil
        }

        return identities.first { identity in
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
                return false
            }
            return (SecCertificateCopySubjectSummary(cert) as String?) == Self.certCommonName
        }
    }

    // The permanent private key from a previous launch, if one was stored.
    private func loadPrivateKeyFromKeychain() -> SecKey? {
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup,
            kSecReturnRef as String: true,
        ]
        var keyResult: CFTypeRef?
        guard SecItemCopyMatching(keyQuery as CFDictionary, &keyResult) == errSecSuccess else {
            return nil
        }
        return (keyResult as! SecKey)
    }

    private func fingerprintFromIdentity(_ identity: SecIdentity) -> String? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            return nil
        }
        return Self.fingerprint(ofCertificate: cert)
    }

    private func loadKnownHosts() {
        if let data = Self.sharedDefaults.data(forKey: Self.knownHostsKey),
           let hosts = try? JSONDecoder().decode([String: String].self, from: data)
        {
            knownHosts = hosts
        }
    }

    private func saveKnownHosts() {
        if let data = try? JSONEncoder().encode(knownHosts) {
            Self.sharedDefaults.set(data, forKey: Self.knownHostsKey)
        }
    }

    private func loadLocalDeviceName() {
        if let name = Self.sharedDefaults.string(forKey: Self.localDeviceNameKey) {
            localDeviceName = name
        } else {
            // Default name
            #if canImport(UIKit)
            localDeviceName = UIDevice.current.name
            #else
            localDeviceName = Host.current().localizedName ?? "Mac"
            #endif
        }
    }

    // MARK: - Private — Certificate Generation

    // Generate a 2048-bit RSA keypair + self-signed X.509v3 certificate and
    // store both in the Keychain in the shared access group as a `SecIdentity`.
    private func generateAndStoreIdentity() -> SecIdentity? {
        // 1. Generate RSA 2048 keypair in Keychain (shared access group)
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
                kSecAttrAccessGroup as String: Self.keychainAccessGroup,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ] as [String: Any],
        ]

        // Reuse the key left behind by a partial bootstrap: regenerating it would fail
        // with errSecDuplicateItem and leave the identity permanently unavailable.
        let privateKey: SecKey
        if let existingKey = loadPrivateKeyFromKeychain() {
            privateKey = existingKey
        } else {
            var error: Unmanaged<CFError>?
            guard let newKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
                let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
                return identityFailure("key generation failed: \(reason)")
            }
            privateKey = newKey
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return identityFailure("failed to derive public key")
        }

        // 2. Get public key PKCS#1 DER
        guard let pubKeyDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return identityFailure("failed to export public key")
        }

        // 3. Build self-signed X.509v3 certificate
        guard let certDER = buildSelfSignedCertificate(
            publicKeyDER: pubKeyDER,
            privateKey: privateKey,
            commonName: Self.certCommonName
        ) else {
            return identityFailure("failed to build certificate")
        }

        // 4. Import certificate into Keychain (shared access group).
        // Certificates carry no accessibility attribute; passing one fails with errSecParam.
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            return identityFailure("failed to create SecCertificate from DER")
        }

        // Drop a stale certificate from an earlier bootstrap so the stored one always
        // pairs with the key above.
        let staleCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: Self.certLabel,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup,
        ]
        SecItemDelete(staleCertQuery as CFDictionary)

        let addCertQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: Self.certLabel,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup,
        ]
        let addStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            return identityFailure("failed to add certificate to keychain: OSStatus \(addStatus)")
        }

        // 5. Retrieve the paired identity
        guard let identity = loadIdentityFromKeychain() else {
            return identityFailure("certificate stored but identity lookup failed")
        }
        return identity
    }

    // MARK: - ASN.1 DER Construction

    // Build a minimal self-signed X.509v3 certificate in DER format.
    private func buildSelfSignedCertificate(
        publicKeyDER: Data,
        privateKey: SecKey,
        commonName: String
    ) -> Data? {
        let now = Date()
        let tenYears = now.addingTimeInterval(315_360_000) // 10 years in seconds

        // OIDs
        let oidSHA256RSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        let oidRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let oidCN: [UInt8] = [0x55, 0x04, 0x03]

        // AlgorithmIdentifier: sha256WithRSAEncryption
        let sigAlgId = asn1Sequence(asn1OID(oidSHA256RSA) + asn1Null())

        // Name: CN=commonName
        let nameAttr = asn1Sequence(asn1OID(oidCN) + asn1UTF8String(commonName))
        let nameRDN = asn1Set(nameAttr)
        let name = asn1Sequence(nameRDN)

        // Validity
        let validity = asn1Sequence(asn1UTCTime(now) + asn1UTCTime(tenYears))

        // SubjectPublicKeyInfo
        let spkiAlg = asn1Sequence(asn1OID(oidRSA) + asn1Null())
        let spki = asn1Sequence(spkiAlg + asn1BitString(Array(publicKeyDER)))

        // Serial number (random 8 bytes)
        var serialBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        serialBytes[0] &= 0x7F // Ensure positive
        // A zero leading byte would make asn1Integer emit a non-minimal DER INTEGER.
        if serialBytes[0] == 0 { serialBytes[0] = 1 }

        // TBSCertificate
        let version = asn1ExplicitTag(0, asn1Integer([0x02])) // v3
        let serial = asn1Integer(serialBytes)

        let tbsContents = version + serial + sigAlgId + name + validity + name + spki
        let tbsDER = asn1Sequence(tbsContents)

        // Sign the TBSCertificate with the private key
        var signError: Unmanaged<CFError>?
        guard let signatureData = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(tbsDER) as CFData,
            &signError
        ) as Data? else {
            let reason = signError.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            identityFailure("signing failed: \(reason)")
            return nil
        }

        // Final Certificate structure
        let certContents = tbsDER + sigAlgId + asn1BitString(Array(signatureData))
        let certDER = asn1Sequence(certContents)

        return Data(certDER)
    }

    // MARK: - ASN.1 Primitives

    private func asn1Length(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }

    private func asn1Sequence(_ contents: [UInt8]) -> [UInt8] {
        [0x30] + asn1Length(contents.count) + contents
    }

    private func asn1Set(_ contents: [UInt8]) -> [UInt8] {
        [0x31] + asn1Length(contents.count) + contents
    }

    private func asn1Integer(_ value: [UInt8]) -> [UInt8] {
        var bytes = value
        // Ensure the integer is positive (leading bit must be 0)
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return [0x02] + asn1Length(bytes.count) + bytes
    }

    private func asn1BitString(_ contents: [UInt8]) -> [UInt8] {
        // Prepend the "unused bits" count (always 0 for byte-aligned data)
        let payload = [0x00] + contents
        return [0x03] + asn1Length(payload.count) + payload
    }

    private func asn1Null() -> [UInt8] {
        [0x05, 0x00]
    }

    private func asn1OID(_ oid: [UInt8]) -> [UInt8] {
        [0x06, UInt8(oid.count)] + oid
    }

    private func asn1UTF8String(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        return [0x0C] + asn1Length(bytes.count) + bytes
    }

    private func asn1UTCTime(_ date: Date) -> [UInt8] {
        let bytes = Array(Self.utcTimeString(date).utf8)
        return [0x17, UInt8(bytes.count)] + bytes
    }

    // YYMMDDHHMMSSZ, always Gregorian/UTC/ASCII digits.
    static func utcTimeString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!
        )
    }

    private func asn1ExplicitTag(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        let tagByte = 0xA0 | tag
        return [tagByte] + asn1Length(contents.count) + contents
    }
}
