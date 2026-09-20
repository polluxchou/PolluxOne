# pipeline

「新闻 → 口播稿」调研管线。设计见
`docs/superpowers/specs/2026-09-17-news-brief-pipeline-design.md`。

**这个包目前只有确定性内核**——spec §3 说的「刻意不用 AI 的那几步」：

| 阶段 | 模块 |
|---|---|
| ④ 归并去重 | `src/dedupe/merge.ts` |
| ⑤ 交叉验证 | `src/dedupe/independence.ts` · `conflict.ts` · `classify.ts` |
| ⑥ 选点（名额与门槛） | `src/draft/select.ts` |
| ⑧ 挂信源 | `src/draft/bind.ts` |
| ⑨ 时长与气口 | `src/domain/prosody.ts` |
| §10.1 成本估算 | `src/domain/estimate.ts` |

`src/dedupe/union-find.ts` 是上面两处分组共用的原语；`src/core.ts` 把这几段串起来，
`src/cli.ts` 是磁盘与类型化代码之间的信任边界（它校验输入，因为畸形输入最坏的
后果不是报错，是一个看起来很合理的错答案）。

①抓原文 ②扩展检索 ③抽事实 ⑦成稿 属于模型与网络层，**还没做**。

## 跑

    npm install
    npm test          # 97 个，全部离线，不需要任何 API key
    npm run typecheck
    npm run brief -- test/fixtures/reserve-cut.json

`npm test` 一次模型都不调、一个网络请求都不发。这是有意的：**护城河上的算术
必须能不花钱地反复验证。**

`npm run brief` 喂进去的是降准那条新闻的五个信源，其中**一个是另一个的逐字转载**。
出来的结果里那条头条事实是 `independence: 3` 而不是 4——这一个数字就是整个包
存在的理由。路透说 23 亿、彭博说 31 亿，两条都被标成 `conflicted` 且不进稿。

退出码：`0` 正常 · `1` 出稿了但绑定失败 · `2` 输入读不了或管线抛错。

## 运行时依赖为零

和 iOS 侧「V1 无第三方 SPM 包」同一条纪律。devDependencies 只有 typescript、
vitest、tsx 和 @types/node。
