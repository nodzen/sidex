// sidex-helper.swift — the one native helper sidex needs.
//
// Everything bash cannot do comfortably (plist socket protocols, TLS, certificate
// surgery, JSON from devicectl) lives here. sidex compiles this file once with
// Xcode's own swiftc and caches the binary — no Python, no Homebrew, nothing to
// install on top of the full Xcode sidex already requires.
//
// Subcommands:
//   devices                        devicectl "list devices" JSON on stdin -> "UDID|Name (iOS x, USB)" lines
//   apps MODE [TEAM]               devicectl "info apps" JSON on stdin -> "Name<TAB>Bundle<TAB>team" lines
//   team-id                        devicectl apps JSON on stdin -> the Team ID found inside bundle ids
//   installed-bundle WANT          devicectl apps JSON on stdin -> installed bundle id (the app itself if present)
//   fetch-record UDID OUT          stored pairing record from usbmuxd: no sudo, no Full Disk Access
//   pair UDID OUT [--timeout SEC]  live "ProtocolVersion 2" pairing (the same handshake Xcode uses)
//   certs DEVICE_PUB OUTDIR        just the certificate chain (tests / debugging)
//   entitlements TEAM PROFDIR APPDIR   entitlements mirroring for re-signing
//
// The pairing protocol is cross-checked against pymobiledevice3 (doronz88) and
// jkcoxson/idevice_pair, which perform the same handshake.

import Foundation
import Darwin
import CryptoKit
import Security

// MARK: - plumbing

struct HelperError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct LockdownError: Error, CustomStringConvertible {
    let code: String
    var description: String { code }
}

/// PairingPending - the trust dialog is still on screen.
struct PairingPending: Error {}

/// The TLS peer did not present the certificate from the record: fatal, drop the record.
struct ImpostorError: Error {}

func eprint(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@discardableResult
func run(_ path: String, _ arguments: [String], stdin: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe(), errorPipe = Pipe(), input = Pipe()
    process.standardOutput = output
    process.standardError = errorPipe
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do {
        try process.run()
    } catch {
        throw HelperError("cannot run \(path): \(error.localizedDescription)")
    }
    if let data = stdin {
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.closeFile()
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw HelperError("\(URL(fileURLWithPath: path).lastPathComponent) \(arguments.first ?? "") failed: \(message)")
    }
    return outputData
}

@discardableResult
func openssl(_ arguments: [String], stdin: Data? = nil) throws -> Data {
    try run("/usr/bin/openssl", arguments, stdin: stdin)
}

// MARK: - plists

func plistData(_ object: Any) throws -> Data {
    do {
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    } catch {
        throw HelperError("cannot serialise the plist: \(error.localizedDescription)")
    }
}

func plistDictionary(_ data: Data) throws -> [String: Any] {
    guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = object as? [String: Any] else {
        throw HelperError("not a plist dictionary")
    }
    return dictionary
}

// MARK: - sockets

/// A reply above this size is a broken parser, not a real message: refuse instead of allocating.
let maxMessage = 16 * 1024 * 1024

func usbmuxSocketPath() -> String {
    let path = ProcessInfo.processInfo.environment["SIDEX_USBMUXD_SOCKET"]  // env = test hook
    return (path?.isEmpty == false) ? path! : "/var/run/usbmuxd"
}

func connectUnixSocket(_ path: String, timeoutSeconds: Int) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HelperError("socket(): \(String(cString: strerror(errno)))") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        throw HelperError("socket path too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let message = String(cString: strerror(errno))
        close(fd)
        throw HelperError("cannot connect to \(path): \(message)")
    }
    return fd
}

