/**
 在宿主导出项目签名身份，在虚拟机创建和删除单轮专用签名钥匙串。
 日常入口禁止交互；一次性宿主初始化允许系统授权。密码与 PKCS#12 只经标准输入输出传递。
 */

import CryptoKit
import Darwin
import Foundation
import Security

private struct SigningFailure: Error, CustomStringConvertible {
    let description: String
}

private struct ExportInput: Decodable {
    let passphrase: String
}

private struct ImportInput: Decodable {
    let p12base64: String
    let passphrase: String
    let keychainPassword: String
    let team: String
    let certificateChain: [String]
}

private struct InspectInput: Decodable {
    let p12base64: String
    let passphrase: String
    let team: String
}

private struct UnlockInput: Decodable {
    let keychainPassword: String
}

private struct ExportResult: Encodable {
    let fingerprint: String
    let p12base64: String
}

private struct IdentityResult: Encodable {
    let fingerprint: String
    let codeSigningIdentity: String
    let certificateChain: [String]
}

private func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        let explanation = SecCopyErrorMessageString(status, nil) as String? ?? "Security error"
        throw SigningFailure(description: "\(operation) failed (\(status)): \(explanation).")
    }
}

private func input<Value: Decodable>(_ type: Value.Type) throws -> Value {
    do {
        return try JSONDecoder().decode(type, from: FileHandle.standardInput.readDataToEndOfFile())
    } catch {
        throw SigningFailure(description: "Standard input must contain the required signing JSON fields.")
    }
}

private func output<Value: Encodable>(_ value: Value) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

private func certificate(of identity: SecIdentity) throws -> SecCertificate {
    var result: SecCertificate?
    try checked(SecIdentityCopyCertificate(identity, &result), "Read identity certificate")
    guard let result else { preconditionFailure("Security returned no certificate after success") }
    return result
}

private func fingerprint(of certificate: SecCertificate) -> String {
    SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
}

/// Subject 字段通过 OID 定位，避免依赖证书摘要里的显示名称或本地化标签。
private func organizationalUnits(of certificate: SecCertificate) throws -> [String] {
    let subjectOID = kSecOIDX509V1SubjectName as String
    let unitOID = kSecOIDOrganizationalUnitName as String
    guard let values = SecCertificateCopyValues(
        certificate, [kSecOIDX509V1SubjectName] as CFArray, nil
    ) as? [String: Any],
          let subject = values[subjectOID] as? [String: Any],
          let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]] else {
        throw SigningFailure(description: "Could not read certificate subject fields.")
    }
    return fields.compactMap { field in
        guard field[kSecPropertyKeyLabel as String] as? String == unitOID else { return nil }
        return field[kSecPropertyKeyValue as String] as? String
    }
}

private func validateTeam(_ team: String) throws {
    guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
        throw SigningFailure(description: "Project Team must be a ten-character Apple Team identifier.")
    }
}

/// 验证当前代码签名信任、项目身份，以及证书公钥和可签名私钥确实匹配。
private func validateIdentity(
    _ identity: SecIdentity,
    team: String,
    chain: [SecCertificate]
) throws -> IdentityResult {
    try validateTeam(team)
    let certificate = try certificate(of: identity)
    var commonName: CFString?
    try checked(SecCertificateCopyCommonName(certificate, &commonName), "Read certificate name")
    guard (commonName as String?)?.hasPrefix("Apple Development:") == true,
          try organizationalUnits(of: certificate).contains(team) else {
        throw SigningFailure(description: "Signing identity is not an Apple Development certificate for the project Team.")
    }

    var trust: SecTrust?
    var certificates = [certificate]
    for candidate in chain where !certificates.contains(where: { CFEqual($0, candidate) }) {
        certificates.append(candidate)
    }
    let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil)!
    try checked(SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust), "Create signing certificate trust")
    guard let trust else { preconditionFailure("Security returned no trust after success") }
    try checked(SecTrustSetNetworkFetchAllowed(trust, false), "Disable certificate network lookup")
    try checked(SecTrustSetVerifyDate(trust, Date() as CFDate), "Set current certificate verification date")
    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError) else {
        let reason = trustError.map { CFErrorCopyDescription($0) as String } ?? "unknown trust failure"
        throw SigningFailure(description: "Identity certificate is not currently trusted for code signing: \(reason).")
    }

    var privateKey: SecKey?
    try checked(SecIdentityCopyPrivateKey(identity, &privateKey), "Read signing private key")
    guard let privateKey, let publicKey = SecCertificateCopyKey(certificate) else {
        throw SigningFailure(description: "Signing identity must include its certificate and private key.")
    }
    let algorithms: [SecKeyAlgorithm] = [.rsaSignatureMessagePKCS1v15SHA256, .ecdsaSignatureMessageX962SHA256]
    guard let algorithm = algorithms.first(where: {
        SecKeyIsAlgorithmSupported(privateKey, .sign, $0) && SecKeyIsAlgorithmSupported(publicKey, .verify, $0)
    }) else {
        throw SigningFailure(description: "Signing identity key algorithm is not supported.")
    }
    let challenge = Data("ECMenu disposable VM identity verification".utf8) as CFData
    guard let signature = SecKeyCreateSignature(privateKey, algorithm, challenge, nil),
          SecKeyVerifySignature(publicKey, algorithm, challenge, signature, nil) else {
        throw SigningFailure(description: "Signing private key does not match its certificate or cannot sign without authorization.")
    }
    guard let verifiedChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
        preconditionFailure("Security returned no certificate chain after successful trust evaluation")
    }
    return IdentityResult(
        fingerprint: fingerprint(of: certificate),
        codeSigningIdentity: Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined(),
        certificateChain: verifiedChain.map { (SecCertificateCopyData($0) as Data).base64EncodedString() }
    )
}

