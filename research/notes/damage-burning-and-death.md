# Damage, burning and boss death

Lessons from making the ChiRen weapon-switch GP fire tornado deal damage, burn, and kill correctly.
Verified against Steam build `26367565` with the custom UE4SS `v3.0.1-1195-g1ceefac8`. Anything still
marked *pending* is a hypothesis being probed, not a confirmed fact.

The short version: **writing an attribute is not the same as dealing damage.** The game's damage
pipeline does three things a raw write does not — refresh the health bar, run the death/phase logic,
and play the hit/burn visuals. Bypassing it produces "the boss takes no damage" reports that are
really display bugs, and "the boss will not die" bugs that are really broken death flow.

## 1. Direct attribute writes lower health but freeze the bar

`FGameplayAttributeData.CurrentValue` is recomputed by the GAS aggregator from `BaseValue`, so a
lasting change has to write **both**:

```lua
hdata.BaseValue    = math.max(1, baseVal - damage)
hdata.CurrentValue = math.max(1, hp - damage)
```

The write sticks. Reading the target back at 0.5 s and 2.5 s shows `cur == base` with no restore
(e.g. BiYuan `26572 -> 22172`, a full 4400 applied, stable at both delays). **Yet the boss health bar
does not move.** A raw struct write never fires the attribute-change delegate the bar widget listens
to, so the number drops while the UI stays put.

This is the root of "the tornado deals no damage (or I cannot see it on the boss bar)". The damage is
real; the display is not. Tell the three cases apart by reading `CurrentValue` and `BaseValue`
separately at a delay:

| Observation | Meaning |
| --- | --- |
| `cur` snaps back, `base` stays | aggregator restored CurrentValue (write BaseValue too) |
| both restore | a resetting effect is active on the attribute |
| both stay, bar frozen | write stuck, UI delegate never fired (this case) |

A native damage GameplayEffect fires the delegate, so the bar updates. Routing damage through a GE
(see §3) is the clean fix; driving the bar widget manually (see §5) is the additive fallback that
leaves a working write untouched.

## 2. Never write 0 HP or force-kill a boss

Bosses die through their own phase/death event, not the generic `GE_Kill` used on trash mobs.
Writing `Health = 0` and/or applying `GE_Kill` interrupts that native flow: the boss sits at 0 HP
"downed" but never truly dies, and **afterwards even normal attacks cannot kill it**. The encounter is
stuck until the save is reloaded.

Fix: cap every tick so health never reaches 0, and let the game land the killing blow itself.

```lua
-- Cap at 1 HP, never 0: writing 0 (or force-killing) skips the boss's native death/phase
-- event and leaves it stuck at 0 HP, unkillable even by normal attacks.
hdata.BaseValue    = math.max(1, baseVal - damage)
hdata.CurrentValue = math.max(1, hp - damage)
```

Do not apply `GE_Kill` from the mod at all. A boss already stuck at 0 HP from an older build needs a
reload; the cap only prevents it happening again.

## 3. How the game actually deals damage

A move's hits come from **BulletData** assets (its timeline's bullet rows). Each bullet data has a
`DamageData` map keyed by damage tag — a per-bullet factor on the attacker's attack values:

| Tag | Pool |
| --- | --- |
| `Damage.Attack.Target.PhysicalDamage` | health |
| `Damage.Attack.Target.ElementDamage` | element |
| `Damage.Attack.Target.AngerDamage` | sha-chi |

On hit the game reads the map and runs the native damage pipeline: bar refresh, death/phase logic,
hit/burn VFX. Scaling a move's damage means writing these factors right before the cast and restoring
them after (the assets are shared with the enemy that owns the move).

**These tag names are BulletData `DamageData` keys, not GameplayEffect SetByCaller magnitude names.**
Do not pass them to `AssignSetByCallerMagnitude`.

To apply a native damage GE with a custom magnitude, the reflected spec path exists:

```
ASC:MakeOutgoingSpec(geClass, level, context)            -> SpecHandle
lib:AssignSetByCallerMagnitude(spec, dataName, value)    -- or AssignTagSetByCallerMagnitude
ASC:BP_ApplyGameplayEffectSpecToTarget(spec, targetASC)
```

