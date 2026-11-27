# 界面性能诊断

改了面板、卡片、光标的动画或绘制方式，或者用户反馈卡顿、掉帧时，按下面的步骤测量。结论以测量为准，不以截图或主观判断为准。这里只管掉帧；删除动画里卡片错位、跳变、重叠这类逻辑问题由测试覆盖，见 `docs/architecture.md` 的「删除动画 · 测试」。改的是删除和撤销的动画时，脚本加 `--delete`：呼出面板后反复删除选中的卡片再撤销，打印 `delete` 和 `undo` 两组读数。改的是卡片内容（选中项变化时要重画）或光标时，加 `--move`：呼出面板后像按住方向键一样每 50 ms 移动一格，向右、向左各 8 格，打印 `right` 和 `left` 两组读数。改的是搜索、筛选或查询时，加 `--search`：呼出面板后在搜索框里每 80 ms 按一次键：打一个常见的词（每个字都有命中，列表跟着换），删掉；打一个几乎没有命中的词（要扫全表），删掉；用拼音组字输入「测试」，删掉。按键交给搜索框的字段编辑器，和真的打字一样经过 `TextField` 的绑定，按键没送到搜索框时脚本报错退出。按键按固定的节奏发出，不等上一次处理完，慢的版本不会因此打得更慢。整轮连续记录，打完再按按键的时间切开：每次按键的读数从它发出算到下一次按键发出，跨过两次按键的空档算在后一次上。每次按键打印一行，标签是按的键，多两个延迟：`key_to_commit_ms` 是从按键发出到这次按键的排版和图层提交做完，取按键之后的第二帧 display link（第一帧时可能还在提交），最多比实际晚一帧，只看主线程，在没有上屏数据的机器上也能比较；`key_to_present_ms` 是从按键发出到结果上屏，取那一帧提交的探针画面的上屏时间，没有上屏的帧时不打印。最后按 `common`、`rare`、`compose`、`delete` 四组打印中位数和最差的一次（`worst`）。测试历史只有 30 条，里面没有 `github` 这类词，看不出查询和换卡片的开销，脚本会先提醒一句；要用 `PASTEME_BENCH_HISTORY` 指向几千条的历史。和没有 `--search` 或者基准代码更旧的提交（包括 #93 之前的 main）比较时，把被测版本的 `Sources/PasteMeApp/PanelBenchmark.swift` 和 `scripts/bench-panel.sh` 拷到基线的 worktree 里再测（不提交），两边用同一份基准代码。

## 步骤

1. **先告诉用户。** 测量时面板会在屏幕底部反复弹出并取得键盘焦点，每次约 20 秒（`--delete` 约 40 秒，`--move` 约 25 秒，`--search 3` 约 30 秒）。开始前请用户别打字，也暂停视频播放：播放视频时 WindowServer 负载很高，呼出、收起也会缺二三十帧，读数没有意义。
2. **测改动后的版本。** 在仓库根目录运行 `scripts/bench-panel.sh`，记下最后两行 `median show` 和 `median hide` 的 `present_missed`。
3. **测基线。** 用 `git worktree add <临时目录> <基线提交>` 检出对比的版本（main，或怀疑引入问题之前的提交），在那个目录里运行同一个脚本。基线要包含 `PanelBenchmark`；更早的提交先 cherry-pick 加入它的那个提交。
   完成标准：两个版本各测两轮，问题版本的 `present_missed` 中位数每轮都明显更高。测量能这样稳定地 red，才进入下一步。
4. **逐项排查。** 给每个可疑的改动加一个临时开关（读一个 `PM_` 开头的环境变量），每次只关一项，每种配置跑一次脚本。完成标准：找到关掉之后中位数回到基线的那一项。
5. **修复后复测。** 完成标准：修复后的中位数回到基线水平；涉及外观的改动经过「外观检查」；临时开关已删除，worktree 已用 `git worktree remove` 删除。

## 读数

脚本每次呼出、收起各打印一行，最后打印中位数。第一次是冷启动，不计入中位数。

| 字段 | 含义 |
| --- | --- |
| `present_missed` | 实际上屏时缺的帧数：面板里一个 2×2 的 Metal 图层每帧提交一次，相邻两次上屏间隔超过 1.5 帧（120 Hz）的，按缺了几帧累计。用户感觉到的卡顿看这个。 |
| `main_missed`、`main_longest_ms` | 主线程上 display link 回调的间隔。主线程准时而 `present_missed` 高，说明瓶颈在渲染端：合成、裁切、阴影、模糊。 |
| `call_ms` | `show()` 或 `hide()` 本身的同步耗时，直接推迟第一帧。 |