/// macOS 15+ 的显式 memory-only 选项保证宿主检查不写默认钥匙串。
private func inspectedIdentity(p12: Data, passphrase: String, team: String, certificates: [SecCertificate] = []) throws -> IdentityResult {
    var imported: CFArray?
    let options: [String: Any] = [
        kSecImportExportPassphrase as String: passphrase,
        kSecImportToMemoryOnly as String: true,
    ]
    try checked(SecPKCS12Import(p12 as CFData, options as CFDictionary, &imported), "Inspect PKCS#12 in process memory")
    guard let entries = imported as? [[String: Any]], entries.count == 1,
          let rawIdentity = entries[0][kSecImportItemIdentity as String],
          CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
        throw SigningFailure(description: "PKCS#12 must contain exactly one signing identity.")
    }
    let identity = rawIdentity as! SecIdentity
    let chain = entries[0][kSecImportItemCertChain as String] as? [SecCertificate] ?? []
    return try validateIdentity(identity, team: team, chain: chain + certificates)
}

private func inspectIdentity() throws {
    let request = try input(InspectInput.self)
    try validateTeam(request.team)
    guard !request.passphrase.isEmpty,
          let p12 = Data(base64Encoded: request.p12base64), !p12.isEmpty else {
        throw SigningFailure(description: "Identity inspection requires PKCS#12 data and a nonempty passphrase.")
    }
    try output(inspectedIdentity(
        p12: p12, passphrase: request.passphrase, team: request.team
    ))
}

private func exportIdentity(team: String) throws {
    try validateTeam(team)
    let request = try input(ExportInput.self)
    guard !request.passphrase.isEmpty else {
        throw SigningFailure(description: "PKCS#12 export requires a nonempty random passphrase.")
    }
    var rawIdentities: CFTypeRef?
    let query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecMatchPolicy as String: SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil)!,
        kSecMatchValidOnDate as String: Date(),
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &rawIdentities)
    if status == errSecItemNotFound {
        throw SigningFailure(description: "No valid Apple Development signing identity is available for the project Team.")
    }
    try checked(status, "Find project signing identities")
    guard let identities = rawIdentities as? [SecIdentity] else {
        preconditionFailure("Security returned an unexpected identity result")
    }
    let matches = try identities.filter { identity in
        let certificate = try certificate(of: identity)
        var commonName: CFString?
        try checked(SecCertificateCopyCommonName(certificate, &commonName), "Read certificate name")
        guard (commonName as String?)?.hasPrefix("Apple Development:") == true else { return false }
        return try organizationalUnits(of: certificate).contains(team)
    }
    guard matches.count == 1, let identity = matches.first else {
        throw SigningFailure(description: "Expected exactly one valid Apple Development identity for the project Team; found \(matches.count).")
    }

    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    let passphrase = request.passphrase as CFString
    parameters.passphrase = Unmanaged.passUnretained(passphrase)
    var exported: CFData?
    let exportStatus = withExtendedLifetime(passphrase) {
        SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
    }
    try checked(exportStatus, "Export project identity")
    guard let exported else { preconditionFailure("Security returned no PKCS#12 after success") }
    try output(ExportResult(
        fingerprint: fingerprint(of: try certificate(of: identity)),
        p12base64: (exported as Data).base64EncodedString()
    ))
}

