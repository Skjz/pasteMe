// 自动更新的签名钥匙（ADR 0010）。私钥只存在发布者这台 Mac 的登录钥匙串里，公钥写在 `UpdateSignature.publicKey`。
//
// 用法：
//   swift scripts/update-signing.swift generate                生成一对钥匙，私钥存进钥匙串，打印公钥（已经有了就不生成）
//   swift scripts/update-signing.swift public-key              打印钥匙串里那把私钥对应的公钥
//   swift scripts/update-signing.swift sign <文件> [<公钥>]      用私钥给文件签名，写成 <文件>.sig（Base64 的 64 字节签名）；
//                                                              给了公钥时，钥匙串里的私钥对不上就不签
//   swift scripts/update-signing.swift restore                 从备份恢复私钥：在提示处粘贴 Base64（不显示、不进命令历史）
//   swift scripts/update-signing.swift protect                 把已有的私钥改成每次读取都要输入登录钥匙串的密码
//
// 钥匙串里的私钥不信任任何应用，每次读取（public-key、sign、备份）系统都会弹窗要登录钥匙串的密码。
// 不要在弹窗里点「始终允许」：那样以后本机任何 Swift 脚本都能不问一声读走它。
//
// 私钥丢了，已经装好的 PasteMe 就再也收不到自动更新，只能让用户手动下载。备份：
//   security find-generic-password -s io.github.skjz.PasteMe.update-signing -w
// 打印出的 Base64 存进密码管理器；恢复时用上面的 restore。
import CryptoKit
import Foundation
import Security

let service = "io.github.skjz.PasteMe.update-signing"
let account = "ed25519"
let label = "PasteMe 自动更新签名钥匙"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let itemQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
]

/// 只看有没有这一项，不读私钥，不弹窗。
func keyExists() -> Bool {
    var query = itemQuery
    query[kSecReturnAttributes as String] = true
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

/// 钥匙串里存的是私钥原始 32 字节的 Base64，和 `security ... -w` 读写的一样。读的时候系统弹窗要密码。
func storedKey() -> Curve25519.Signing.PrivateKey? {
    var query = itemQuery
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { fail("读不出钥匙串里的签名钥匙：\(status)") }
    guard let key = parse(String(decoding: data, as: UTF8.self)) else { fail("钥匙串里的签名钥匙格式不对") }
    return key
}

func parse(_ base64: String) -> Curve25519.Signing.PrivateKey? {
    Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines))
        .flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
}

/// 读取私钥和改访问控制都不信任任何应用（连创建它的 swift 解释器也不信任）：每次读取，系统都弹窗要登录钥匙串的密码。
/// 钥匙串的 ACL 只有旧的 SecAccess 接口能设；新的 kSecAttrAccessControl 要数据保护钥匙串和签名过的应用，脚本用不了。
func protectedAccess() -> SecAccess {
    var access: SecAccess?
    guard SecAccessCreate(label as CFString, [] as CFArray, &access) == errSecSuccess, let access else { fail("建不了钥匙串的访问控制") }
    return access
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    var item = itemQuery
    item[kSecAttrLabel as String] = label
    item[kSecAttrAccess as String] = protectedAccess()
    item[kSecValueData as String] = Data(key.rawRepresentation.base64EncodedString().utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("存不进钥匙串：\(status)") }
}

func printPublicKey(_ key: Curve25519.Signing.PrivateKey) {
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    if keyExists() { fail("钥匙串里已经有签名钥匙了，不再生成。公钥：swift scripts/update-signing.swift public-key") }
    let key = Curve25519.Signing.PrivateKey()
    store(key)
    printPublicKey(key)
case "restore":
    if keyExists() { fail("钥匙串里已经有签名钥匙了。要换掉它，先在「钥匙串访问」里删掉「\(label)」") }
    guard let typed = getpass("粘贴备份的私钥（Base64，不显示）："), let key = parse(String(cString: typed)) else { fail("不是有效的私钥") }
    store(key)
    print("已恢复，公钥：", terminator: "")
    printPublicKey(key)
case "protect":
    // SecItemUpdate 只会在原来的 ACL 上加条目，信任 swift 解释器的那一条还在，所以读出来、删掉、按新的 ACL 重新存。
    guard let key = storedKey() else { fail("钥匙串里没有签名钥匙") }
    let deleted = SecItemDelete(itemQuery as CFDictionary)
    guard deleted == errSecSuccess else { fail("删不掉原来的签名钥匙：\(deleted)") }
    var item = itemQuery
    item[kSecAttrLabel as String] = label
    item[kSecAttrAccess as String] = protectedAccess()
    item[kSecValueData as String] = Data(key.rawRepresentation.base64EncodedString().utf8)
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else {
        fail("重新存进钥匙串失败（\(added)）。原来的已经删掉了，这是私钥，马上用 restore 存回去：\(key.rawRepresentation.base64EncodedString())")
    }
    print("已改成每次读取都要输入登录钥匙串的密码")
case "public-key":
    guard let key = storedKey() else { fail("钥匙串里没有签名钥匙") }
    printPublicKey(key)
case "sign":
    guard (2...3).contains(arguments.count) else { fail("用法：swift scripts/update-signing.swift sign <文件> [<公钥>]") }
    let path = arguments[1]
    guard let key = storedKey() else { fail("钥匙串里没有签名钥匙，先 generate 或从备份 restore") }
    if arguments.count == 3, key.publicKey.rawRepresentation.base64EncodedString() != arguments[2] {
        fail("钥匙串里的私钥和应用里的公钥对不上，签出来的更新装不上。检查钥匙串里的「\(label)」是不是备份的那一把")
    }
    guard let data = FileManager.default.contents(atPath: path) else { fail("读不了 \(path)") }
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("签名验证不过") }
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print("已生成 \(path).sig")
default:
    fail("用法：swift scripts/update-signing.swift generate | public-key | sign <文件> [<公钥>] | restore | protect")
}
