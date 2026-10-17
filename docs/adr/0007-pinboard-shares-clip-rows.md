# 0007 Pinboard 引用历史里的条目，不另存一份

日期：2026-10-17

Pinboard（#9）用 `pinboard_items(pinboard_id, clip_id, sort_order)` 引用 `clips` 里的行，固定的条目同时还是历史里的条目。Paste 的 Pinboard 和历史互相独立：在历史里删掉一条，Pinboard 里的那份还在。我们没有照搬，是因为引用同一行时，编辑、起标题、识别出的文字和链接预览只有一份，在哪里看到的都一样；去重（`content_hash`）也只有一套规则，再复制一次固定过的内容就是同一个条目。代价是删除的含义要看在哪个标签里：在「历史」里 ⌘⌫ 删除条目，它也从所有 Pinboard 里消失（可以 ⌘Z）；在 Pinboard 里 ⌘⌫ 只是移出，条目还在历史里。清空历史只删除不在任何 Pinboard 里的条目，所以清空以后「历史」标签里还能看到固定的条目。

## Considered Options

- 固定时复制一份到 Pinboard：两边完全独立，但编辑、标题和附加信息要在两份之间同步，或者接受它们不一致；同样的内容会有两个 `content_hash` 相同的行，现在的唯一约束要改。
- 给 `clips` 加 `in_history` 标记：在「历史」里删除固定的条目只是隐藏，清空历史后「历史」标签里也看不到它们。查询、去重、撤销都要多处理一种状态，而按 Pinboard 筛选时又要决定看不看已经隐藏的条目。等用户确实觉得清空后还看到固定的条目碍事，再考虑。

## Consequences

- 在「历史」里删除固定过的条目会连 Pinboard 里的一起删掉。卡片底部的图钉提示它固定过；撤销会放回它在各个 Pinboard 里的位置（`DeletedClip.pins`）。
- 以后要让历史和 Pinboard 互相独立，需要一次数据迁移（加 `in_history` 或复制行），并改掉 `HistoryModel.delete` 在两种标签里的分支。