/// trusted application ACL 与签名 partition ACL 在导入前配置，避免后续密码提权。
private func signingAccess() throws -> SecAccess {
    var trusted: [SecTrustedApplication] = []
    for path in [
        "/usr/bin/codesign",
        "/usr/bin/security",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
    ] {
        var application: SecTrustedApplication?
        try checked(SecTrustedApplicationCreateFromPath(path, &application), "Create trusted signing application")
        guard let application else { preconditionFailure("Security returned no trusted application after success") }
        trusted.append(application)
    }
    var result: SecAccess?
    try checked(SecAccessCreate("ECMenu disposable VM signing" as CFString, trusted as CFArray, &result), "Create signing access")
    guard let result else { preconditionFailure("Security returned no access object after success") }

    // Apple security 工具以十六进制 XML plist 表达 partition ACL 的描述字段。
    let partitionData = try PropertyListSerialization.data(
        fromPropertyList: ["Partitions": ["apple-tool:", "apple:", "codesign:"]],
        format: .xml, options: 0
    )
    let description = partitionData.map { String(format: "%02x", $0) }.joined() as CFString
    let existing = SecAccessCopyMatchingACLList(result, kSecACLAuthorizationPartitionID) as? [SecACL] ?? []
    if existing.isEmpty {
        var acl: SecACL?
        try checked(SecACLCreateWithSimpleContents(result, nil, description, [], &acl), "Create signing partition access")
        guard let acl else { preconditionFailure("Security returned no ACL after success") }
        try checked(SecACLUpdateAuthorizations(acl, [kSecACLAuthorizationPartitionID] as CFArray), "Set signing partition authorization")
    } else {
        for acl in existing {
            try checked(SecACLSetContents(acl, nil, description, []), "Set signing partition access")
        }
    }
    return result
}

private func guestKeychainPath(_ path: String) throws -> String {
    var virtualMachine: Int32 = 0
    var size = MemoryLayout.size(ofValue: virtualMachine)
    guard ProcessInfo.processInfo.environment["ECMENU_VM_GUEST"] == "1",
          sysctlbyname("kern.hv_vmm_present", &virtualMachine, &size, nil, 0) == 0,
          virtualMachine == 1 else {
        throw SigningFailure(description: "Keychain import and removal require the virtual machine guest environment.")
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".artifacts/scratch", isDirectory: true).standardizedFileURL.path + "/"
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard path.hasPrefix("/"), url.path.hasPrefix(root), url.pathExtension == "keychain-db" else {
        throw SigningFailure(description: "The disposable keychain must be an absolute .keychain-db path within this checkout's scratch directory.")
    }
    return url.path
}