func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
    var output = Data(count: count)
    try output.withUnsafeMutableBytes { buffer in
        var received = 0
        while received < count {
            let chunk = read(fd, buffer.baseAddress! + received, count - received)
            if chunk > 0 { received += chunk; continue }
            if chunk == 0 { throw HelperError("connection closed") }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw HelperError("timed out") }
            throw HelperError("read(): \(String(cString: strerror(errno)))")
        }
    }
    return output
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
        var sent = 0
        while sent < data.count {
            let chunk = write(fd, buffer.baseAddress! + sent, data.count - sent)
            if chunk > 0 { sent += chunk; continue }
            if chunk < 0 && errno == EINTR { continue }
            if chunk < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw HelperError("timed out") }
            throw HelperError("write(): \(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - usbmuxd (Unix socket, 16-byte little-endian header + XML plist; the
// length field includes the 16-byte header, in both directions)

func muxExchange(_ fd: Int32, _ message: [String: Any]) throws -> [String: Any] {
    let payload = try plistData(message)
    let header: [UInt32] = [UInt32(payload.count) + 16, 1, 8, 1]
    try writeAll(fd, header.withUnsafeBufferPointer { Data(buffer: $0) })
    try writeAll(fd, payload)
    let replyHeader = try readExactly(fd, 16)
    let length = replyHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
    guard length >= 16, length <= maxMessage else { throw HelperError("bad usbmuxd message length \(length)") }
    return try plistDictionary(try readExactly(fd, Int(length) - 16))
}

func muxRequest(_ message: [String: Any], sockPath: String, timeoutSeconds: Int = 15) throws -> [String: Any] {
    let fd = try connectUnixSocket(sockPath, timeoutSeconds: timeoutSeconds)
    defer { close(fd) }
    return try muxExchange(fd, message)
}

func muxFindDevice(_ udid: String, sockPath: String) throws -> Int {
    let response = try muxRequest(["MessageType": "ListDevices"], sockPath: sockPath)
    let wanted = udid.replacingOccurrences(of: "-", with: "").uppercased()
    for device in (response["DeviceList"] as? [[String: Any]]) ?? [] {
        let properties = (device["Properties"] as? [String: Any]) ?? [:]
        let serial = ((properties["SerialNumber"] as? String) ?? "").replacingOccurrences(of: "-", with: "").uppercased()
        if serial == wanted, let id = device["DeviceID"] as? Int { return id }
    }
    throw HelperError("iPhone \(udid) is not visible to usbmuxd (plug in the USB cable)")
}

func muxReadBUID(_ sockPath: String) -> String? {
    guard let buid = (try? muxRequest(["MessageType": "ReadBUID"], sockPath: sockPath))?["BUID"] as? String,
          !buid.isEmpty else { return nil }
    return buid
}

func muxConnect(_ deviceID: Int, port: UInt16, sockPath: String) throws -> Int32 {
    let fd = try connectUnixSocket(sockPath, timeoutSeconds: 10)
    do {
        let response = try muxExchange(fd, [
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": Int(port.byteSwapped),  // plist-protocol quirk: network byte order
        ])
        if let number = response["Number"] as? Int, number != 0 {
            throw HelperError("usbmuxd could not connect to the device (error \(number))")
        }
    } catch {
        close(fd)
        throw error
    }
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

// MARK: - lockdownd (over the usbmuxd-connected socket: 4-byte big-endian length + plist)

final class Lockdown {
    let fd: Int32
    let label: String

    init(fd: Int32, label: String) {
        self.fd = fd
        self.label = label
    }

    func request(_ name: String, _ options: [String: Any] = [:]) throws -> [String: Any] {
        var message: [String: Any] = ["Label": label, "Request": name]
        for (key, value) in options { message[key] = value }
        let payload = try plistData(message)
        let length = UInt32(payload.count).bigEndian
        try writeAll(fd, withUnsafeBytes(of: length) { Data($0) })
        try writeAll(fd, payload)
        let header = try readExactly(fd, 4)
        let size = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        guard size > 0, size <= UInt32(maxMessage) else {
            throw HelperError("bad lockdownd message length \(size)")
        }
        let response = try plistDictionary(try readExactly(fd, Int(size)))
        if let error = response["Error"] as? String {
            if error == "PairingDialogResponsePending" { throw PairingPending() }
            throw LockdownError(code: error)
        }
        return response
    }

    func getValue(_ key: String) throws -> Any {
        let response = try request("GetValue", ["Key": key])
        guard let value = response["Value"] else {
            throw LockdownError(code: "missing Value for \(key)")
        }
        return value
    }
}

// MARK: - certificate chain

struct Chain {
    let hostCertificate: Data
    let hostPrivateKey: Data
    let deviceCertificate: Data
    let rootCertificate: Data
    let rootPrivateKey: Data
}

/// Length and header size of the DER tag at `offset`.
func derLength(_ data: [UInt8], at offset: Int) throws -> (length: Int, header: Int) {
    guard offset + 2 <= data.count else { throw HelperError("bad DER") }
    if data[offset + 1] < 0x80 { return (Int(data[offset + 1]), 2) }
    let count = Int(data[offset + 1] & 0x7F)
    guard count > 0, offset + 2 + count <= data.count else { throw HelperError("bad DER length") }
    var length = 0
    for index in 0..<count { length = (length << 8) | Int(data[offset + 2 + index]) }
    return (length, 2 + count)
}

func findBytes(_ haystack: [UInt8], _ needle: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
    guard !needle.isEmpty else { return nil }
    let limit = (to ?? haystack.count) - needle.count
    guard limit >= from else { return nil }
    for start in from...limit {
        var matched = true
        for index in 0..<needle.count where haystack[start + index] != needle[index] {
            matched = false
            break
        }
        if matched { return start }
    }
    return nil
}

func pemWrap(_ label: String, _ der: Data) -> Data {
    let base64 = der.base64EncodedString()
    var body = ""
    var index = base64.startIndex
    while index < base64.endIndex {
        let next = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
        body += base64[index..<next] + "\n"
        index = next
    }
    return Data("-----BEGIN \(label)-----\n\(body)-----END \(label)-----\n".utf8)
}

/// PKCS#1 DER of an RSA public key. Accepts both PEM flavors: PKCS#1 ("RSA PUBLIC KEY",
/// what lockdownd answers) and SubjectPublicKeyInfo ("PUBLIC KEY", what openssl prints
/// for a certificate).
func publicKeyDER(_ pem: Data) throws -> Data {
    if let der = try? openssl(["rsa", "-pubin", "-pubout", "-RSAPublicKey_out", "-outform", "DER"],
                              stdin: pem) {
        return der
    }
    return try openssl(["rsa", "-pubin", "-RSAPublicKey_in", "-pubout", "-RSAPublicKey_out",
                        "-outform", "DER"], stdin: pem)
}

/// Replace the public key inside an openssl-issued certificate.
///
/// openssl refuses to issue a certificate for a key it does not own (it verifies the
/// CSR signature), and the device's private key never leaves the iPhone. Both keys are
/// RSA-2048, so their DER encodings have identical size: overwrite the public key in
/// place, fix the key identifier, re-sign the TBS with the root key, keep the rest.
func graftDeviceKey(certDER: Data, dummyDER: Data, deviceDER: Data, rootKeyPath: String) throws -> Data {
    guard dummyDER.count == deviceDER.count else {
        throw HelperError("device public key is not RSA-2048, cannot build its certificate")
    }
    var output = [UInt8](certDER)
    let dummy = [UInt8](dummyDER)
    let device = [UInt8](deviceDER)
    guard let position = findBytes(output, dummy),
          findBytes(output, dummy, from: position + 1) == nil else {
        throw HelperError("internal error: throwaway public key not found exactly once")
    }
    output.replaceSubrange(position..<(position + device.count), with: device)
    // subjectKeyIdentifier = SHA-1 of the raw public key bits
    let oid: [UInt8] = [0x06, 0x03, 0x55, 0x1d, 0x0e]  // id-ce-subjectKeyIdentifier
    guard let oidPosition = findBytes(output, oid),
          let skiPosition = findBytes(output, [0x04, 0x14], from: oidPosition, to: oidPosition + 16) else {
        throw HelperError("internal error: cannot locate the key identifier extension")
    }
    let dummySHA1 = [UInt8](Data(Insecure.SHA1.hash(data: dummyDER)))
    guard Array(output[(skiPosition + 2)..<(skiPosition + 22)]) == dummySHA1 else {
        throw HelperError("internal error: cannot locate the key identifier extension")
    }
    output.replaceSubrange((skiPosition + 2)..<(skiPosition + 22),
                           with: [UInt8](Data(Insecure.SHA1.hash(data: deviceDER))))
    // the old signature is invalid now: re-sign the TBS part, keep the layout
    guard output.count > 261,
          Array(output[(output.count - 261)..<(output.count - 256)]) == [0x03, 0x82, 0x01, 0x01, 0x00] else {
        throw HelperError("internal error: unexpected certificate layout")
    }
    let (_, outerHeader) = try derLength(output, at: 0)
    let (tbsLength, tbsHeader) = try derLength(output, at: outerHeader)
    let tbs = Data(output[outerHeader..<(outerHeader + tbsHeader + tbsLength)])
    let signature = try openssl(["dgst", "-sha256", "-sign", rootKeyPath], stdin: tbs)
    guard signature.count == 256 else {
        throw HelperError("openssl produced an unexpected signature (\(signature.count) bytes)")
    }
    output.replaceSubrange((output.count - 256)..<output.count, with: [UInt8](signature))
    return Data(output)
}

/// Build the certificate chain for a pairing record.
///
/// Mirrors what macOS itself creates: empty subjects, RSA-2048, serial 1, SHA-256,
/// ten-year validity; a self-signed root; host and device leafs signed by the root.
func generateChain(devicePublicKeyPEM: Data, workdir: String) throws -> Chain {
    let certDays = 3650
    // certificate extensions Apple itself puts in pairing certificates
    // (root ones via req -addext: LibreSSL's req has no -extfile; the file is for x509 -req)
    let rootExtensions = ["-addext", "basicConstraints=critical,CA:TRUE",
                          "-addext", "subjectKeyIdentifier=hash"]
    let leafExtensions = "[x]\nbasicConstraints=critical,CA:FALSE\n" +
        "keyUsage=critical,digitalSignature,keyEncipherment\n" +
        "subjectKeyIdentifier=hash\n"

    func path(_ name: String) -> String { workdir + "/" + name }
    func read(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path(name))) }
    func keypair(_ key: String, _ pkcs8: String) throws {
        try openssl(["genrsa", "-out", path(key), "2048"])
        try openssl(["pkcs8", "-topk8", "-nocrypt", "-in", path(key), "-out", path(pkcs8)])
    }

    let leafExtensionFile = path("leaf.ext")
    try leafExtensions.write(toFile: leafExtensionFile, atomically: true, encoding: .utf8)

    try keypair("root.key", "root.pk8")
    let rootCertificate = path("root.crt")
    try openssl(["req", "-x509", "-new", "-key", path("root.key"), "-subj", "/",
                 "-days", String(certDays), "-sha256"] + rootExtensions +
                ["-out", rootCertificate])

    try keypair("host.key", "host.pk8")
    try openssl(["req", "-new", "-key", path("host.key"), "-subj", "/", "-out", path("host.csr")])
    try openssl(["x509", "-req", "-in", path("host.csr"), "-CA", rootCertificate,
                 "-CAkey", path("root.key"), "-set_serial", "1", "-days", String(certDays),
                 "-sha256", "-extfile", leafExtensionFile, "-extensions", "x",
                 "-out", path("host.crt")])

    // device certificate: issue for a throwaway key, then graft the device key in
    try openssl(["genrsa", "-out", path("dummy.key"), "2048"])
    try openssl(["req", "-new", "-key", path("dummy.key"), "-subj", "/", "-out", path("dummy.csr")])
    try openssl(["x509", "-req", "-in", path("dummy.csr"), "-CA", rootCertificate,
                 "-CAkey", path("root.key"), "-set_serial", "1", "-days", String(certDays),
                 "-sha256", "-extfile", leafExtensionFile, "-extensions", "x",
                 "-out", path("dummy.crt")])
    let dummyDER = try openssl(["rsa", "-in", path("dummy.key"), "-pubout",
                                "-RSAPublicKey_out", "-outform", "DER"])
    let deviceDER = try publicKeyDER(devicePublicKeyPEM)
    let dummyCertDER = try openssl(["x509", "-in", path("dummy.crt"), "-outform", "DER"])
    let deviceCertificate = pemWrap("CERTIFICATE",
        try graftDeviceKey(certDER: dummyCertDER, dummyDER: dummyDER, deviceDER: deviceDER,
                           rootKeyPath: path("root.key")))

    // the iPhone rejects a bad record hours later - fail loudly here instead
    try deviceCertificate.write(to: URL(fileURLWithPath: path("device.crt")))
    _ = try openssl(["verify", "-CAfile", rootCertificate, path("device.crt")])
    let certificateKey = try openssl(["x509", "-in", path("device.crt"), "-noout", "-pubkey"])
    guard try publicKeyDER(certificateKey) == deviceDER else {
        throw HelperError("internal error: the generated device certificate carries the wrong key")
    }

    return Chain(hostCertificate: try read("host.crt"),
                 hostPrivateKey: try read("host.pk8"),
                 deviceCertificate: deviceCertificate,
                 rootCertificate: try read("root.crt"),
                 rootPrivateKey: try read("root.pk8"))
}

