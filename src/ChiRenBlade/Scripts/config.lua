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

    -- Write clash, free-attack, cost and fire lines to UE4SS.log.
    -- 把拼刀、免耗、消耗和火焰时长写进 UE4SS.log。
    LogEvents = true,
}
