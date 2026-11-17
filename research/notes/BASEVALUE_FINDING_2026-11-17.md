# 免耗 BaseValue 持久层 + 原生双层结算发现（2026-11-17 15:56 会话）

## 背景：CurrentValue 退款被聚合器恢复
即时/80ms 写 `Shachi.CurrentValue` 均在写后 ~250–270ms 被引擎恢复回退款前值（15:42 会话 #24/#25 实锤：760 held 到 +160ms，+260ms 掉回 717，期间无新激活）。150ms readback 太早赶在恢复前，误判持续有效。

## BaseValue 实验（结算改写 BaseValue += refund，150/600/1200ms 长读回双层）
- **BaseValue 持久**：多组 readback base 停在写入值不被抹（如 line 2716 base 506.9→633.4，+150/600/1200ms 均 633.4）。解决 CurrentValue 瞬态问题。
- **cur 滞后 base**：+150ms cur 常仍=退款前值，base 已升；cur 在 600–1200ms 或特定动作后结算上来。
- **回气正常**：cur 仍向 base/max regen（line 2100 cur 633→753→758；line 2439 533→632→635）。
- 无 ERROR、无崩溃。用户视觉确认免耗不再直接变动可用杀气条。

## 原生双层结算机制（用户 UI 观察 + 数据吻合）
- 杀气双层：`CurrentValue`=可用杀气（UI 棕条）；`BaseValue`=含待结算总量。
- **base − cur 差 = UI 上比棕色暗淡的中间段** = 原生"待结算杀气"（用户截图观察）。
- 退款写 base → 进待结算暗淡段 → 随时间/动作结算进 cur。疑似原生特殊武器补回杀气通道。
- **穿插普攻恢复杀气** = 普攻触发 base→cur 结算（原生行为）。

## 结算规则（当前实现）
- 入口快照 consumed（能力 UObject 复用，数字拷贝解耦）。
- refund = consumed×(1−keepScale)，免费 0 全退/付费 keep HeavyCostScale。
- 封顶：current≥Shachi_Max 跳过；add=min(refund, max−current)；写 base += add。
- 每激活一次性结算（回调内同步），新激活不取消旧退款；SamePlayer 保护换图/死亡/读档。
- 长读回 150/600/1200ms 双层（诊断，发布前清）。

## 待评估
- cur 滞后 base 仅剩**视觉层面**（连招中可用条 dipped、停手补回）；功能层面因用户天赋"杀气不足可释放连招"保证不耗光，拒绝发动边界不存在。是否用 both-write 消除连招 dip 属可选视觉改进。
- 写 BaseValue 是否完全契合原生语义（目前看接上了原生待结算通道，回气正常，非破坏性）。
- 与 GPT 复核对照：GPT 曾警告勿盲写 BaseValue 怕改回气语义；实测回气正常且命中原生待结算机制，倾向可用，请 GPT 复核此发现。

## 连招滞后实锤（16:12 会话，用户 UI 观察 + 数据吻合）
- 用户观察：单击停手后暗淡棕条补回；全 Y 连招不断则连招中间不能补回。
- 停手/间隔（line 2305/2326/2481）：base 717→760，cur +150ms=717 滞后，+600ms cur=760 结算上来。
- 连招中（line 2563/2624/2648，~1–1.5s/击）：cur 持续滞后 base（+150/600/1200ms cur=590/base=633 不落地），停手才结算。
- 机制：cur 结算事件/间隔驱动（停手/普攻触发），连招中无触发→可用 cur dipped。总杀气守恒（base 保留）。
- **边界2（长连招 cur<费用拒绝发动）不存在**：用户点了天赋"杀气不足仍可释放杀气连招"，保证不耗光杀气条，连招持续可放。本轮 cur 最低 590+ 亦未卡。

## 候选改进：同时写 cur + base（待 GPT 复核/实测）
- 原理：CurrentValue 单写被抹~260ms，因聚合器按 base 重算 cur、base 无退款→拉回原值。若 base 也含退款，重算把 cur 拉向含退款的 base→cur 立即补且持久。
- 拟：结算时 base += add 且 cur += add（ShachiSet）。base 锚定持久，cur 给即时可用，消除连招 dip。
- 安全性：BaseValue 实验已证 base 写安全（回气正常、命中原生待结算通道）；cur 写锚定 base 应同样安全。需长读回验证连招中 cur 持久不 dipped。