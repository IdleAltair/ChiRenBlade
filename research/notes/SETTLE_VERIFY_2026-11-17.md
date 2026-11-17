# 免耗结算实现与验证（2026-11-17 15:24 会话）

按 REVIEW_TWO_PROBLEMS 的"费用快照＋每次激活一次性结算"实现，已部署实测。代码见同目录 main.lua。

## 实现
- `HeavyActivate` 入口立即快照 `consumedSnapshot = readNumber(self, "Actual Shachi Consumed")`（数字拷贝，解耦能力 UObject 复用）。
- `ScheduleShachiSettlement(consumed, keepScale)`（替换旧 `ScheduleShachiRefund` raw 差值 watcher）：
  - consumed/keepScale 有限性校验（consumed≥0，keepScale∈[0,1]），refund=consumed×(1−keepScale)，refund≤0 跳过。
  - 一次性 `After(80)` 结算：SamePlayer(ownerKey) 保护换图/死亡/读档；读真实 `Shachi`/`Shachi_Max`（readNumber 取 CurrentValue）；current≥max 跳过（满条丢弃余额，不 bank、不削原生超额）；add=min(refund, max−current)；ShachiSet(current+add)。
  - `After(150)` 有限读回确认 CurrentValue 未被聚合器恢复（不写 BaseValue）。
- 调用点：freeAttack→keepScale 0；付费且 HeavyCostScale<1→keepScale=HeavyCostScale。
- 旧 raw 差值退款彻底停用（日志无 `refund +Nms`）。refundToken 递增保留为死代码（不再驱动取消）。

## 验证（15:24 会话，grep `shachi settle`）
- 归因定额：consumed 42.6/84.6/126.6 → refund 同值（免费）；付费 refund 21.3=42.6×0.5。✓
- 封顶：cur 717.4→760.0（真实 Shachi_Max=760）。✓
- 连击各退各的：每激活一条 settle，新激活不取消旧退款。✓
- **CurrentValue 写持续有效**：多数 readback cur==target（浮点微差）。✓
- 无 ERROR。✓

## readback 掉回归因（非覆盖）
4 条 readback 掉回 ~188.8（如 760→571.19）。抽查 line 2788–2795 实锤：
- 2788 settle 717.4→760（退款生效）；2789 +160ms 仍 760；
- 2792 `switch seq 27: GA_Hun_Long_Counter_C`（切武 counter）+ 2795 拼刀；
- 2790 +260ms 掉到 571。
掉到 571.19 而非 settle 前 717.4 → 退款写未被引擎恢复；188.81 是切武 counter 技能的合法扣费落在 readback 窗口内。结算只补本次 consumed，不补其他技能/受击损失，符合 GPT 约束。其余 3 条同模式（掉回值均 ~188.8）。

## 入口时序证据（14:54 会话，grep `shachi entry`）
- consumed 入口已有值（entry==+80ms）→ 扣费在回调前已落地，入口快照成立。
- 能力地址复用：B_C=...245936 / BB_C=...244064 / BBB_C=...442992（同类同 UObject）→ 必须数字快照＋按 seq，不能靠 addr 去重。
- 杀气不足（#32/#33）：cur=0、consumed=35.47/33.40（实际扣光量，非标准费用）→ 归因仍成立。

## 待补边界（GPT 要求）
- 取消攻击时 consumed 是否重置（本轮未专门测）。
- 杀气不足时结算恢复（逻辑上 consumed=实际扣光量→退还原量，本轮 settle 未见非标准 consumed，需专测）。
- 同能力快速重激活改变费用（addr 复用已证，数字快照解耦；需确认连续不同 consumed 各退各的）。
- 事后退款不解决"杀气不足原生拒绝发动"（玩法层面，另议）。