private func importIdentity(path: String) throws {
    let path = try guestKeychainPath(path)
    let request = try input(ImportInput.self)
    try validateTeam(request.team)
    guard !request.passphrase.isEmpty, !request.keychainPassword.isEmpty,
          let p12 = Data(base64Encoded: request.p12base64), !p12.isEmpty else {
        throw SigningFailure(description: "Identity import requires PKCS#12 data and two nonempty random passwords.")
    }
    guard !FileManager.default.fileExists(atPath: path) else {
        throw SigningFailure(description: "Refusing to replace an existing signing keychain.")
    }
    // 在内存中验证私钥后再导入；已导入钥匙串只向真实签名工具开放。
    let certificates = try request.certificateChain.map { value -> SecCertificate in
        guard let data = Data(base64Encoded: value), let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw SigningFailure(description: "Certificate chain requires valid DER certificates.")
        }
        return certificate
    }
    let verified = try inspectedIdentity(p12: p12, passphrase: request.passphrase, team: request.team, certificates: certificates)
    var keychain: SecKeychain?
    let password = Data(request.keychainPassword.utf8)
    let createStatus = password.withUnsafeBytes { bytes in
        SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain)
    }
    try checked(createStatus, "Create disposable keychain")
    guard let keychain else { preconditionFailure("Security returned no keychain after success") }
    do {
        let unlockStatus = password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        try checked(unlockStatus, "Unlock disposable keychain")
        var settings = SecKeychainSettings(version: 1, lockOnSleep: false, useLockInterval: false, lockInterval: 0)
        try checked(SecKeychainCopySettings(keychain, &settings), "Read disposable keychain settings")
        FileHandle.standardError.write(Data("Disposable keychain settings: lockInterval=\(settings.lockInterval), lockOnSleep=\(settings.lockOnSleep.boolValue)\n".utf8))
        let access = try signingAccess()
        let passphrase = request.passphrase as CFString
        let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.flags = .importOnlyOne
        parameters.passphrase = Unmanaged.passUnretained(passphrase)
        parameters.accessRef = Unmanaged.passUnretained(access)
        parameters.keyAttributes = Unmanaged.passUnretained(attributes)
        var format = SecExternalFormat.formatPKCS12
        var type = SecExternalItemType.itemTypeAggregate
        var imported: CFArray?
        let importStatus = withExtendedLifetime((passphrase, attributes, access)) {
            SecItemImport(p12 as CFData, nil, &format, &type, [], &parameters, keychain, &imported)
        }
        try checked(importStatus, "Import project identity")
        // 仅补齐公开证书；信任锚与信任设置仍由系统拥有，整条链已在导入前验证。
        for certificate in certificates {
            let status = SecCertificateAddToKeychain(certificate, keychain)
            if status != errSecDuplicateItem {
                try checked(status, "Import public signing certificate")
            }
        }
        let identities = (imported as? [Any])?.compactMap { item -> SecIdentity? in
            guard CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
            return (item as! SecIdentity)
        } ?? []
        guard identities.count == 1, let identity = identities.first else {
            throw SigningFailure(description: "Imported PKCS#12 must contain exactly one signing identity.")
        }
        try checked(SecKeychainSetSearchList([keychain] as CFArray), "Select disposable signing keychain")
        let importedFingerprint = fingerprint(of: try certificate(of: identity))
        guard importedFingerprint == verified.fingerprint else {
            throw SigningFailure(description: "Imported identity differs from the verified project identity.")
        }
        try output(verified)
    } catch {
        let cleanupStatus = SecKeychainDelete(keychain)
        if cleanupStatus != errSecSuccess {
            let original = (error as? SigningFailure)?.description ?? "Identity import failed."
            throw SigningFailure(description: "\(original) Disposable keychain cleanup also failed (\(cleanupStatus)).")
        }
        throw error
    }
}

private func removeKeychain(path: String) throws {
    let path = try guestKeychainPath(path)
    guard FileManager.default.fileExists(atPath: path) else { return }
    var keychain: SecKeychain?
    try checked(SecKeychainOpen(path, &keychain), "Open disposable keychain")
    guard let keychain else { preconditionFailure("Security returned no keychain after success") }
    try checked(SecKeychainDelete(keychain), "Delete disposable keychain")
}

/// 在每个构建阶段前显式解锁单轮钥匙串，沿用系统默认的空闲锁定策略。
private func unlockKeychain(path: String) throws {
    let path = try guestKeychainPath(path)
    let request = try input(UnlockInput.self)
    guard !request.keychainPassword.isEmpty else {
        throw SigningFailure(description: "Disposable keychain unlock requires its nonempty password.")
    }
    var keychain: SecKeychain?
    try checked(SecKeychainOpen(path, &keychain), "Open disposable keychain")
    guard let keychain else { preconditionFailure("Security returned no keychain after success") }
    let password = Data(request.keychainPassword.utf8)
    let status = password.withUnsafeBytes { bytes in
        SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
    }
    try checked(status, "Unlock disposable keychain")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let authorizedExport = arguments.count == 2 && arguments[0] == "export-authorized"
    if authorizedExport {
        var virtual: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &virtual, &size, nil, 0) == 0,
              virtual == 0 else {
            throw SigningFailure(description: "One-time authorized export requires the macOS host.")
        }
    }
    try checked(SecKeychainSetUserInteractionAllowed(authorizedExport), "Configure signing authorization dialogs")
    if arguments == ["inspect"] {
        try inspectIdentity()
        exit(0)
    }
    guard arguments.count == 2 else {
        throw SigningFailure(description: "Usage: SigningIdentity inspect | export <project-Team> | export-authorized <project-Team> | import <guest-keychain-path> | unlock <guest-keychain-path> | remove <guest-keychain-path>")
    }
    switch arguments[0] {
    case "export", "export-authorized": try exportIdentity(team: arguments[1])
    case "import": try importIdentity(path: arguments[1])
    case "unlock": try unlockKeychain(path: arguments[1])
    case "remove": try removeKeychain(path: arguments[1])
    default: throw SigningFailure(description: "Unknown signing command.")
    }
} catch {
    let message = (error as? SigningFailure)?.description ?? "Signing helper failed; input secrets are omitted."
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