- 单次结果波动大，只比较中位数。机器负载会改变绝对值，只比较同一轮里测出的结果。
- 参考值：#20 之后的 main，呼出 0～2，收起 0～1。#17 引入问题时，呼出约 18，大约三分之一的帧没能上屏。删除（2 秒，含颗粒和补位）约 1，撤销约 1～2；关掉颗粒、只留列表变化时删除和撤销也各缺 1 帧左右。
- 主线程缺帧数和上屏缺帧数差不多、而且每一次都很高时，先检查屏幕是不是在 60 Hz 下运行，或者机器负载高（`ps -Ao pcpu,comm -r | head`）。
- 测试历史由 `PanelBenchmark` 在空的临时 home 里自动生成：约 30 条来自本机系统应用的文本、链接和图片，每次都一样。链接带着链接预览（网站图标用来源应用的图标，一半有网页标题），呼出时依次出现的前 8 张里有两张链接。
- WindowServer 的 CPU 占用（`ps -Ao pcpu,comm -r`）在 40% 以上时，`present_missed` 会一下子变成十几帧，`call_ms` 也会波动好几毫秒。这时只比较同一轮里背靠背测出的基线和改动，或者等负载降下来再测。想知道某种卡片本身贵不贵，在测试里用不显示的 `NSHostingView` 反复排版、绘制单张卡片计时，不受屏幕和 WindowServer 影响。
- 传给应用的参数放在次数后面，例如 `scripts/bench-panel.sh 9 -cursorStyle flow`。
- 基准按开发版运行（ADR 0009），读的是开发版偏好域 `io.github.skjz.PasteMe.dev` 里的设置，一般是默认值，不是用户自己的设置。和 ADR 0009 之前的提交比较时，旧提交读的是用户的设置；两边设置不同（比如光标样式）时，用上面的参数把它们设成一样。
- 用户在自己的历史上觉得卡、基准却测不出来时，用用户的数据和 release 版本测：`PASTEME_BENCH_HISTORY=<history.sqlite>` 用这份历史的副本（`sqlite3 .backup` 拷贝，原文件不动），`PASTEME_BENCH_RELEASE=1` 用 release 优化编译。对比 main 时先用 `sqlite3 .backup` 固定一份副本，两边用同一份。
- 不想占用户的屏幕时，在另一台 Mac 上跑：本机编译 release 基准（`swift build -c release -Xswiftc -DDEBUG --build-path .build/bench-release`），把 `PasteMe` 拷过去，在临时 home 里运行。那台机器的屏幕如果是远程桌面的虚拟显示器，`presented` 一直是 0，上屏读数用不了，只看主线程的读数。想知道时间花在哪，用系统自带的 `sample <pid> 20 1` 采样，不需要 Xcode，也不会像 Instruments 那样在 `$TMPDIR` 留下大文件。
- 中位数会藏住偶尔的大卡顿：循环次数加到 25 次左右，把每一行都存下来，再算平均值和最差的 10%。

## 已经确认过的渲染端开销

- 在运行时裁切超出范围的子视图：比如标题栏 `.clipped()` 裁掉放大的图标，会让每张卡片在入场动画里逐帧重新合成（#17，在 #20 修复）。解决办法是把裁好的样子预先画成图片，见 `AppIconCache.headerIcon`。

## 已经确认过的主线程开销

- 搜索（#89）：每改一个字，`HistoryModel.query` 在主线程上同步查询一次。用 5333 条、238 MB 的真实历史（release，60 Hz 的屏幕，60 Hz 下每 80 ms 本来就要记 4 帧）测 `--search 5`，修复前每次按键的 `call_ms` 中位数约 54 ms，其中 `items(matching:)` 的 SQL 约 51 ms，置顶计数、候选列表、拼查询条件加起来不到 2 ms；`present_missed` 中位数 9～11，每次按键主线程最长被占的时间中位数约 60 ms。慢在列的顺序（见 `docs/architecture.md` 的「列的顺序」），第 9 版改过以后 `call_ms` 约 4～5 ms，SQL 约 3 ms，`present_missed` 中位数 4～5，主线程最长被占的时间中位数约 25 ms、最差的 10% 约 40 ms。还剩的是结果列表换了以后新出现的卡片：每次约 11 张（屏幕上 8 张，加上 `LazyHStack` 预先准备的几张），结果没变的按键也会重算这 11 张的 body，但很快。这部分没有单独的热点：在屏幕上把标题栏、内容、底部、外框阴影各关掉一项，每项只省 3～5 ms，不解码缩略图也没有差别，整张卡片换成空方块才回到底线。在屏幕上用 `/usr/bin/sample` 采样主线程（20 秒，忙碌约 3300 ms）：查询约占 18%；真正画图层（`CA::Layer::display`）约 4%，画文字几乎为 0；大头在 SwiftUI 的视图图更新，主要是排版（`sizeThatFits`，一层层 stack、padding、frame 和 `.overlay(alignment:)` 的对齐往下量尺寸）、把结果转成图层（`DisplayList.ViewUpdater`）和 `LazyHStack` 摆放，分在每个视图上，项目自己的 `body` 只占一百多个采样。量文字和生成富文本合起来约 10%～15%，但把预览截到 1000 字（屏幕上最多显示 11 行）读数没有变化。离屏计时（不显示的 `NSHostingView` 加 `cacheDisplay`）一张卡片约 5 ms，大部分在 `cacheDisplay` 用 CPU 画图，和屏幕上不一样，只能用来比较排版的部分（不到 1 ms）。输入法组字时（还没确认的拼音）不改 `query`，不查询，读数和什么都不做一样。

