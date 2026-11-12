# ChiRen Blade

[English](#chiren-blade) | [中文指南](#中文指南)

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for Phantom Blade Zero (Unreal Engine 5.7).

After a successful clash with the ChiRen blade the next heavy attacks cost no Shachi, the blade burns and the
player gets a short invulnerability. Clashes also build a streak: the ChiRen whirlwind (风回云卷) deals 3–6× damage
based on that streak, and a full three-clash meter interrupts the enemy with the game's own Break hit reaction.
Independently, every heavy attack costs half the usual Shachi.

Made with game build `26367565` (Steam) and UE4SS `v3.0.1-1195-g1ceefac8` (the custom build for this game).

## What it does

- **Free heavy attacks after a clash.** The player's deflect component (`DeflectComponent:ConsumeReceivedFrame`)
  is the trigger. After a clash, the next `Charges` heavy attacks (the Y-button Shachi attacks, `GA_Hun_ChiRen_B*`)
  cost no Shachi. The cost is written to `0` on the ability instance right before it activates, so nothing is
  patched permanently. All heavy segments are covered, including the first (B) and third (BBB), whose activation
  comes from their shared base ability.
- **Fire on the blade.** The clash applies the weapon's own `GE_ChiRen_FireState` for `FireSeconds`. The original
  blade-energy fire is a separate effect instance and is not changed. If a hit clears the fire, it is reapplied
  within the same `FireSeconds` window (rate-limited to once per second).
- **Short invulnerability.** Each clash applies the game's own `GE_PBZSpecialMoveInvulnerable_C` for
  `InvulnSeconds` (1.2 s). The optional health guard (`HealthGuard`, off by default) writes the player's health
  back every 16 ms during the window as a fallback; with the game effect alone the window is already invulnerable.
- **Whirlwind damage.** Every `GA_Hun_ChiRen_BSup_C` cast patches the two attack bullets' `PhysicalDamage` and
  `ElementDamage` while the move runs and restores them afterwards. The multiplier is
  `max(TornadoClashMin, min(streak, TornadoClashMax)) × TornadoDamageScale`: 3–6× by default, with at most six
  stored clashes. The second cast of a double cast reuses the first cast's multiplier for 4 seconds. Every cast
  also gets 2.5 s of invulnerability and starts or extends a 15 s fire.
- **Three-clash interrupt.** Every non-block clash adds one point to that enemy's break meter. At `BreakThreshold`
  (3) the mod plays the game's own `BP_DeflectHitreactAttackSource_Break_C` on the enemy's hitreact component, so
  the hit reaction, animation and exit all run natively (about 1.0–1.8 s). `BreakHoldSeconds` keeps the target in
  the reaction if a normal hit knocks it out early (at most two replays).
- **Permanent half cost.** `HeavyCostScale` (0.5 by default) halves the Shachi every ChiRen heavy attack costs. The
  game does not read the ability's `Shachi Cost` fields nor the `HeavyAttack_ShachiCostReduction` attribute, so the
  mod watches the Shachi bar for about a second after each non-free heavy attack and refunds the part the scale
  removes.
- **Optional block-parry window.** `DeflectWindowFrames` (off by default) raises the perfect window of the block
  parry, the game setting `Deflect Perfect Window Frames` (6 frames at 30 fps, 0.2 s). This is not the weapon
  clash's window.
- **Optional clash window.** `ClashWindowFrames` (off by default) widens the weapon clash window of the
  heavy -> light counter (`GA_Hun_Long_Counter_C`) for the ChiRen blade. The clash has no global field: the
  mod writes the duration of the counter's single `GAA_DeflectFrame_C` row before the native timeline
  autoplay starts. Vanilla is 0.350606441 s (about 10.5 frames at 30 fps); other long blades are left alone.
- **Damage log.** With `LogDamage = true` the mod samples the nearest enemy's health and writes `damage hit` /
  `action damage` lines, plus a low-frequency `damage watch` line with the target and its current HP.

## Install

1. Install the custom UE4SS build for Phantom Blade Zero into `<game>\platform\steam\`
   (`dwmapi.dll` and the `ue4ss\` folder; see the [PBZ modding resources](https://github.com/KintaroModding)).
   The stock UE4SS does not work with this game.
2. Copy the `ChiRenBlade` folder into `<game>\platform\steam\ue4ss\Mods\`.
3. Start the game. The mod writes its log to `<game>\platform\steam\ue4ss\UE4SS.log`; the first line is
   `[ChiRenBlade] 0.90 loaded`.

The folder holds `enabled.txt`, so UE4SS starts the mod without an entry in `mods.txt`.

## Configuration

Edit `ChiRenBlade\Scripts\config.lua`. The file is independent of `main.lua`, so it survives mod updates: a setting
that is missing, has the wrong type, or is outside its range keeps the built-in default, and the log says so.
Restart the game after a change.

| Setting | Default | Range | Meaning |
| --- | --- | --- | --- |
| `Charges` | `6` | 0-20 | Heavy attacks that cost no Shachi after a clash. |
| `FireEnabled` | `true` | - | Apply the fire effect after a clash. |
| `FireSeconds` | `5` | 0.5-30 | Duration of the mod's fire. |
| `CooldownSeconds` | `0.6` | 0-2 | Debounce between two clash triggers, in seconds. |
| `TriggerOnDeflect` | `true` | - | Use the deflect component as the clash trigger. |
| `HeavyCostScale` | `0.5` | 0.05-1.0 | Permanent heavy-attack cost scale (`1.0` = off), implemented as a refund after the charge. |
| `DeflectWindowFrames` | `0` | 0-60 | Perfect window of the **block parry** in frames at 30 fps (game value 6). Not the weapon clash. `0` = no change. |
| `ClashWindowFrames` | `0` | 0-60 | Weapon **clash** window of the heavy -> light counter, in frames at 30 fps (vanilla 0.350606441 s, about 10.5). ChiRen only. `0` = no change. |
| `InvulnSeconds` | `1.2` | 0-5 | Game invulnerability applied after a clash. `0` = off. |
| `HealthGuard` | `false` | - | 16 ms health write-back during the invulnerability window. Fallback only; leave off unless the game effect lets damage through. |
| `TornadoInvulnSeconds` | `2.5` | 0-5 | Invulnerability applied by a whirlwind cast. |
| `TornadoClashMin` | `3` | 1-6 | Lower end of the whirlwind damage multiplier. |
| `TornadoClashMax` | `6` | 3-10 | Highest stored clash streak; also the upper end of the multiplier. |
| `TornadoDamageScale` | `1.0` | 1.0-3.0 | Extra multiplier on top of the streak. |
| `TornadoDamageSeconds` | `4.0` | 1.0-8.0 | Safety restore time for the patched bullet damage. |
| `TornadoBurnSeconds` | `15` | 0-60 | Fire duration started or extended by a whirlwind cast. |
| `BreakOnClash` | `true` | - | Enable the three-clash interrupt. |
| `BreakThreshold` | `3` | 1-10 | Clashes needed to fill the break meter. |
| `BreakHoldSeconds` | `1.2` | 0-3 | Keep the target in the Break reaction for this long; `0` = no replays. |
| `LogEvents` | `true` | - | Write clash, free-attack, cost and fire lines to `UE4SS.log`. |
| `LogDamage` | `true` | - | Write damage lines and sample the enemy's health. |

A value outside its range keeps the default, and the log names the setting.

Example `config.lua`:

```lua
return {
    Charges = 6,
    FireEnabled = true,
    FireSeconds = 5,
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    HeavyCostScale = 0.5,
    DeflectWindowFrames = 0,
    ClashWindowFrames = 0,
    InvulnSeconds = 1.2,
    HealthGuard = false,
    TornadoInvulnSeconds = 2.5,
    TornadoClashMin = 3,
    TornadoClashMax = 6,
    TornadoDamageScale = 1.0,
    TornadoDamageSeconds = 4.0,
    TornadoBurnSeconds = 15,
    BreakOnClash = true,
    BreakThreshold = 3,
    BreakHoldSeconds = 1.2,
    LogEvents = true,
    LogDamage = true,
}
```

## How it works

- **Clash trigger:** a pre-hook on `DeflectComponent:ConsumeReceivedFrame`, filtered to the player's pawn
  (`BP_Renewal_Hun`). `CooldownSeconds` debounces the many frames a single clash produces. A block impact within
  0.5 s is classified as a block and does not build the break meter.
- **Free heavy attacks:** pre-hooks on `K2_ActivateAbility` of `GA_Hun_ChiRen_B`, `BB`, `BBB`, `BD`, `BSup`, `C`.
  While charges remain, `Shachi Cost` and `Shachi Cost Min` on the instance are set to `0`.
- **Fire duration:** `GE_ChiRen_FireState` takes its duration from a SetByCaller tag that
  `BP_ApplyGameplayEffectToSelf` cannot supply. The mod switches the effect CDO's `DurationMagnitude` to a fixed
  value for the one apply and restores it immediately.
- **Invulnerability:** `GE_PBZSpecialMoveInvulnerable_C` is applied for the window and removed explicitly so an
  infinite effect cannot stay on the player.
- **Whirlwind damage:** the two `BD_GA_Hun_ChiRen_BSup_01/02` bullets' `Damage.Attack.Target.PhysicalDamage` and
  `ElementDamage` are scaled, then restored at cast end (or after `TornadoDamageSeconds`). `AngerDamage` is not
  touched.
- **Break:** `StaticConstructObject` creates the game's `BP_DeflectHitreactAttackSource_Break_C`, and
  `HitreactComponent:PlayHitreactToAvatar` plays it on the nearest enemy. The exit is the game's own.
- **Cost scale:** after each non-free heavy attack the mod samples `Shachi` at 60/150/400 ms and writes back the
  part `HeavyCostScale` keeps.
- **Loops:** UE4SS delayed action loops on the game thread (`LoopInGameThreadWithDelay`), 1.5 s for hook setup and
  300 ms for sampling.

## Log lines

```
[ChiRenBlade] 0.90 loaded
[ChiRenBlade] hooked ConsumeReceivedFrame
[ChiRenBlade] clash skipped (block): deflect frame consumed
[ChiRenBlade] clash (deflect frame consumed): 6 free heavy attacks
[ChiRenBlade] fire: applied, asked 5.0 s
[ChiRenBlade] fire: cleared by a hit, reapplied 4.2 s
[ChiRenBlade] invuln: applied 1.2 s
[ChiRenBlade] free heavy: GA_Hun_ChiRen_BB_C (5 left)
[ChiRenBlade] tornado combo: 4/6
[ChiRenBlade] tornado cast: streak=4 tier=3 multiplier=x4.00 free=true
[ChiRenBlade] tornado damage: BD_GA_Hun_ChiRen_BSup_02 Damage.Attack.Target.PhysicalDamage 1.04 -> 4.18
[ChiRenBlade] damage hit: 2410 GA_Hun_ChiRen_BSup_C x4.00 on BP_Monster_YuBi_C
[ChiRenBlade] break meter full: ... (3/3); playing the native Break hitreact
[ChiRenBlade] break source clash: ok=true state None -> CharacterState.HitReact.State.Break.Normal
[ChiRenBlade] heavy cost +150ms: 384 -> 384 (delta 0) consumed=nil
[ChiRenBlade] refund +400ms: spent 26, kept 13, wrote 198 ok=true
[ChiRenBlade] damage watch: BP_Monster_YuBi_C hp=139000
```

## Notes

- The mod only affects the ChiRen blade; other weapons are untouched. The clash trigger does not check the weapon,
  so a clash with another weapon fills the charge count and the break meter; those charges are spent on the next
  ChiRen heavy attack.
- The fire is an extra effect instance on top of the game's own fire. Both run and expire independently.
- The clash trigger is the deflect component, not the parry ability. A block consumes a deflect frame but does not
  grant any reward: no free attacks, no fire, no invulnerability, and no break meter.
- The refund is a post-charge correction: the bar drops first, then the kept part is written back within about a
  second. It is not an instantaneous discount.
- The whirlwind multiplier only applies to the two BSup bullets. The Shachi-cost whirlwind variant `C` keeps its
  vanilla damage but still gets the 2.5 s invulnerability.
- The three-clash interrupt uses the game's native Break reaction. Below the threshold the enemy keeps acting.

## Game data and research

The `research/` folder contains the mapping file, the readable property schema, the scripts used to generate it,
and notes from runtime probing. See [research/README.md](research/README.md). These files are for mod authors who
want to build on the same data; they are not needed to play.

## Deploy and pack

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1      # copy into the game's ue4ss\Mods
powershell -ExecutionPolicy Bypass -File .\pack.ps1        # dist\ChiRenBlade-<version>.zip
```

`deploy.ps1` keeps an existing `Scripts\config.lua` in the game; `-ResetConfig` overwrites it with the shipped
one.

## Credits

Written by Altair, with DeepSeek-V4.1-Flash-1017 (Qoder model selector), Gemini (Argon) and Kimi (K3.1 Pro) as
collaborators.

## License

[MIT](LICENSE)

## 中文指南

炽刃专用的 UE4SS Lua mod，适用于《影之刃零》（UE 5.7）。核心是拼刀后的奖励链：免杀气重攻击、刀上火、短暂
无敌；拼刀还累积层数，风回云卷按层数造成 3–6 倍伤害，满 3 次拼刀用游戏原生 Break 受击打断敌人；此外每次
重攻击的杀气消耗减半。

游戏版本 `26367565`（Steam），配套的定制 UE4SS `v3.0.1-1195-g1ceefac8`。

### 功能

- **拼刀后免杀气。** 玩家的弹刀组件 `DeflectComponent:ConsumeReceivedFrame` 被消费时算一次拼刀。之后
  接下来 `Charges` 次重攻击（Y 键的 B 系：`GA_Hun_ChiRen_B / BB / BBB / BD / BSup / C`）不消耗杀气。
  做法是在技能激活前把实例上的 `Shachi Cost` 和 `Shachi Cost Min` 写成 0，不永久改资产。第一段 B 和
  第三段 BBB 通过它们的公共父类一起覆盖。
- **刀上火。** 拼刀同时施加武器自己的 `GE_ChiRen_FireState`，持续 `FireSeconds` 秒。原版攒满刀劲的
  15 秒火焰是另一个独立实例，两者不会互相刷新或缩短。火被受击或临时效果清掉时，会在同一个
  `FireSeconds` 窗口内自动补火（每秒最多一次）。
- **短暂无敌。** 每次拼刀施加游戏自己的 `GE_PBZSpecialMoveInvulnerable_C`，持续 `InvulnSeconds`（1.2 秒）。
  `HealthGuard` 默认关闭；打开后会在无敌窗口内每 16ms 把血量写回起始值，作为游戏效果之外的兜底。
- **风回云卷增伤。** 每次 `GA_Hun_ChiRen_BSup_C` 释放时临时改两颗子弹的 `PhysicalDamage` 和 `ElementDamage`，
  结束自动还原。倍率 = `max(TornadoClashMin, min(拼刀层数, TornadoClashMax)) × TornadoDamageScale`，
  默认 3–6 倍，最多存 6 次拼刀；双发的第二发在 4 秒内沿用第一发倍率。每次释放还有 2.5 秒无敌，并施加或
  延长 15 秒火焰。
- **3 次拼刀打断。** 每次非格挡拼刀给该敌人加一层架势，满 `BreakThreshold`（3）时用游戏自己的
  `BP_DeflectHitreactAttackSource_Break_C` 走 `HitreactComponent:PlayHitreactToAvatar`，受击、动画和退出
  都是原生流程（约 1.0–1.8 秒）。`BreakHoldSeconds` 会在普通受击提前顶掉时补一次（最多重放两次）。
- **永久杀气减半。** `HeavyCostScale` 默认 0.5。游戏不读技能自带的 Cost 字段，也不读
  `HeavyAttack_ShachiCostReduction` 属性，所以做法是「先扣后退」：每次非免耗重攻击激活后盯杀气条约一秒，
  检测到下降就把倍率之外的部分写回去。
- **可选格挡弹反窗口。** `DeflectWindowFrames` 默认 0（不改）。设成非 0 时，把全部难度配置的
  `Deflect Perfect Window Frames` 改成该值。注意这是**格挡弹反**的窗口，不是拼刀窗口。
- **可选拼刀窗口。** `ClashWindowFrames` 默认 0（不改）。设成非 0 时，把「重击接轻击」派生拼刀
  （`GA_Hun_Long_Counter_C`）里那条独立判定行 `GAA_DeflectFrame_C` 的时长改成该帧数（30fps 基准）。
  原版 0.350606441 秒 ≈ 10.5 帧；只对炽刃生效，其他长兵保持原版。
- **伤害日志。** `LogDamage = true` 时会采样最近敌人的血量，写 `damage hit` / `action damage`，并每 3 秒写
  一条 `damage watch` 显示当前目标和血量。

### 安装

1. 先把影之刃零专用的定制 UE4SS 装进 `<游戏目录>\platform\steam\`
   （`dwmapi.dll` 和 `ue4ss\` 文件夹；来源见 [PBZ modding resources](https://github.com/KintaroModding)）。
   原版 UE4SS 不适用于这个游戏。
2. 把 `ChiRenBlade` 文件夹放进 `<游戏目录>\platform\steam\ue4ss\Mods\`。
3. 启动游戏。日志写在 `<游戏目录>\platform\steam\ue4ss\UE4SS.log`，第一行应为
   `[ChiRenBlade] 0.90 loaded`。

文件夹里带有 `enabled.txt`，不需要在 `mods.txt` 里登记。

更详细的小白安装教程（含常见问题）见 [docs/安装教程.md](docs/安装教程.md)。

### 配置

编辑 `ChiRenBlade\Scripts\config.lua`，改完保存并**重启游戏**。这个文件和 `main.lua` 分开，mod 升级不会
覆盖你的设置；缺失项、类型错误或超出范围会用回默认值，并在日志里点名。

| 参数 | 默认 | 范围 | 作用 |
| --- | --- | --- | --- |
| `Charges` | `6` | 0-20 | 拼刀后多少次重攻击免杀气。按技能**激活**计数，不是命中；`0` = 关闭免耗（火焰不受影响）。 |
| `FireEnabled` | `true` | - | 拼刀后是否给刀上火。 |
| `FireSeconds` | `5` | 0.5-30 | mod 施加的火焰持续几秒。 |
| `CooldownSeconds` | `0.6` | 0-2 | 一次拼刀会连续触发很多帧，这个窗口用来去重。 |
| `TriggerOnDeflect` | `true` | - | 用玩家的弹刀组件作为拼刀触发点。 |
| `HeavyCostScale` | `0.5` | 0.05-1.0 | 重攻击杀气的永久倍率。`1.0` = 关闭；实现是扣后回补。 |
| `DeflectWindowFrames` | `0` | 0-60 | **格挡弹反**的完美窗口帧数（30 fps），游戏原值 6。`0` = 不改。 |
| `ClashWindowFrames` | `0` | 0-60 | **拼刀**（重击接轻击派生）的判定窗口帧数（30fps），原版 0.350606441 秒 ≈ 10.5 帧。只对炽刃生效。`0` = 不改。 |
| `InvulnSeconds` | `1.2` | 0-5 | 拼刀后的游戏无敌秒数。`0` = 关闭。 |
| `HealthGuard` | `false` | - | 无敌窗口内每 16ms 写回血量。只在游戏无敌漏伤害时才需要打开。 |
| `TornadoInvulnSeconds` | `2.5` | 0-5 | 风回云卷释放时的无敌秒数。 |
| `TornadoClashMin` | `3` | 1-6 | 龙卷倍率的下限。 |
| `TornadoClashMax` | `6` | 3-10 | 最多存储的拼刀层数，也是倍率上限。 |
| `TornadoDamageScale` | `1.0` | 1.0-3.0 | 在层数之外再乘的倍率。 |
| `TornadoDamageSeconds` | `4.0` | 1.0-8.0 | 子弹伤害替换的兜底还原时间。 |
| `TornadoBurnSeconds` | `15` | 0-60 | 龙卷释放施加/延长的火焰秒数。 |
| `BreakOnClash` | `true` | - | 是否启用 3 次拼刀打断。 |
| `BreakThreshold` | `3` | 1-10 | 蓄满打断架势需要的拼刀次数。 |
| `BreakHoldSeconds` | `1.2` | 0-3 | 维持 Break 受击的秒数；`0` = 不重放。 |
| `LogEvents` | `true` | - | 是否把拼刀、免耗、杀气消耗和火焰时长写进 `UE4SS.log`。 |
| `LogDamage` | `true` | - | 是否写伤害日志并采样敌人血量。 |

范围外的值会保留默认值，日志会说明是哪一项。

### 日志示例

```
[ChiRenBlade] 0.90 loaded
[ChiRenBlade] clash skipped (block): deflect frame consumed
[ChiRenBlade] clash (deflect frame consumed): 6 free heavy attacks
[ChiRenBlade] invuln: applied 1.2 s
[ChiRenBlade] fire: cleared by a hit, reapplied 4.2 s
[ChiRenBlade] tornado combo: 4/6
[ChiRenBlade] tornado cast: streak=4 tier=3 multiplier=x4.00 free=true
[ChiRenBlade] damage hit: 2410 GA_Hun_ChiRen_BSup_C x4.00 on BP_Monster_YuBi_C
[ChiRenBlade] break meter full: ... (3/3); playing the native Break hitreact
[ChiRenBlade] damage watch: BP_Monster_YuBi_C hp=139000
```

### 说明与限制

- mod 只改炽刃；其他武器的伤害和动作不变。拼刀触发不检查武器，所以用其他武器拼刀也会攒免耗次数和打断架势，
  免耗次数会在下一次炽刃重攻击时用掉。
- 火焰是额外的一层效果，与原版刀劲火各自计时、互不刷新。
- 拼刀触发是弹刀组件的判定，不是格挡弹反技能。格挡也会消费弹刀帧，但不发任何奖励：不免耗、不点火、
  不给无敌、也不攒打断架势。
- 杀气减半是扣后回补，杀气条会先掉再回，不是瞬时折扣。
- 龙卷倍率只作用于两颗 BSup 子弹；耗杀气的 `C` 变体保持原版伤害，但同样有 2.5 秒无敌。
- 打断用的是游戏原生 Break 受击，未满阈值时敌人继续正常行动。

### 游戏资料与研究

`research/` 目录放了映射文件、可读的属性表、生成脚本和运行时探测笔记，见
[research/README.md](research/README.md)。这些是给继续改 mod 的人用的，普通游玩不需要。

### 部署与打包（开发者）

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1      # 复制到游戏的 ue4ss\Mods
powershell -ExecutionPolicy Bypass -File .\pack.ps1        # 生成 dist\ChiRenBlade-<version>.zip
```

`deploy.ps1` 会保留游戏里已有的 `Scripts\config.lua`；加 `-ResetConfig` 则用发布的版本覆盖。
