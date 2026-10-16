# 0004 搜索用 LIKE 子串匹配，暂不使用 FTS5

日期：2026-10-16

搜索在 SQLite 里用 `LIKE '%词%'` 做子串匹配，不建 FTS5 全文索引。原因是用户主要搜索中文：FTS5 自带的 `unicode61` 分词不切分中文，`trigram` 分词又要求查询至少 3 个字符，搜“发票”“微信”这类两个字的词会搜不到。LIKE 在数量级为一万条条目时足够快。

搜索实现封装在 `ClipQuery` / `ClipStore.items(matching:)` 之后（ADR 0002）。如果实测变慢，可以换成“FTS5 trigram 处理 3 个字符以上的查询，短查询仍用 LIKE”的组合，只改这一处。