- 代码卡片（#28）：识别在记录时做，着色只做卡片显示的前 11 行，结果按条目和深浅外观缓存（`CodeHighlightCache`），所以带着色的 `AttributedString` 不会每次画卡片都重算。单张代码卡片和普通文本卡片从创建到画出来一样快。用 36 条代码的历史（`PASTEME_BENCH_HISTORY`，release）和 main 背靠背各测三轮，呼出、收起、移动光标的 `present_missed` 都不比 main 多。

- 链接卡片的衬线字体（拉丁字母 New York，中文换成宋体）要建字体描述、挂上备用字体，每次画卡片都新建会让 `show()` 多花几毫秒，所以 `EditorialFont` 按字号缓存。海报样式的图标光晕也预先画成图（`LinkIconCache.posterIcon`），不在运行时模糊。单张海报链接卡片从创建到画出来约 4.5 ms，文本卡片约 3.7 ms。

- 文件卡片的海报样式：单张卡片从创建到画出来约 4.2～4.5 ms，和海报链接卡片一样，比改版前的文件卡片（约 3.7 ms）多约 0.5 ms。多出来的主要是顶上那片 `PosterGlow` 渐变：离屏计时里去掉它就回到 3.7 ms，但换成预先画好的图片也一样贵（CPU 画一大片半透明的区域本身就要这么久），在屏幕上测也没有差别，所以没有换。用 17 条文件条目的历史（PDF、代码、照片、文件夹、多个文件、已经不在的文件，release）和 main 交替测，呼出的 `present_missed` 两边都是 0～2，收起都是 0。呼出的 `call_ms` main 四轮 18.5～25.2 ms（平均 22），改版后三轮 23.9～27.8 ms（平均 26），WindowServer 负载在 45%～56%，单轮波动有好几毫秒。多出的 3 ms 左右和每张卡片多 0.5 ms、一屏约 8 张对得上；这份历史全是文件，平时和文本、链接混在一起时更少。文件大小、文件夹项数在后台读（`FileFactsCache`），不占 `show()`。

- Liquid Glass 背景（#41）：SwiftUI 内容放在 `NSGlassEffectView` 的 `contentView` 里时，窗口每次上屏（`makeKeyAndOrderFront`、收起时的 `orderFrontRegardless`）玻璃都会让内容整个重画一遍，呼出的 `call_ms` 比 main 多约 6 ms、收起多约 4 ms。改成玻璃只当背景、内容叠在上面之后，呼出和收起的 `call_ms` 都不比 main 多。玻璃自己每次上屏还要 3～4 ms，这部分省不掉。

- 卡片的右键菜单写在卡片的 body 里（`.contextMenu { … }` 直接放按钮）时，SwiftUI 每次画卡片都把整个菜单建一遍。#9 给菜单加了「固定到」子菜单（每个 Pinboard 一个勾）后，`show()` 的 `call_ms` 多了约 7 ms；把菜单拆成单独的视图（`CardContextMenu`）后回到基线。改右键菜单时看 `call_ms`。

## 外观检查

- 计算机操作工具和 `screencapture` 都拍不到面板（没有屏幕录制权限，截图会过滤 PasteMe 的窗口）。
- `PASTEME_SNAPSHOT` 用 `cacheDisplay` 在 CPU 上重画面板，普通视图和阴影与屏幕一致。
- `drawingGroup` 里的模糊例外：截图和 `ImageRenderer` 里看起来正常，屏幕上却出现方框状的边缘。这类效果请用户在真实屏幕上确认。
- Liquid Glass 背景（#41）也要请用户在屏幕上看：`cacheDisplay` 画不出窗口后面的内容，截图里的玻璃不是屏幕上的样子。

## 试过但不可靠的测量方式

- **Instruments 的 Animation Hitches 模板**：每录十几秒就会在 `$TMPDIR` 留下十几 GB 的 `instruments*.ktrace` 和 `xrgpu_*`，删掉输出的 `.trace` 不会删它们，曾经把磁盘占满。`xctrace --launch` 按 bundle id 启动，可能启动机器上另一个旧副本。确实需要时先问用户；只录一次几秒，用 `--attach <pid>`，录完检查 `df -h` 和 `$TMPDIR`。
- **GPU 利用率**（`ioreg` 的 `Device Utilization %`）：随 GPU 频率变化，同一版本两轮测出 10% 和 34%，不能用来比较版本。
- **窗口位置采样**（`CGWindowListCopyWindowInfo`）：能看出窗口有没有逐帧移动，看不出内容是否按时上屏。