(`lib` = `/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary`.) The magnitude name must
be read from the GE's CDO `Modifiers` — each `FGameplayModifierInfo` has `Attribute`, `ModifierOp` and
`ModifierMagnitude` (`MagnitudeCalculationType`, `SetByCallerMagnitude.DataName/DataTag`,
`ScalableFloatMagnitude.Value`). *Pending: reading GE_Ignite_Dot's modifiers to confirm its damage
magnitude name and type.*

## 4. Burning is two effects, and the visual lives in the context

The native fire blade ignites an enemy with **two** GameplayEffects, confirmed by hooking
`/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectToSelf` and watching enemy
applies during a fire-blade hit:

| Effect | Role | Path |
| --- | --- | --- |
| `GE_Ignite` | burning state, carries the visual | `/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Ignite.GE_Ignite_C` |
| `GE_Ignite_Dot` | damage-over-time tick | `.../GE_Ignite_Dot.GE_Ignite_Dot_C` |

Applying the same two GEs from a mod with an empty `asc:MakeEffectContext()` burns (the DoT lands) but
shows **no fire visual**. The GE choice is correct; the difference is the **EffectContext**. The native
attack context carries the weapon (`EffectCauser`) and a `HitResult`, which the burning GameplayCue
uses to attach; an instigator-only context does not trigger it. *Pending: a probe dumps the native
fire-blade context (`EffectContextGetEffectCauser` / `GetInstigatorActor` / `HasHitResult` /
`GetSourceObject`) and GE_Ignite's `GameplayCues` to confirm which field the cue needs.*

The context handle can be enriched with `EffectContextAddHitResult`, `EffectContextSetOrigin`, and
`CloneSpecHandle(newInstigator, newCauser, spec)`.

Do not confuse the enemy burn with `GE_ChiRen_FireState`: that is the **player's** blade-fire state
(`CharacterState.AbilityState.ChiRen.Burning` tag), applied to the player's own ASC. It is not the
enemy DoT.

### Overriding a shared GE duration

To limit a burn to N seconds, switch the CDO `DurationMagnitude` to a fixed `ScalableFloat`
(`MagnitudeCalculationType = 0`) for one apply, then restore it immediately, with read-back
verification both before and after (the official `ChirenFireEffect` pattern). Guard the whole path
with a "duration overrides broken" flag so a failed restore stops further overrides — these assets are
shared with the native fire blade.

## 5. Health bar widgets

| Bar | Class | Notes |
| --- | --- | --- |
| Player | `WB_PlayerHPBar_C`, `WB_PlayerHPBar_V1_C` | progress component `AnimHPBar_1` (`PBZAnimProgressBar2_C`) |
| Boss | `WB_BossHPBar_C` | *pending: progress component + mapping* |
| Enemy | `WB_EnemyHPBar_C` | |

The player bar is driven by `AnimHPBar_1:UpdateBar(shown, shown)` with the display mapping
`(ratio - 0.01) / 0.99 * 0.88 + 0.12`. `PBZAnimProgressBar2.SetShowUpRatio` resets its fill to 1 when
`Max` changes, so refresh only after that native event or a new HUD. Driving the boss bar the same way
after a raw attribute write is the additive fix for §1; it never writes Health, Max, damage or save
data.

## 6. Verification habits that caught these

- A successful property write is **not** proof the effect took hold. Read the target back at delays
  (0.5 s / 2.5 s), `CurrentValue` and `BaseValue` separately.
- Hook callbacks receive the UFunction parameters: the `BP_ApplyGameplayEffectToSelf` hook gets
  `(context, geClass, level, effectContext)`. Static library getters are reached through the `Default__`
  CDO, not the class object.
- `FindAllOf` is a heavy query; throttle it (the damage scan refreshes direction every 250 ms, not every
  50 ms move step). `LoadAsset` cannot run before `UGameEngine::Tick` has initialised UE4SS — do it from
  a game-thread tick, never at module load.
- Log the error text on a failed probe, not just `FAILED`; a silent `TrivialObject` return usually means
  the method is not a reflected UFunction on this build.