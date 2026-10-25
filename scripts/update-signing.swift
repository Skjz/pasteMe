// 自动更新的签名钥匙（ADR 0010）。私钥只存在发布者这台 Mac 的登录钥匙串里，公钥写在 `UpdateSignature.publicKey`。
//
// 用法：
//   swift scripts/update-signing.swift generate      生成一对钥匙，私钥存进钥匙串，打印公钥（已经有了就不生成）
//   swift scripts/update-signing.swift public-key    打印钥匙串里那把私钥对应的公钥
//   swift scripts/update-signing.swift sign <文件>    用私钥给文件签名，写成 <文件>.sig（Base64 的 64 字节签名）
//
// 私钥丢了，已经装好的 PasteMe 就再也收不到自动更新，只能让用户手动下载。备份：
//   security find-generic-password -s io.github.skjz.PasteMe.update-signing -w
// 打印出的 Base64 存进密码管理器；恢复时用 `security add-generic-password -s io.github.skjz.PasteMe.update-signing -a ed25519 -w <它>`。
import CryptoKit
import Foundation
import Security

let service = "io.github.skjz.PasteMe.update-signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// 钥匙串里存的是私钥原始 32 字节的 Base64，和 `security ... -w` 读写的一样。
func storedKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { fail("读不出钥匙串里的签名钥匙：\(status)") }
    guard let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("钥匙串里的签名钥匙格式不对") }
    return key
}

func printPublicKey(_ key: Curve25519.Signing.PrivateKey) {
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate":
    if storedKey() != nil { fail("钥匙串里已经有签名钥匙了，不再生成。公钥：swift scripts/update-signing.swift public-key") }
    let key = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "PasteMe 自动更新签名钥匙",
        kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("存不进钥匙串：\(status)") }
    printPublicKey(key)
case "public-key":
    guard let key = storedKey() else { fail("钥匙串里没有签名钥匙") }
    printPublicKey(key)
case "sign":
    guard arguments.count == 2, let path = arguments.last else { fail("用法：swift scripts/update-signing.swift sign <文件>") }
    guard let key = storedKey() else { fail("钥匙串里没有签名钥匙，先 generate 或从备份恢复") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("读不了 \(path)") }
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("签名验证不过") }
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print("已生成 \(path).sig")
default:
    fail("用法：swift scripts/update-signing.swift generate | public-key | sign <文件>")
}
