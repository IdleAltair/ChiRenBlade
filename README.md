# ChiRen Blade

[English](#chiren-blade) | [中文指南](#中文指南)

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for Phantom Blade Zero (Unreal Engine 5.7): after a
successful clash with the ChiRen blade, the next few heavy attacks cost no Shachi and the blade burns;
independently of that, every heavy attack costs half the usual Shachi.

Made with game build `26367565` (Steam) and UE4SS `v3.0.1-1195-g1ceefac8` (the custom build for this game).

## What it does

- **Free heavy attacks after a clash.** The player's deflect component (`DeflectComponent:ConsumeReceivedFrame`)
  is the trigger. After a clash, the next `Charges` heavy attacks (the Y-button Shachi attacks, `GA_Hun_ChiRen_B*`)
  cost no Shachi. The cost is written to `0` on the ability instance right before it activates and restored on the
  next attack, so nothing is patched permanently.
- **Fire on the blade.** The clash also applies the weapon's own `GE_ChiRen_FireState` for `FireSeconds`. The
  original blade-energy mechanic keeps its own 15-second fire; the two are separate effect instances and do not
  shorten each other.
- **Permanent half cost.** `HeavyCostScale` (0.5 by default) halves the Shachi every ChiRen heavy attack costs. The
  game does not read the ability's `Shachi Cost` fields nor the `HeavyAttack_ShachiCostReduction` attribute, so the
  mod watches the Shachi bar for about a second after each non-free heavy attack and refunds the part the scale
  removes. The log line is `refund ... spent ... kept ...`.
- **Independent switches.** The refund, the fire and the cost scale are separate: set `FireEnabled = false` and the
  free heavy attacks still work.
- **Optional block-parry window.** `DeflectWindowFrames` (off by default) raises the perfect window of the block
  parry, the game setting `Deflect Perfect Window Frames` (6 frames at 30 fps, 0.2 s). This is not the weapon
  clash's window.

## Install

1. Install the custom UE4SS build for Phantom Blade Zero into `<game>\platform\steam\`
   (`dwmapi.dll` and the `ue4ss\` folder; see the [PBZ modding resources](https://github.com/KintaroModding)).
   The stock UE4SS does not work with this game.
2. Copy the `ChiRenBlade` folder into `<game>\platform\steam\ue4ss\Mods\`.
3. Start the game. The mod writes its log to `<game>\platform\steam\ue4ss\UE4SS.log`; the first line is
   `[ChiRenBlade] 0.31 loaded`.

The folder holds `enabled.txt`, so UE4SS starts the mod without an entry in `mods.txt`.

## Configuration

Edit `ChiRenBlade\Scripts\config.lua`. The file is independent of `main.lua`, so it survives mod updates: a
setting that is missing, has the wrong type, or is outside its range keeps the built-in default, and the log says
so. Restart the game after a change.

| Setting | Default | Range | Meaning |
| --- | --- | --- | --- |
| `Charges` | `6` | 0-20 | How many heavy attacks cost no Shachi after a clash (`0` turns the refund off). |
| `FireEnabled` | `true` | - | Apply the fire effect after a clash. |
| `FireSeconds` | `5` | 0.5-30 | How long the mod's fire burns. The game's own 15-second fire from full blade energy is not touched. |
| `CooldownSeconds` | `0.6` | 0-2 | Debounce between two clash triggers, in seconds. |
| `TriggerOnDeflect` | `true` | - | Use the deflect component as the clash trigger. |
| `HeavyCostScale` | `0.5` | 0.05-1.0 | Permanent scale for the heavy attack cost (`0.5` = half, `1.0` = off). Implemented as a refund after the charge, because the game ignores the ability's cost fields. |
| `DeflectWindowFrames` | `0` | 0-60 | Perfect window of the **block parry**, in frames at 30 fps (game value 6). Not the weapon clash. Written to every difficulty. `0` = no change. |
| `LogEvents` | `true` | - | Write clash, free-attack, cost and fire lines to `UE4SS.log`. |

A value outside its range keeps the default, and the log names the setting.

Example `config.lua`:

```lua
return {
    Charges = 5,
    FireEnabled = true,
    FireSeconds = 6,
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    HeavyCostScale = 0.5,
    DeflectWindowFrames = 0,
    LogEvents = false,
}
```

## How it works

- **Clash trigger:** a pre-hook on `DeflectComponent:ConsumeReceivedFrame`, filtered to the player's pawn
  (`BP_Renewal_Hun`). `CooldownSeconds` debounces the many frames a single clash produces.
- **Free heavy attacks:** pre-hooks on `K2_ActivateAbility` of the ChiRen heavy abilities
  (`GA_Hun_ChiRen_B`, `BB`, `BBB`, `BD`, `BSup`, `C`). While charges remain, `Shachi Cost` and `Shachi Cost Min`
  on the instance are set to `0` and one charge is spent. With no charges left, the original values (cached on
  the first activation) are written back scaled by `HeavyCostScale`.
- **Fire duration:** `GE_ChiRen_FireState` takes its duration from a SetByCaller tag
  (`SetByCaller.MainWeapon.ChiRen.FireStateDuration`), which `BP_ApplyGameplayEffectToSelf` cannot supply. The mod
  reads the class default object of the effect, switches `DurationMagnitude` to a fixed value for the one apply,
  and restores it immediately. `FireSeconds` is that value.
- **Cost scale:** the ability's own fields and the `HeavyAttack_ShachiCostReduction` attribute are ignored by the
  game's cost calculation. After each non-free heavy attack the mod samples `Shachi` at 80/160/260/400/600/850 ms
  and, whenever it dropped, writes back the part `HeavyCostScale` keeps. A newer activation cancels the watchers
  of the previous one.
- **Deflect window:** `Deflect Perfect Window Frames` lives on the per-difficulty `PDA_GlobalCombatConfig_C` assets.
  When `DeflectWindowFrames` is above `0` the mod writes it to all of them once, and the log prints the old and the
  new value per difficulty.
- **Loops:** UE4SS Delayed Action loops on the game thread (`LoopInGameThreadWithDelay`), 1.5 s for hook setup and
  300 ms for the burning tag sampling.

## Log lines

```
[ChiRenBlade] 0.31 loaded
[ChiRenBlade] hooked ConsumeReceivedFrame
[ChiRenBlade] hooked heavy GA_Hun_ChiRen_BB_C
[ChiRenBlade] clash (deflect frame consumed): 3 free heavy attacks
[ChiRenBlade] fire: applied, asked 5.0 s
[ChiRenBlade] free heavy: GA_Hun_ChiRen_BB_C (2 left)
[ChiRenBlade] heavy cost +60ms: 384 -> 384 (delta 0) consumed=168
[ChiRenBlade] refund +400ms: spent 26, kept 13, wrote 198 ok=true
[ChiRenBlade] fire lasted 5.12 s (asked 5.0)
[ChiRenBlade] burning=0 at ...
```

`delta 0` with a `free heavy` line means the attack cost no Shachi. The `refund` lines are the cost scale at
work: `spent` is what the game charged, `kept` is what the mod lets stay gone.

## Notes

- The mod only affects the ChiRen blade; other weapons are untouched.
- The fire is an extra effect instance on top of the game's own fire. If the blade is already burning from full
  blade energy, both run and expire independently.
- The clash trigger is the deflect component, not the parry ability. Blocks are not required; a clash is.
- The refund is a post-charge correction: the bar drops first, then the kept part is written back within about a
  second. It is not an instantaneous discount.

## Deploy and pack

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1      # copy into the game's ue4ss\Mods
powershell -ExecutionPolicy Bypass -File .\pack.ps1        # dist\ChiRenBlade-<version>.zip
```

`deploy.ps1` keeps an existing `Scripts\config.lua` in the game; `-ResetConfig` overwrites it with the shipped
one.

## 中文指南

炽刃专用的 UE4SS Lua mod，适用于《影之刃零》（UE 5.7）。核心是三条互相独立的改动：拼刀后给几次免杀气
重攻击、给刀上火、以及永久降低重攻击的杀气消耗。另有一个可选的格挡弹反窗口调整，默认关闭。

游戏版本 `26367565`（Steam），配套的定制 UE4SS `v3.0.1-1195-g1ceefac8`。

### 功能

- **拼刀后免杀气。** 玩家的弹刀组件 `DeflectComponent:ConsumeReceivedFrame` 被消费时算一次拼刀。之后
  接下来 `Charges` 次重攻击（Y 键的 B 系：`GA_Hun_ChiRen_B / BB / BBB / BD / BSup / C`）不消耗杀气。
  做法是在技能激活前把实例上的 `Shachi Cost` 和 `Shachi Cost Min` 写成 0，用完后写回原值，不永久改资产。
- **刀上火。** 拼刀同时施加武器自己的 `GE_ChiRen_FireState`，持续 `FireSeconds` 秒。原版攒满刀劲的
  15 秒火焰是另一个独立实例，两者不会互相刷新或缩短。
- **永久杀气减半。** `HeavyCostScale` 默认 0.5。游戏不读技能自带的 Cost 字段，也不读
  `HeavyAttack_ShachiCostReduction` 属性，所以做法是「先扣后退」：每次非免耗重攻击激活后盯杀气条约一秒，
  检测到下降就把倍率之外的部分写回去。日志里的 `refund ... spent ... kept ...` 就是这一步。
- **可选格挡弹反窗口。** `DeflectWindowFrames` 默认 0（不改）。设成非 0 时，把全部 5 份难度配置的
  `Deflect Perfect Window Frames` 改成该值。注意这是**格挡弹反**的窗口，不是拼刀窗口。

### 安装

1. 先把影之刃零专用的定制 UE4SS 装进 `<游戏目录>\platform\steam\`
   （`dwmapi.dll` 和 `ue4ss\` 文件夹；来源见 [PBZ modding resources](https://github.com/KintaroModding)）。
   原版 UE4SS 不适用于这个游戏。
2. 把 `ChiRenBlade` 文件夹放进 `<游戏目录>\platform\steam\ue4ss\Mods\`。
3. 启动游戏。日志写在 `<游戏目录>\platform\steam\ue4ss\UE4SS.log`，第一行应为
   `[ChiRenBlade] 0.31 loaded`。

文件夹里带有 `enabled.txt`，不需要在 `mods.txt` 里登记。

### 配置

编辑 `ChiRenBlade\Scripts\config.lua`，改完保存并**重启游戏**。这个文件和 `main.lua` 分开，mod 升级不会
覆盖你的设置；缺失项、类型错误或超出范围会用回默认值，并在日志里点名。

| 参数 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `Charges` | `6` | 0-20 | 拼刀后多少次重攻击免杀气。按技能**激活**计数，不是命中；一套 B→BB→BBB 按三下算 3 次。`0` = 关闭免耗（火焰不受影响）。 |
| `FireEnabled` | `true` | - | 拼刀后是否给刀上火。 |
| `FireSeconds` | `5` | 0.5-30 | mod 施加的火焰持续几秒。原版攒满刀劲的 15 秒火不受影响。 |
| `CooldownSeconds` | `0.6` | 0-2 | 一次拼刀会连续触发很多帧，这个窗口用来去重。设太大可能吞掉紧挨着的第二次拼刀。 |
| `TriggerOnDeflect` | `true` | - | 用玩家的弹刀组件作为拼刀触发点。关掉后免耗和火都不会触发，一般只用于排查。 |
| `HeavyCostScale` | `0.5` | 0.05-1.0 | 重攻击杀气的永久倍率。`0.5` = 半价，`1.0` = 关闭。实现是扣后回补，所以杀气条会先掉再回。与「正气凌然」（-30%）叠加时约为原价的 35%。 |
| `DeflectWindowFrames` | `0` | 0-60 | **格挡弹反**的完美窗口帧数（30 fps），游戏原值 6 即 0.2 秒。`0` = 不改。会写入全部 5 份难度。不是拼刀窗口。 |
| `LogEvents` | `true` | - | 是否把拼刀、免耗、杀气消耗和火焰时长写进 `UE4SS.log`。 |

范围外的值会保留默认值，日志会说明是哪一项。

### 示例

```lua
return {
    Charges = 6,
    FireEnabled = true,
    FireSeconds = 5,
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    HeavyCostScale = 0.5,
    DeflectWindowFrames = 0,   -- 想加长格挡弹反窗口就改这里，例如 12
    LogEvents = true,
}
```

### 日志示例

```
[ChiRenBlade] 0.31 loaded
[ChiRenBlade] hooked ConsumeReceivedFrame
[ChiRenBlade] hooked heavy GA_Hun_ChiRen_BB_C
[ChiRenBlade] clash (deflect frame consumed): 3 free heavy attacks
[ChiRenBlade] fire: applied, asked 5.0 s
[ChiRenBlade] free heavy: GA_Hun_ChiRen_BB_C (2 left)
[ChiRenBlade] heavy cost +60ms: 384 -> 384 (delta 0) consumed=168
[ChiRenBlade] refund +400ms: spent 26, kept 13, wrote 198 ok=true
[ChiRenBlade] fire lasted 5.12 s (asked 5.0)
```

`delta 0` 且上面有 `free heavy` 行 = 这次攻击没花杀气。`refund` 行是杀气减半在工作：`spent` 是游戏实际
扣掉的，`kept` 是 mod 允许留下的部分。

### 说明与限制

- 只影响炽刃，其他武器不受影响。
- 火焰是额外的一层效果实例。刀本身已经因为刀劲充满在燃烧时，两层各烧各的、各自到期，不会互相覆盖。
- 免耗的计数口径是**技能激活**，不是命中：被打断、状态不允许而没放出来时不扣次数。
- 杀气减半不是即时折扣，而是扣后约一秒内补回；补回过程分几次采样，日志会逐条记录。

### 部署与打包（开发者）

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1      # 复制到游戏的 ue4ss\Mods
powershell -ExecutionPolicy Bypass -File .\pack.ps1        # 生成 dist\ChiRenBlade-<version>.zip
```

`deploy.ps1` 会保留游戏里已有的 `Scripts\config.lua`；加 `-ResetConfig` 则用发布的版本覆盖。

## Credits

Written by Altair with DeepSeek-V4.1-Flash-1017 in Qoder.

## License

MIT
