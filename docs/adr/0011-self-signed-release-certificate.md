# 0011 发布版用自签名证书「PasteMe Release」签名，启动时清掉失效的授权条目

日期：2026-10-25

系统按代码签名的 designated requirement 记辅助功能授权。0.1.0 用的是临时签名，它的 requirement 是这一次构建的哈希（`cdhash H"…"`），每次构建都不一样。所以每次升级后，「辅助功能」列表里的旧 PasteMe 开关还开着却不起作用，`AXIsProcessTrustedWithOptions` 也不会再把新的加进列表：用户要找到旧条目删掉，点加号，在文件窗口里找到 PasteMe 加进来，再打开开关。有了应用内更新（ADR 0010）以后，每次更新都要来这么一遍。

现在：

- `scripts/release-certificate.sh create` 在发布者的登录钥匙串里生成一张自签名的代码签名证书「PasteMe Release」，`make-dmg.sh` 用它签名，没有就停下。requirement 变成 `identifier "io.github.skjz.PasteMe" and certificate leaf = H"…"`，和哈希无关，同一张证书签的新版本沿用原来的授权。证书没有人的名字，不像 Apple Development 证书会把发布者的名字带进应用。
- 启动时没有授权，就先运行 `tccutil reset Accessibility <bundle id>` 删掉这个应用的条目，再弹系统的授权提示（`Accessibility.forgetStaleGrant`）。系统会把新的 PasteMe 加进列表，用户只要打开开关。从临时签名的 0.1.0 升上来、或者证书换了的那一次，就只剩这一步。

2026-10-25 在 macOS 27 上用单独的 bundle id 实测过：临时签名的版本授权后，同一位置换成证书签名的版本，启动时清掉了旧条目、列表里只多出一个关着的开关；打开后再换成哈希不同、同一张证书签名的版本，启动时直接是已授权，没有弹提示。

## Considered Options

- Developer ID 签名加公证：系统认得出发布者，第一次打开也不用「仍要打开」，但需要付费的开发者账号，现在没有。有了以后换过去，用户要再打开一次开关（requirement 变了），启动时的清理照样管用。
- Apple Development 证书：requirement 固定，但证书上是发布者的名字和邮箱，会带进每个用户的应用里（`make-dmg.sh` 开头写过）。
- 只做启动时的清理，继续用临时签名：不用管证书，但每次更新都要打开一次开关。

## Consequences

- 证书只在发布者的钥匙串里，要备份（`scripts/release-certificate.sh` 开头写了怎么导出）。丢了只能生成新的，用户更新后要再打开一次开关，不会像 ADR 0010 的私钥那样收不到更新。
- 自签名证书不受系统信任（`security find-identity` 显示 `CSSMERR_TP_NOT_TRUSTED`），不影响签名、`codesign --verify` 和辅助功能授权；Gatekeeper 照样拦，第一次打开还是要「仍要打开」。任何人都能做一张同名的证书，所以它不能代替 ADR 0010 的更新签名。
- `tccutil reset` 要靠 LaunchServices 找到这个 bundle id。放在临时目录（`/private/tmp`）里的应用找不到，清理不起作用；装在「应用程序」里没有问题。
- 清理只在启动时、没有授权时做：有效的授权不会被删；用户自己关掉的开关，下次启动会变成重新询问一次。
- 证书 20 年后过期。`codesign` 没有加可信时间戳，过期后系统按当时的时间判断签名，到期前要换证书（用户再打开一次开关）。