// MARK: - files

/// DER bytes of one PEM block; PEM-less input passes through unchanged.
func derFromPEM(_ pem: Data) -> Data {
    let text = String(decoding: pem, as: UTF8.self)
    let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
    return Data(base64Encoded: body) ?? pem
}

func makeTempDirectory(_ prefix: String) throws -> String {
    let path = NSTemporaryDirectory() + prefix + UUID().uuidString
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func writeFile(path: String, data: Data) throws {
    let temporary = path + ".tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw HelperError("cannot write \(temporary): \(String(cString: strerror(errno)))") }
    do {
        try writeAll(fd, data)
    } catch {
        close(fd)
        throw error
    }
    close(fd)
    guard rename(temporary, path) == 0 else {
        throw HelperError("cannot replace \(path): \(String(cString: strerror(errno)))")
    }
}

// MARK: - TLS (SecureTransport on the socket usbmuxd gave us)

final class TLSConnection {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
}

/// Load the host certificate + key as a SecIdentity (via a throwaway PKCS#12).
func makeClientIdentity(certificates: Data, privateKey: Data) throws -> SecIdentity {
    let directory = try makeTempDirectory("sidex-helper-tls-")
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let certificatePath = directory + "/cert.pem"
    let keyPath = directory + "/key.pem"
    let bundlePath = directory + "/identity.p12"
    try certificates.write(to: URL(fileURLWithPath: certificatePath))
    try privateKey.write(to: URL(fileURLWithPath: keyPath))
    let passphrase = UUID().uuidString
    _ = try openssl(["pkcs12", "-export", "-out", bundlePath, "-inkey", keyPath,
                     "-in", certificatePath, "-passout", "pass:" + passphrase])
    let bundle = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
    var items: CFArray?
    let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
    let status = SecPKCS12Import(bundle as CFData, options, &items)
    guard status == errSecSuccess,
          let list = items as? [[String: Any]],
          let first = list.first,
          let rawIdentity = first[kSecImportItemIdentity as String] else {
        throw HelperError("the keychain rejected the exported identity (status \(status))")
    }
    return rawIdentity as! SecIdentity  // SecPKCS12Import always hands back a SecIdentity here
}

func tlsWrite(_ context: SSLContext, _ data: Data, deadline: Date) throws {
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < data.count {
            var written = 0
            let status = SSLWrite(context, buffer.baseAddress! + offset, data.count - offset, &written)
            offset += written
            if offset >= data.count { break }
            guard Date() < deadline else { throw HelperError("TLS write timed out") }
            if status != errSecSuccess && status != errSSLWouldBlock {
                throw HelperError("TLS write failed (status \(status))")
            }
            usleep(20_000)
        }
    }
}

