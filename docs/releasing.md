# 发布 PasteMe

发一个新版本的步骤：改版本号、打包签名 DMG、发布前检查、在 GitHub 上发布。签名和更新的设计理由见 ADR [0010](adr/0010-self-signed-updates.md)、[0011](adr/0011-self-signed-release-certificate.md)，应用内更新怎么检查和安装见 [architecture.md](architecture.md) 的「检查更新」。

版本号按 SemVer，tag 写成 `v0.1.0` 这样。

1. 改 `Resources/Info.plist` 的 `CFBundleShortVersionString`，`CFBundleVersion` 加一；[使用说明](guide.md)标题里的版本号一起改；这一版加了值得一提的功能时，README.md 和 README.en.md 两份一起补上。CHANGELOG 把 Unreleased 下的条目移到新版本的标题 `## [x.y.z] - 日期` 下，文末的比较链接加上新版本。这些改动走 PR 合进 main。
2. 在合并后的 main 上运行 `scripts/make-dmg.sh`，得到 `build/PasteMe-x.y.z.dmg` 和自动更新用的签名 `build/PasteMe-x.y.z.dmg.sig`（私钥在发布者的钥匙串里，没有就停下，见 ADR 0010）。它带 `PASTEME_RELEASE=1` 打包，bundle id 保持 `io.github.skjz.PasteMe`，接得上用户已有的设置和历史；应用是通用二进制，用自签名证书「PasteMe Release」签名（ADR 0011）；钥匙串里没有这张证书、或者签出来的 `certificate leaf` 不是 `CERTIFICATE_SHA1`（`712284cf…983b`）就停下，不会退回临时签名，也不会用一张同名的新证书签。
3. 发布前挂载 DMG（`hdiutil attach -nobrowse -readonly`）检查：`lipo -info` 有 x86_64 和 arm64；`xcrun vtool -show-build` 里每个架构的 `sdk` 都是真实的 SDK 版本；`codesign -d -r-` 里是 `certificate leaf = H"712284cfaa92f8c43b961438cd9dc0e83a0d983b"`（只看 `Authority=PasteMe Release` 不够，同名的证书谁都能做）；二进制里搜不到本机路径（`bundle.sh` 打发布版时用 `strip -S` 去掉调试符号，搜到 `$HOME/` 就报错退出）；Info.plist 的 `CFBundleIdentifier` 是 `io.github.skjz.PasteMe`，不是 `.dev`。用临时 home 把两个架构各启动一次（`arch -x86_64` 要装了 Rosetta 的 Mac）。这要从 shell 直接运行，会弹署名为终端或 Claude 的授权框（见 [architecture.md](architecture.md) 的「在真实应用里验证」第 3 步），先告诉用户，弹出后点「拒绝」。
4. `gh release create vx.y.z build/PasteMe-x.y.z.dmg build/PasteMe-x.y.z.dmg.sig --target main`，两个文件都要传，少了 `.sig` 用户的 PasteMe 只能提示、不能自动安装，tag 打在合并后的 main 上。发布说明写这一版的主要变化、怎么安装和升级、系统要求，以及 DMG 的 SHA-256。
   发布说明中英双语（从 0.2.1 起；README 也有中英两份），写法要短：每条变化中文一行、紧跟英文一行。安装步骤（第一次打开要在「隐私与安全性」里点「仍要打开」）不在发布页重复，链到 README.md 的「安装」和 README.en.md 的「Install」；发布页只写 README 里没有的：从上一版怎么升级（菜单栏菜单里的「更新到…」，同一张证书签的版本之间升级授权仍然有效），以及从 0.1.0 升上来时 PasteMe 会弹出授权提示，要在列表里打开新出现的那个 PasteMe 的开关。应用的界面只有中文，英文里提到菜单项和按钮时写中文原文、括号里给英文，用户照着找得到。不要整份中文写完再整份英文：v0.2.1 这样写过，安装步骤写了两遍，长了一倍。也不要用 `<details>` 折叠英文：应用内更新的弹窗（`Updater.notesView`）显示整份发布说明，不认 HTML，标签会原样显示。
