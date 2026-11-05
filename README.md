# ChiRen Blade

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
  game does not read the ability's `Shachi Cost` fields nor the `HeavyAttack_ShachiCostReduction` attribute (both
  were written and changed nothing), so the mod watches the Shachi bar for about a second after each non-free heavy
  attack and refunds the part the scale removes. The log line is `refund ... spent ... kept ...`.
- **Independent switches.** The refund, the fire and the cost scale are separate: set `FireEnabled = false` and the
  free heavy attacks still work.
- **Optional block-parry window.** `DeflectWindowFrames` (off by default) raises the perfect window of the block
  parry, the game setting `Deflect Perfect Window Frames` (6 frames at 30 fps, 0.2 s). This is not the weapon
  clash: a clash's frames are part of each attack asset and have no global setting.

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
| `DeflectWindowFrames` | `0` | 0-60 | Perfect window of the **block parry**, in frames at 30 fps (game value 6). Not the weapon clash, which has no global window setting. Written to every difficulty. `0` = no change. |
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

## Break research (parked)

A clash-break/stagger feature (interrupting the attacker through the hit reaction state machine) was developed
up to a working state switch and then removed in 0.30. The measurements, API signatures and the remaining ideas
are kept in [notes/break-research.md](notes/break-research.md).

## Deploy and pack

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1      # copy into the game's ue4ss\Mods
powershell -ExecutionPolicy Bypass -File .\pack.ps1        # dist\ChiRenBlade-<version>.zip
```

`deploy.ps1` keeps an existing `Scripts\config.lua` in the game; `-ResetConfig` overwrites it with the shipped
one.

## Credits

Written by Altair with DeepSeek-V4.1-Flash-1017 in Qoder.

## License

MIT