func tlsReadExactly(_ context: SSLContext, _ count: Int, deadline: Date) throws -> Data {
    var output = Data(count: count)
    try output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
        var offset = 0
        while offset < count {
            var received = 0
            let status = SSLRead(context, buffer.baseAddress! + offset, count - offset, &received)
            offset += received
            if offset >= count { break }
            guard Date() < deadline else { throw HelperError("TLS read timed out") }
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
                throw HelperError("the device closed the session")
            }
            if status != errSecSuccess && status != errSSLWouldBlock {
                throw HelperError("TLS read failed (status \(status))")
            }
            usleep(20_000)
        }
    }
    return output
}

/// Start a TLS session with the fresh record and prove lockdownd answers on it.
// ponytail: SecureTransport is deprecated since macOS 10.15 — move to Network.framework
// over the same usbmuxd socket only when Apple actually removes it; it works today.
func tlsPing(fd: Int32, identity: SecIdentity, record: [String: Any], label: String) throws {
    guard let context = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
        throw HelperError("cannot create a TLS context")
    }
    let connection = UnsafeMutablePointer<TLSConnection>.allocate(capacity: 1)
    connection.initialize(to: TLSConnection(fd: fd))
    defer {
        connection.deinitialize(count: 1)
        connection.deallocate()
    }

    let readCallback: SSLReadFunc = { reference, data, length in
        let fd = reference.assumingMemoryBound(to: TLSConnection.self).pointee.fd
        let count = read(fd, data, length.pointee)
        if count > 0 { length.pointee = count; return errSecSuccess }
        length.pointee = 0
        if count == 0 { return errSSLClosedGraceful }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return errSSLClosedAbort
    }
    let writeCallback: SSLWriteFunc = { reference, data, length in
        let fd = reference.assumingMemoryBound(to: TLSConnection.self).pointee.fd
        let count = write(fd, data, length.pointee)
        if count > 0 { length.pointee = count; return errSecSuccess }
        length.pointee = 0
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return errSSLClosedAbort
    }
    SSLSetIOFuncs(context, readCallback, writeCallback)
    SSLSetConnection(context, UnsafeMutableRawPointer(connection))
    SSLSetCertificate(context, [identity] as CFArray)
    // the device's chain is not Apple-signed: CA verification is meaningless here.
    // Security is the pin check below instead: the presented certificate must be the
    // exact same bytes that are in the pairing record (a MITM cannot present the
    // device's leaf without holding the device's private key).
    SSLSetSessionOption(context, .breakOnServerAuth, true)
    SSLSetProtocolVersionMin(context, .tlsProtocol12)
    SSLSetProtocolVersionMax(context, .tlsProtocol12)

    let deadline = Date().addingTimeInterval(20)
    var status = SSLHandshake(context)
    // errSSLServerAuthCompleted is a C alias of errSSLPeerAuthCompleted: the break we asked for
    while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted {
        guard Date() < deadline else { throw HelperError("TLS handshake timed out") }
        usleep(20_000)
        status = SSLHandshake(context)
    }
    guard status == errSecSuccess else {
        throw HelperError("TLS handshake failed (status \(status))")
    }

    // pin: the peer must present the certificate from the pairing record
    guard let expected = record["DeviceCertificate"] as? Data else {
        throw HelperError("the pairing record has no DeviceCertificate to pin against")
    }
        var peerTrustRef: SecTrust?
    guard SSLCopyPeerTrust(context, &peerTrustRef) == errSecSuccess, let peerTrust = peerTrustRef,
          let peers = SecTrustCopyCertificateChain(peerTrust) as? [SecCertificate],
          !peers.isEmpty,
          peers.contains(where: { Data(SecCertificateCopyData($0) as Data) == expected }) else {
        throw ImpostorError()
    }

    let request = try plistData(["Label": label, "Request": "GetValue", "Key": "ProductVersion"])
    let length = UInt32(request.count).bigEndian
    var framed = withUnsafeBytes(of: length) { Data($0) }
    framed.append(request)
    try tlsWrite(context, framed, deadline: deadline)
    let header = try tlsReadExactly(context, 4, deadline: deadline)
    let size = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
    guard size > 0, size <= UInt32(maxMessage) else {
        throw HelperError("bad lockdownd message length \(size)")
    }
    let body = try tlsReadExactly(context, Int(size), deadline: deadline)
    _ = try plistDictionary(body)
    SSLClose(context)
}

