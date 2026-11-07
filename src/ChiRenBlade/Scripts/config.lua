-- ChiRen Blade settings.
-- Edit the values, save, and restart the game. A setting that is missing, has the wrong type, or is
-- outside its range keeps the built-in default, and the log says so.
--
-- 炽刃 mod 配置。
-- 改完保存并重启游戏生效。缺失、类型不对或超出范围的项会自动用回默认值，并在日志里说明。

return {
    -- How many heavy attacks cost no Shachi after a successful clash (0-20).
    -- 拼刀成功后，接下来多少次重攻击免杀气（0-20）。
    Charges = 6,

    -- Apply the blade's fire effect after a clash. true / false.
    -- 拼刀后是否附带火焰附魔。true / false。
    FireEnabled = true,

    -- How many seconds the mod's fire burns (0.5-30). The game's own 15-second fire from full blade
    -- energy is a separate effect and is not changed.
    -- 火焰持续秒数（0.5-30）。原版攒满刀劲的 15 秒火焰是独立效果，不受这里影响。
    FireSeconds = 5,

    -- Debounce between two clash triggers, in seconds (0-2).
    -- 两次拼刀触发之间的去重窗口，秒（0-2）。
    CooldownSeconds = 0.6,

    -- Use the player's deflect component as the clash trigger.
    -- 用玩家的 DeflectComponent 作为拼刀触发点。
    TriggerOnDeflect = true,

    -- Permanent heavy-attack cost scale (0.05-1.0). 0.5 = the Shachi a ChiRen heavy attack costs is
    -- halved; 1.0 = off. The game ignores the ability's own cost fields and the cost-reduction
    -- attribute, so the mod watches the Shachi bar after each non-free heavy attack and refunds the
    -- part this scale removes. Free attacks from a clash are not refunded.
    -- 炽刃重攻击杀气的永久倍率（0.05-1.0）。0.5 = 消耗减半；1.0 = 关闭。
    -- 游戏不读技能自带的 Cost 字段和那个减免属性，所以 mod 在每次非免耗重攻击后盯杀气条，
    -- 把倍率之外的部分补回去。拼刀免耗的那几次不参与回补。
    HeavyCostScale = 0.5,

    -- The block parry's perfect window, in frames at 30 fps (0-60). Game value is 6 (0.2 s).
    -- This is NOT the weapon clash window: the clash's frames are part of each attack asset, and the
    -- game has no global setting for them. Applies to every difficulty. 0 = no change.
    -- 格挡弹反的完美判定窗口，30 fps 下的帧数（0-60），游戏原值 6（0.2 秒）。
    -- 这不是拼刀窗口：拼刀的判定帧写在每招的资产里，游戏没有对应的全局配置项。
    -- 五个难度都会写入。0 = 不修改。
    DeflectWindowFrames = 0,

    -- Seconds of the game's own dodge invulnerability applied after a clash (0-5). 0 = off.
    -- 拼刀后获得的无敌秒数（0-5），用的是游戏自己的闪避无敌效果。0 = 关闭。
    InvulnSeconds = 1.2,

    -- Write the player's health back to the start value every 16 ms during the invulnerability
    -- window, as a fallback for a hit that the game effect does not stop. Off by default: the game's
    -- own invulnerability effect covers the window in testing, and this is the highest-frequency
    -- property access in the mod. Turn it on if damage gets through.
    -- 无敌期间每 16ms 把玩家血量写回起始值，作为游戏无敌效果之外的兜底。默认关闭：
    -- 实测只靠游戏无敌就够，而且这是 mod 里频率最高的属性访问。如果发现漏伤害再打开。
    HealthGuard = false,

    -- Seconds of invulnerability applied when 风回云卷 (GA_Hun_ChiRen_BSup_C) activates (0-5).
    -- 0 = off. Triggered by the heavy input.
    -- 风回云卷（GA_Hun_ChiRen_BSup_C，重攻击触发）释放时的无敌秒数（0-5）。0 = 关闭。
    TornadoInvulnSeconds = 2.5,

    -- Lowest clash count used for the tornado damage multiplier (1-6). The whirlwind itself still
    -- needs the game's blade-force Lv3, so a real cast normally happens at 3+ clashes; this value
    -- is the multiplier floor for a cast that arrives with fewer, which makes the default range 3-6x.
    -- 计入龙卷伤害倍率的最低拼刀次数（1-6）。风回云卷本身仍需要游戏的三档刀劲，
    -- 实际释放时通常已有 3 次以上拼刀；这个值只是次数不足时的倍率下限，默认倍率范围即 3-6 倍。
    TornadoClashMin = 3,

    -- Highest clash count that counts toward the tornado (3-10). The clash streak is shown by
    -- "tornado combo: n/max" in the log and is consumed by a cast; six is the most stored clashes.
    -- Every BSup whirlwind cast gets the bonus; the second cast of a double cast reuses the first
    -- cast's multiplier for 4 seconds.
    -- 计入龙卷伤害的最高拼刀次数（3-10），默认最多存储 6 次拼刀。日志里的
    -- "tornado combo: n/max" 就是它，释放后清零。所有 BSup 龙卷都吃加成；
    -- 双发的第二发在 4 秒内沿用第一发的倍率。
    TornadoClashMax = 6,

    -- Extra multiplier on top of the clash count (1.0-3.0). The damage multiplier is
    -- min(clashes, TornadoClashMax) * this value and is applied to the two attack bullets'
    -- PhysicalDamage and ElementDamage while the move runs; vanilla values are restored after.
    -- 在拼刀次数之外再乘的倍率（1.0-3.0）。最终伤害倍率 =
    -- min(拼刀次数, TornadoClashMax) × 此值，只改两颗龙卷子弹的物理与元素伤害，结束自动还原。
    TornadoDamageScale = 1.0,

    -- How long the bullet damage replacement may stay applied before the safety restore (1-8).
    -- The ability's own end event restores it earlier when it fires.
    -- 子弹伤害替换的最长保留时间（1-8）。技能正常结束时会提前还原，这里是兜底。
    TornadoDamageSeconds = 4.0,

    -- Seconds of the ChiRen fire state started by a tornado cast (0-60). 0 = off. If the player is
    -- already burning, the running effect is extended to at least this many seconds.
    -- 龙卷释放时施加的燃烧状态秒数（0-60）。0 = 关闭。已经处于燃烧状态时会把剩余时间延长到
    -- 至少这个秒数。
    TornadoBurnSeconds = 15,

    -- Interrupt the nearest enemy once the break meter fills (false = off). A full meter plays the
    -- game's own Break attack source on the enemy's HitreactComponent, so the state, animation and
    -- exit all run natively (about 1.0-1.8 s). Below the threshold the enemy keeps acting.
    -- 拼刀蓄满架势后是否打断最近的敌人（false = 关闭）。满阈值时用游戏自己的 Break 攻击源走
    -- HitreactComponent，状态、动画和退出都是原生流程（约 1.0-1.8 秒自然恢复）。
    -- 未满阈值时敌人继续行动。
    BreakOnClash = true,

    -- Clashes needed to fill the break meter (1-10). 1 = every clash. The meter of one enemy
    -- resets after 30 seconds without a clash. When it fills, the native Break hit reaction is
    -- played; if the enemy is inside an unbashable window it is retried twice (150/400 ms).
    -- 蓄满打断架势需要的拼刀次数（1-10）。1 = 每次拼刀；同一敌人 30 秒没拼刀会清空架势。
    -- 满阈值时施加原生 Break 受击；如果敌人正处于不可打断窗口，会补试两次（150/400 毫秒）。
    BreakThreshold = 3,

    -- Seconds to hold the break reaction (0-3). The player's next hit replaces Break with a plain
    -- hit reaction within a few frames; while this window runs, the Break source is replayed
    -- whenever the enemy has dropped out of the Break state. 0 = single application only.
    -- 破防后维持原生受击的秒数（0-3）。玩家下一刀会在几帧内把 Break 覆盖成普通受击；
    -- 窗口内一旦敌人离开 Break 状态就重放一次 Break 源。0 = 只施加一次。
    BreakHoldSeconds = 1.2,

    -- Write clash, free-attack, cost and fire lines to UE4SS.log.
    -- 把拼刀、免耗、消耗和火焰时长写进 UE4SS.log。
    LogEvents = true,

    -- Log each action's damage ("damage hit: ..." per hit, "action damage: ..." per action).
    -- The damage is sampled from the nearest enemy's Health every 0.1 s and credited to the action
    -- that started within the last 1.5 s; burning/environment damage shows up without an action.
    -- 记录每个动作造成的伤害（每一跳 "damage hit: ..."，每个动作汇总 "action damage: ..."）。
    -- 每 0.1 秒采样最近敌人的血量，归给最近 1.5 秒内开始的技能；
    -- 燃烧/环境/其他来源的伤害会显示为没有动作。
    LogDamage = true,
}
