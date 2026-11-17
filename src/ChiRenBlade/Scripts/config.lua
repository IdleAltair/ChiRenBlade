-- ============================================================================
-- 影之刃零 · 炽刃 Mod 配置文件 (ChiRen Blade 1.0 Settings)
-- 调参向导整理：猫猫 (Gemini) 喵～
--
-- 【怎么改设置喵？】
-- 1. 只修改等号「=」右边的数字或 true/false，不要改动左边的英文名字，也不要删掉行尾的逗号「,」。
-- 2. 修改后按 Ctrl+S 保存，并【完全退出游戏重新启动】才会生效（只退回主菜单不算重启喵）。
-- 3. 写错了也不会坏存档！如果填错类型或超出有效范围，mod 会自动回退到默认值并在 UE4SS.log 里提醒你。
--
-- 【猫猫的懒人抄作业速查（不想看全部参数？只改下面对应的几项就行喵！）】
-- ★ 流派 A：轮椅无双爽玩流（1次拼刀直接放龙卷 + 切武360度弹红光 + 重击几乎不耗杀气）
--    Charges = 20, HeavyCostScale = 0.05（注意最小填0.05别填0喵）, TornadoEasyCast = true,
--    TornadoClashMin = 3, SwitchDeflectAngle = 360, SwitchDeflectRedEye = true
-- ★ 流派 B：电影级打击感流（拼刀瞬间全屏慢动作特写 + 慢后加速冲刺 + 更快破防打断）
--    ClashSlowmoEnabled = true, ClashSlowmoSpeed = 0.3, ClashSlowmoSeconds = 0.4,
--    SlowmoRushSpeed = 1.3, BreakThreshold = 2
-- ★ 流派 C：手残护肝宽松流（总是按不准时机？把拼刀、切武弹反和完美格挡窗口统统加宽！）
--    ClashWindowFrames = 18, SwitchDeflectFrames = 24, DeflectWindowFrames = 12, InvulnSeconds = 2.0
-- ============================================================================