// MARK: - the pairing itself

func waitForDeviceValues(_ lockdown: Lockdown, timeout: Double) throws -> (publicKey: Data, wifi: String) {
    // lockdownd answers GetProhibited while the iPhone is locked
    let deadline = Date().addingTimeInterval(timeout)
    var hinted = false
    while true {
        do {
            let value = try lockdown.getValue("DevicePublicKey")
            let publicKey: Data
            if let data = value as? Data { publicKey = data }
            else if let text = value as? String { publicKey = Data(text.utf8) }
            else { throw HelperError("the iPhone returned no public key") }
            let wifi = (try lockdown.getValue("WiFiAddress")) as? String ?? ""
            return (publicKey, wifi)
        } catch let error as LockdownError where error.code == "GetProhibited" {
            guard Date() < deadline else {
                throw HelperError("the iPhone is locked: unlock it (Home Screen) and run pair again")
            }
            if !hinted {
                eprint("Unlock the iPhone and keep it on the Home Screen - waiting...")
                hinted = true
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

func pairHandshake(_ lockdown: Lockdown, options: [String: Any], timeout: Double) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    eprint("If the iPhone asks \"Trust This Computer?\" - tap Trust.")
    while true {
        do {
            return try lockdown.request("Pair", options)
        } catch is PairingPending {
            guard Date() < deadline else {
                throw HelperError("timed out waiting for the Trust tap on the iPhone")
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

/// StartSession + TLS with the fresh record: proves the iPhone accepts it. Soft on
/// technical hiccups (the Pair handshake already succeeded), fatal on an impostor cert.
func validateSession(fd: Int32, label: String, record: [String: Any], chain: Chain) throws {
    do {
        let lockdown = Lockdown(fd: fd, label: label)
        let response = try lockdown.request("StartSession", [
            "HostID": record["HostID"] as? String ?? "",
            "SystemBUID": record["SystemBUID"] as? String ?? "",
        ])
        if (response["EnableSessionSSL"] as? Bool) != true {
            eprint("Session check passed: the iPhone accepts the record.")
            return
        }
        let identity = try makeClientIdentity(certificates: chain.hostCertificate + chain.rootCertificate,
                                              privateKey: chain.hostPrivateKey)
        try tlsPing(fd: fd, identity: identity, record: record, label: label)
        eprint("Session check passed: the iPhone accepts the record.")
    } catch is ImpostorError {
        throw HelperError("the device presented a certificate that is not the one in the pairing record (possible impersonation); pairing record discarded")
    } catch {
        eprint("Note: could not verify a lockdown session (\(error)); the record is saved anyway.")
    }
}

/// Pair with the device and save a lockdown record. The modern "ProtocolVersion 2"
/// handshake Xcode itself uses, so it works on a Mac that has never seen the device.
func pair(udid: String, outPath: String, sockPath: String, timeout: Double) throws {
    let deviceID = try muxFindDevice(udid, sockPath: sockPath)
    // libimobiledevice's well-known System BUID, used only when usbmuxd cannot report one
    let buid = muxReadBUID(sockPath) ?? "30142955-444094379208051516"
    let label = "sidex-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
    eprint("Asking the iPhone for its public key...")
    let fd = try muxConnect(deviceID, port: 62078, sockPath: sockPath)
    defer { close(fd) }
    let lockdown = Lockdown(fd: fd, label: label)
    let (publicKey, wifi) = try waitForDeviceValues(lockdown, timeout: timeout)
    let workdir = try makeTempDirectory("sidex-pair-")
    defer { try? FileManager.default.removeItem(atPath: workdir) }
    let chain = try generateChain(devicePublicKeyPEM: publicKey, workdir: workdir)
    var record: [String: Any] = [
        // certificates go DER-style: that is how Apple's own pairing records store them
        "DeviceCertificate": derFromPEM(chain.deviceCertificate),
        "HostCertificate": derFromPEM(chain.hostCertificate),
        "HostID": UUID().uuidString.uppercased(),
        "RootCertificate": derFromPEM(chain.rootCertificate),
        "RootPrivateKey": chain.rootPrivateKey,
        "WiFiMACAddress": wifi,
        "SystemBUID": buid,
    ]
    let options: [String: Any] = [
        "HostName": ProcessInfo.processInfo.hostName,
        "PairRecord": record,
        "ProtocolVersion": "2",
        "PairingOptions": ["ExtendedPairingErrors": true],
    ]
    let response = try pairHandshake(lockdown, options: options, timeout: timeout)
    record["HostPrivateKey"] = chain.hostPrivateKey
    if let escrow = response["EscrowBag"] as? Data { record["EscrowBag"] = escrow }
    try writeFile(path: outPath, data: try plistData(record))
    do {
        try validateSession(fd: fd, label: label, record: record, chain: chain)
    } catch {
        try? FileManager.default.removeItem(atPath: outPath)  // a possibly impersonated record is worse than none
        throw error
    }
}

func lockdownHint(_ code: String) -> String {
    let hints = [
        "UserDeniedPairing": "pairing was declined on the iPhone (the \"Don't Trust\" button)",
        "PasswordProtected": "the iPhone asks for its passcode: unlock it and retry",
        "PasscodeRequired": "the iPhone asks for its passcode: unlock it and retry",
        "GetProhibited": "the iPhone is locked: unlock it and retry",
        "InvalidHostID": "the iPhone no longer knows this host; retry the pairing",
        "PairingDialogResponsePending": "the iPhone never answered the pairing dialog",
    ]
    return hints[code] ?? "the iPhone refused to pair: \(code)"
}

// MARK: - commands

func standardInputData() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func isUDID(_ text: String) -> Bool {
    if text.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$", options: .regularExpression) != nil { return true }
    // pre-A12 devices have no dashes: 25-40 hex characters
    return text.range(of: "^[0-9A-Fa-f]{25,40}$", options: .regularExpression) != nil
}

func jsonRoot(_ data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return object as? [String: Any]
}

func devicesCommand() throws {
    guard let root = jsonRoot(standardInputData()) else { return }
    let devices = ((root["result"] as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
    for device in devices {
        let properties = device["properties"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any]
            ?? device["hardwareProperties"] as? [String: Any] ?? [:]
        let software = properties["software"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any]
            ?? device["deviceProperties"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any]
            ?? device["connectionProperties"] as? [String: Any] ?? [:]
        let udid = (hardware["udid"] as? String) ?? (device["udid"] as? String) ?? ""
        guard isUDID(udid) else { continue }
        if (hardware["reality"] as? String) == "simulated" { continue }
        if ((hardware["platform"] as? String) ?? "iOS") != "iOS" { continue }
        var version: Any? = software["osVersionNumber"]
        if version == nil { version = (device["deviceProperties"] as? [String: Any])?["osVersionNumber"] }
        if let number = version as? [String: Any] { version = number["stringValue"] }
        let osVersion = (version as? String) ?? "?"
        let name = (state["name"] as? String) ?? (hardware["marketingName"] as? String) ?? "device"
        var transport = (connection["transportType"] as? String) ?? "?"
        if transport == "wired" { transport = "USB" }
        else if transport == "localNetwork" { transport = "Wi-Fi" }
        print("\(udid)|\(name) (iOS \(osVersion), \(transport))")
    }
}

func matchesTeam(_ bundle: String, team: String) -> Bool {
    guard !team.isEmpty else { return false }
    let pattern = "\\." + NSRegularExpression.escapedPattern(for: team) + "($|\\.)"
    return bundle.range(of: pattern, options: .regularExpression) != nil
}

func appsCommand(_ arguments: [String]) throws {
    let mode = arguments.first ?? "all"
    let team = arguments.count > 1 ? arguments[1] : ""
    let apps = ((jsonRoot(standardInputData())?["result"] as? [String: Any])?["apps"] as? [[String: Any]]) ?? []
    var items = apps.map { (name: ($0["name"] as? String) ?? "?", bundle: ($0["bundleIdentifier"] as? String) ?? "?") }
    // drop extensions: a bundle id that extends another installed app's id is not an app
    let bundles = items.map { $0.bundle }
    items = items.filter { item in
        !bundles.contains { other in other != item.bundle && item.bundle.hasPrefix(other + ".") }
    }
    let pairTargets = ["sidestore", "livecontainer", "stikdebug", "feather", "ksign",
                       "sparsebox", "protokol", "antrag", "enswilde", "reynard", "stosdebug"]
    func rank(_ item: (name: String, bundle: String)) -> Int {
        let haystack = (item.name + " " + item.bundle).lowercased()
        for (index, keyword) in pairTargets.enumerated() where haystack.contains(keyword) { return index }
        return 99
    }
    switch mode {
    case "team":
        if !team.isEmpty { items = items.filter { matchesTeam($0.bundle, team: team) } }
    case "pair-targets":
        items = items.filter { rank($0) < 99 }
        items.sort { left, right in
            let leftRank = rank(left), rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.name.lowercased() < right.name.lowercased()
        }
    default:
        break
    }
    for item in items {
        print("\(item.name)\t\(item.bundle)\t\(matchesTeam(item.bundle, team: team) ? "team" : "")")
    }
}

func teamIDCommand() throws {
    guard let root = jsonRoot(standardInputData()) else { return }
    var found: String?
    func walk(_ object: Any) {
        guard found == nil else { return }
        if let dictionary = object as? [String: Any] {
            if let bundle = dictionary["bundleIdentifier"] as? String,
               let range = bundle.range(of: "\\.[A-Z0-9]{10}(\\.|$)", options: .regularExpression) {
                var team = String(bundle[range].dropFirst())
                if team.hasSuffix(".") { team.removeLast() }
                found = team
                return
            }
            for value in dictionary.values { walk(value) }
        } else if let array = object as? [Any] {
            for value in array { walk(value) }
        }
    }
    walk(root)
    if let team = found { print(team) }
}

func installedBundleCommand(_ arguments: [String]) throws {
    guard let wanted = arguments.first else { throw HelperError("usage: installed-bundle WANT") }
    guard let root = jsonRoot(standardInputData()) else { return }
    var bundles: [String] = []
    func walk(_ object: Any) {
        if let dictionary = object as? [String: Any] {
            if let bundle = dictionary["bundleIdentifier"] as? String { bundles.append(bundle) }
            for value in dictionary.values { walk(value) }
        } else if let array = object as? [Any] {
            for value in array { walk(value) }
        }
    }
    walk(root)
    if let exact = bundles.first(where: { $0 == wanted }) { print(exact) }
    else if let extensionMatch = bundles.first(where: { $0.hasPrefix(wanted + ".") }) { print(extensionMatch) }
}

func fetchRecordCommand(_ arguments: [String]) throws {
    guard arguments.count >= 2 else { throw HelperError("usage: fetch-record UDID OUT") }
    let udid = arguments[0], out = arguments[1]
    let sockPath = usbmuxSocketPath()
    var record: Data?
    var lastNumber: Any = "?"
    do {
        for candidate in [udid, udid.replacingOccurrences(of: "-", with: "")] {
            let response = try muxRequest(["MessageType": "ReadPairRecord", "PairRecordID": candidate],
                                          sockPath: sockPath, timeoutSeconds: 10)
            lastNumber = response["Number"] ?? "?"
            if let data = response["PairRecordData"] as? Data, !data.isEmpty {
                record = data
                break
            }
        }
    } catch let error as HelperError {
        eprint("usbmuxd: \(error.message)")
        exit(1)
    } catch {
        eprint("usbmuxd: bad reply (\(error))")
        exit(1)
    }
    guard let data = record else {
        eprint("usbmuxd has no stored pairing record (error \(lastNumber); is the iPhone on a USB cable and unlocked?)")
        exit(1)
    }
    guard (try? plistDictionary(data)) != nil else {
        eprint("usbmuxd returned a malformed pairing record")
        exit(1)
    }
    try writeFile(path: out, data: data)
}

func pairCommand(_ arguments: [String]) throws {
    guard arguments.count >= 2 else { throw HelperError("usage: pair UDID OUT [--timeout SECONDS]") }
    let udid = arguments[0], out = arguments[1]
    var timeout = 120.0
    var index = 2
    while index < arguments.count {
        if arguments[index] == "--timeout" {
            guard index + 1 < arguments.count, let value = Double(arguments[index + 1]) else {
                throw HelperError("--timeout needs a number of seconds")
            }
            timeout = value
            index += 2
        } else {
            throw HelperError("unknown option for pair: \(arguments[index])")
        }
    }
    do {
        try pair(udid: udid, outPath: out, sockPath: usbmuxSocketPath(), timeout: timeout)
    } catch let error as LockdownError {
        throw HelperError(lockdownHint(error.code))
    }
}

func certsCommand(_ arguments: [String]) throws {
    guard arguments.count >= 2 else { throw HelperError("usage: certs DEVICE_PUB_FILE OUTDIR") }
    let publicKeyPEM = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
    let directory = arguments[1]
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let chain = try generateChain(devicePublicKeyPEM: publicKeyPEM, workdir: directory)
    try chain.hostCertificate.write(to: URL(fileURLWithPath: directory + "/host.crt"))
    try chain.hostPrivateKey.write(to: URL(fileURLWithPath: directory + "/host.pk8"))
    try chain.deviceCertificate.write(to: URL(fileURLWithPath: directory + "/device.crt"))
    try chain.rootCertificate.write(to: URL(fileURLWithPath: directory + "/root.crt"))
    try chain.rootPrivateKey.write(to: URL(fileURLWithPath: directory + "/root.pk8"))
}

/// SHA-1 of every certificate the profile was minted for, uppercase hex, one per line.
/// The signing identity must be exactly one of these, or iOS refuses the install.
func certHashCommand(_ arguments: [String]) throws {
    guard let profilePath = arguments.first else { throw HelperError("usage: cert-hash PROFILE") }
    let signed = try? run("/usr/bin/security", ["cms", "-D", "-i", profilePath])
    let raw = try plistDictionary(signed ?? Data(contentsOf: URL(fileURLWithPath: profilePath)))
    guard let certificates = raw["DeveloperCertificates"] as? [Data], !certificates.isEmpty else {
        throw HelperError("no DeveloperCertificates in the profile")
    }
    for certificate in certificates {
        print(Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined())
    }
}

func entitlementsCommand(_ arguments: [String]) throws {
    guard arguments.count >= 3 else { throw HelperError("usage: entitlements TEAM PROFILE_DIR APP_DIR") }
    let team = arguments[0], profileDirectory = arguments[1], appDirectory = arguments[2]
    var jobs: [(path: String, name: String)] = [(appDirectory, "app")]
    var plugins: [(plugin: String, path: String)] = []
    for subdirectory in ["PlugIns", "AppClips"] {
        let path = appDirectory + "/" + subdirectory
        for plugin in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter({ $0.hasSuffix(".appex") }).sorted()
        {
            plugins.append((plugin, path + "/" + plugin))
        }
    }
    for plugin in plugins {
        jobs.append((plugin.path, String(plugin.plugin.dropLast(".appex".count))))
    }
    for job in jobs {
        let profilePath = profileDirectory + "/" + job.name + ".mobileprovision"
        let profile = try plistDictionary(try run("/usr/bin/security", ["cms", "-D", "-i", profilePath]))
        guard var entitlements = profile["Entitlements"] as? [String: Any] else {
            throw HelperError("no Entitlements in the profile for \(job.name)")
        }
        var original: [String: Any] = [:]
        if let raw = try? run("/usr/bin/codesign", ["-d", "--entitlements", ":-", job.path]) {
            let prefix = String(decoding: raw.prefix(8), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("<?xml") || prefix.hasPrefix("bplist") {
                original = (try? plistDictionary(raw)) ?? [:]
            }
        }
        if let groups = original["keychain-access-groups"] as? [String] {
            entitlements["keychain-access-groups"] = groups.map { group in
                group.replacingOccurrences(of: "^[A-Z0-9]{10}\\.", with: team + ".",
                                           options: .regularExpression)
            }
        }
        let data = try plistData(entitlements)
        try data.write(to: URL(fileURLWithPath: profileDirectory + "/" + job.name + ".entitlements.plist"))
        print("  entitlements: " + job.name)
    }
}

// MARK: - entry point

enum SidexHelper {
    static let usageText = """
    usage: sidex-helper <command>

      devices                        devicectl "list devices" JSON on stdin -> "UDID|Name (iOS x, USB)" lines
      apps MODE [TEAM]               devicectl "info apps" JSON on stdin -> "Name<TAB>Bundle<TAB>team" lines
      team-id                        devicectl apps JSON on stdin -> the Team ID found inside bundle ids
      installed-bundle WANT          devicectl apps JSON on stdin -> installed bundle id
      fetch-record UDID OUT          stored pairing record from usbmuxd
      pair UDID OUT [--timeout SEC]  live "ProtocolVersion 2" pairing
      certs DEVICE_PUB OUTDIR        certificate chain only (tests / debugging)
      cert-hash PROFILE              SHA-1 of each certificate inside a provisioning profile
      entitlements TEAM PROFDIR APPDIR   entitlements mirroring for re-signing
    """

    static func dispatch() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            eprint(usageText)
            exit(2)
        }
        arguments.removeFirst()
        switch command {
        case "devices": try devicesCommand()
        case "apps": try appsCommand(arguments)
        case "team-id": try teamIDCommand()
        case "installed-bundle": try installedBundleCommand(arguments)
        case "fetch-record": try fetchRecordCommand(arguments)
        case "pair": try pairCommand(arguments)
        case "certs": try certsCommand(arguments)
        case "cert-hash": try certHashCommand(arguments)
        case "entitlements": try entitlementsCommand(arguments)
        default: throw HelperError("unknown command \(command)\n\(usageText)")
        }
    }
}

do {
    try SidexHelper.dispatch()
} catch let error as HelperError {
    eprint("ERROR: \(error.message)")
    exit(1)
} catch let error as LockdownError {
    eprint("ERROR: \(lockdownHint(error.code))")
    exit(1)
} catch {
    eprint("ERROR: \(error)")
    exit(1)
}