return {

    -- ========================================================================
    -- 【第一区：拼刀核心奖励与杀气减耗（新手最常改这里喵！）】
    -- Section 1: Core Clash Rewards & Shachi Cost Reduction
    -- ========================================================================

    -- 拼刀成功后，送你多少次「免杀气」重攻击（手柄 Y 键 B 系连招）。填 0 = 关闭免耗。
    -- 【有效范围：0 ~ 20】默认 6 次。
    -- ★ 机制说明：游戏底层无法直接用反射/Hook 拦截重击扣费，mod 改为在原生「杀气结算段」（杀气槽中间暗淡的棕色段）
    --   把杀气补回。因此杀气条会来回涨跌；且在连续消耗杀气的连招途中，游戏内部聚合计算会拒绝修改，
    --   需等到「可恢复杀气的时刻」（如杀气连招停手结束、闪避、或轻重击穿插出轻击时）才会真正补回杀气喵！
    -- Free heavy attacks granted after a clash (0-20). Refunded via the native Shachi settlement bar.
    Charges = 6,

    -- 平时重攻击（没有免耗次数时）的杀气消耗永久折扣。0.5 = 半价；1.0 = 原价不打折。
    -- ★ 猫猫防呆提醒：有效范围是【0.05 ~ 1.0】！想几乎不耗杀气请填 0.05，千万别填 0（填 0 超范围会回退成 0.5 喵）！
    -- Permanent heavy-attack Shachi cost multiplier (0.05-1.0). 0.5 = half cost, 1.0 = vanilla.
    HeavyCostScale = 0.5,

    -- 拼刀成功后是否自动给炽刃刀身附魔火焰（true = 开启，false = 关闭）。
    -- Apply blade fire infusion after a clash (true/false).
    FireEnabled = true,

    -- 拼刀后刀身火焰附魔的持续秒数。与原版攒满刀劲的 15 秒火焰独立共存，互不覆盖。
    -- 【有效范围：0.5 ~ 30】默认 5 秒。
    -- Blade fire duration after a clash in seconds (0.5-30). Independent of vanilla 15s full-meter fire.
    FireSeconds = 5,

    -- 拼刀成功后获得的闪避无敌秒数。填 0 = 关闭拼刀无敌。
    -- 【有效范围：0 ~ 5】默认 1.2 秒。
    -- Invulnerability duration after a clash in seconds (0-5). 0 = off.
    InvulnSeconds = 1.2,


    -- ========================================================================
    -- 【第二区：风回云卷（刀劲三档大招 LB+Y）强化设置】
    -- Section 2: Whirlwind Ultimate (GA_Hun_ChiRen_BSup_C) Scaling
    -- （注：这招拼刀大招风回云卷是可以正常直接斩杀敌人的喵！）
    -- ========================================================================

    -- 是否开启「1 次拼刀直接满三档刀劲」捷径（false = 默认关闭，保留原版攒满刀劲门槛；true = 开启）。
    -- 开启后拼刀 1 次刀劲即满，放龙卷前的普通重击也会吃到满档加成喵。
    -- Force blade tier to Lv3 after a single clash so 1 clash can cast Whirlwind (true/false).
    TornadoEasyCast = false,

    -- 风回云卷的保底伤害倍率下限。默认 1 即倍率等于拼刀层数（1层1倍…6层6倍）；调高可保底（如填 3 则保底 3 倍）。
    -- 【有效范围：1 ~ 6】注意不能填得比下面的 TornadoClashMax 更大喵！
    -- Minimum Whirlwind damage multiplier floor (1-6). Must not exceed TornadoClashMax.
    TornadoClashMin = 1,

    -- 最多累积几次拼刀层数（即层数倍率上限，释放后清零；双发龙卷的第二发在 4 秒内自动沿用第一发倍率）。
    -- 【有效范围：3 ~ 10】默认 6 层（最高 6 倍）。
    -- Maximum stored clash stacks for Whirlwind multiplier (3-10).
    TornadoClashMax = 6,

    -- 在拼刀层数倍率之外再额外乘算的伤害倍率（最终倍率 = 拼刀层数 × 此值）。
    -- 【有效范围：1.0 ~ 3.0】默认 1.0；若改为 2.0，满 6 层可打出 12 倍伤害喵！
    -- Extra multiplier on top of the clash streak (1.0-3.0).
    TornadoDamageScale = 1.0,

    -- 释放风回云卷时的无敌秒数（三档刀劲版与耗杀气 C 变体均享受无敌）。填 0 = 关闭。
    -- 【有效范围：0 ~ 5】默认 2.5 秒。
    -- Invulnerability seconds when casting Whirlwind (0-5).
    TornadoInvulnSeconds = 2.5,

    -- 释放风回云卷时为刀身施加或延长火焰状态的秒数。填 0 = 关闭。
    -- 【有效范围：0 ~ 60】默认 15 秒。
    -- Blade fire duration applied or extended on Whirlwind cast in seconds (0-60).
    TornadoBurnSeconds = 15,


    -- ========================================================================
    -- 【第三区：切武弹反（切刀 GP）、刀劲保留与判定窗口】
    -- Section 3: Weapon-Switch Parry (GP), Stack Retention & Parry Windows
    -- （★ 帧数换算：按 30 帧/秒计，15 帧 = 0.5 秒，30 帧 = 1.0 秒，60 帧 = 2.0 秒喵）
    -- ========================================================================

    -- 切换武器后是否保留炽刃已有的刀劲层数不掉档（true = 保留，false = 关闭）。
    -- Keep ChiRen blade stacks (Lv1-Lv3) across weapon switches (true/false).
    SwitchKeepStacks = true,

    -- 是否给切出炽刃的起手攻击注入原生弹反（GP）窗口（true = 开启，false = 关闭）。
    -- 切武弹反成功同样送免耗重击、刀身火焰、无敌与打断计数（不加风回云卷层数喵）。
    -- Inject a native parry (GP) window at the start of ChiRen switch attack (true/false).
    SwitchDeflectInject = true,

    -- 切出炽刃起手弹反窗口帧数（30fps）。填 0 = 关闭。
    -- 【有效范围：0 ~ 60】默认 15 帧（即 0.5 秒，实测手感最佳）。
    -- Switch-attack parry window in frames at 30 fps (0-60). Default 15 (~0.5s).
    SwitchDeflectFrames = 15,

    -- 切武弹反的判定扇形角度。120 = 原版前方扇形；360 = 全身 360 度无死角弹反。
    -- 【有效范围：1 ~ 360】默认 120 度。
    -- Front cone angle in degrees for switch parry (1-360). 360 = omnidirectional.
    SwitchDeflectAngle = 120,

    -- 切武弹反是否连敌人的红光危招也能弹（false = 只弹蓝光/黑光；true = 连红光也直接弹反）。
    -- Allow switch parry to deflect red-glint attacks as well (true/false).
    SwitchDeflectRedEye = false,

    -- 炽刃「重击接轻击派生（拼刀反击）」的判定窗口帧数（30fps，只影响炽刃）。
    -- 【有效范围：0 ~ 60】默认 0 = 不修改（保持原版约 10.5 帧即 0.35 秒）；手残党可填 18~24。
    -- ChiRen heavy->light clash counter window in frames at 30 fps (0-60). 0 = vanilla (~10.5 frames).
    ClashWindowFrames = 0,

    -- 按住格挡键「完美格挡弹反」的窗口帧数（30fps，影响全武器与全难度）。
    -- 【有效范围：0 ~ 60】默认 0 = 不修改（保持原版 6 帧即 0.2 秒）。
    -- Global held-block perfect parry window in frames at 30 fps (0-60). 0 = vanilla (6 frames).
    DeflectWindowFrames = 0,


    -- ========================================================================
    -- 【第四区：切刀 GP「仁慈火龙卷」与敌人缠身火视觉】
    -- Section 4: Switch-GP "Merciful Fire Tornado" & Enemy Burn Visuals
    -- ★ 仁慈龙卷说明：切刀 GP 自动甩出的黑伤火龙卷会追踪并灼烧敌人，但伤害封顶保留敌人最后 1 点生命值，
    --   不会直接烧死敌人（避免直接改 0 血卡死 Boss 转阶段，且贴合原生非致死燃烧设计），最后一击交由你亲手收刀喵！
    -- ========================================================================

    -- 切刀 GP 成功时，是否在身前地面自动甩出一发「处决同款」黑伤火龙卷（true = 开启，false = 关闭）。
    -- Spawn the HeiShang execution fire tornado automatically on a successful switch GP (true/false).
    SwitchTornadoEnabled = true,

    -- 切刀 GP 火龙卷的范围伤害倍率。填 0 = 纯视觉特效无伤害。
    -- 【有效范围：0 ~ 5】默认 2.0（补足实战移动中约一半的跳数命中率，想调龙卷伤害直接改这里喵）。
    -- Switch-GP tornado damage multiplier (0-5). 0 = visual only, default 2.0.
    SwitchTornadoDamageScale = 2.0,

    -- 切刀 GP 火龙卷单次完整命中的基础伤害（随玩家攻击力线性成长）。填 0 = 回退为攻击力×弹道系数。
    -- 【有效范围：0 ~ 20000】默认 1100（对齐实测原版风回云卷 1 层伤害）。
    -- Base total damage of the switch-GP tornado at calibrated attack (0-20000). Default 1100.
    SwitchTornadoDamageBase = 1100,

    -- 切刀 GP 火龙卷命中点燃敌人的持续秒数（同时挂原生燃烧 DoT 与敌人身体着火特效）。填 0 = 不点燃。
    -- 【有效范围：0 ~ 30】默认 5 秒（与玩家刀上的 FireSeconds 互不影响喵）。
    -- Enemy burn duration in seconds applied by the switch-GP tornado (0-30). Default 5s.
    SwitchTornadoBurnSeconds = 5,

    -- 是否开启敌人身体燃烧的缠身火焰视觉特效（true = 默认开启，龙卷点燃敌人时敌人全身着火约 5 秒）。
    -- Enable owned Niagara body-fire visual on burning enemies (true/false).
    EnemyBurnVisual = true,

    -- 切刀 GP 成功到火龙卷冒出的现实延迟秒数（配合挥刀收势动作）。
    -- 【有效范围：0 ~ 3】默认 0.6 秒。
    -- Real-time delay in seconds before the switch-GP tornado spawns (0-3).
    SwitchTornadoDelaySeconds = 0.6,

    -- 火龙卷生成位置与伤害范围微调（一般保持默认即可喵）：
    -- Distance (cm, 0-600), Drop (cm, 0-300), Radius (cm, 0-1000), Angle (deg, 1-360), BurnEvery (1-20).
    SwitchTornadoDistance = 215,
    SwitchTornadoDrop = 120,
    SwitchTornadoRadius = 300,
    SwitchTornadoAngle = 360,
    SwitchTornadoBurnEvery = 4,


    -- ========================================================================
    -- 【第五区：拼刀破防打断与慢动作打击感特写】
    -- Section 5: Clash Break Interrupt & Slow-Motion Hit Feedback
    -- ========================================================================

    -- 拼刀或切刀 GP 累积满一定次数后，是否用游戏原生 Break 受击强行打断敌人（true = 开启，false = 关闭）。
    -- Interrupt the enemy with native Break hit reaction every N clashes (true/false).
    BreakOnClash = true,

    -- 触发一次破防打断所需的拼刀次数（同一敌人 30 秒未拼刀则清零计数）。
    -- 【有效范围：1 ~ 10】默认 3 次（填 1 = 每次拼刀都打断喵）。
    -- Clashes required to trigger a Break interrupt (1-10). Default 3.
    BreakThreshold = 3,

    -- 切武弹反（切刀 GP）成功时的独立慢动作开关（true = 默认开启，补足弹普通攻击时的慢放反馈）。
    -- Independent slow-motion on switch-attack parry (true/false, on by default).
    SwitchSlowmoEnabled = true,

    -- 切武弹反慢放的世界速度倍率（【0.05 ~ 1.0】默认 0.6 = 60% 速度）与持续真实秒数（【0.05 ~ 2.0】默认 0.2 秒）。
    -- Switch-parry slow-motion speed factor (0.05-1.0) and real-time duration in seconds (0.05-2.0).
    SwitchSlowmoSpeed = 0.6,
    SwitchSlowmoSeconds = 0.2,

    -- 普通拼刀成功时，是否在游戏自带顿帧之上再叠一层全屏慢动作（false = 默认关闭，喜欢强特写可改 true）。
    -- Extra world slow-motion on normal clash (true/false, off by default).
    ClashSlowmoEnabled = false,

    -- 普通拼刀额外慢放的世界速度倍率（【0.05 ~ 1.0】默认 0.3）与持续真实秒数（【0.05 ~ 2.0】默认 0.4 秒）。
    -- Normal clash slow-motion speed factor (0.05-1.0) and real-time duration in seconds (0.05-2.0).
    ClashSlowmoSpeed = 0.3,
    ClashSlowmoSeconds = 0.4,

    -- 慢放结束后的「慢—快」加速冲刺倍率（【1.0 ~ 3.0】默认 1.0 = 关闭，填 1.3 可快放 30%）与持续秒数（【0.05 ~ 1.0】）。
    -- Post-slowmo rush speed multiplier (1.0-3.0, 1.0 = off) and duration in seconds (0.05-1.0).
    SlowmoRushSpeed = 1.0,
    SlowmoRushSeconds = 0.15,


    -- ========================================================================
    -- 【第六区：底层防呆、日志与内部调试项（普通玩家请保持默认，无需修改喵！）】
    -- Section 6: Internal Safeguards, Fallback Routes & Diagnostics (Keep defaults)
    -- ========================================================================

    -- 拼刀去重冷却（0~2s）、弹刀触发总开关、无敌锁血兜底、龙卷还原超时（1~8s）、破防维持窗口（0~3s）
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    HealthGuard = false,
    TornadoDamageSeconds = 4.0,
    BreakHoldSeconds = 1.2,

    -- 旧版切武攻击盒回退方案（已被 SwitchDeflectInject 取代，切勿同时开启）
    SwitchAttackBlock = false,
    SwitchAttackBranch = "Normal",
    SwitchAttackWindowFrames = 7,

    -- 日志与开发者内部探针（LogImportant 默认开启记录关键加载与触发；其余日常游玩全部保持 false 喵）
    LogImportant = true,
    LogEvents = false,
    LogDamage = false,
    ProbeSwitchAttack = false,
    ProbeNativeFinish = false,
    ProbeBurnVisual = false,
    ProbeCombatApi = false,
    TestBurnAttach = false,
}
