# Clash break research (parked in 0.30)

The break/stagger feature was removed from the mod in 0.30. This file keeps what was measured so the
work can be resumed without repeating the probes.

## Goal

After a successful clash with the ChiRen blade, interrupt the attacker (a boss mid-combo) and hold it
out of the fight long enough to attack back.

## What the game side looks like (verified in usmap + runtime)

- Poise break effect: `/PBZCombatAsset/Prototypes/GameplayEffects/GE_ActionPoiseBreak.GE_ActionPoiseBreak_C`
  (`GE_TempEffectBase`). Its GE components are only `TargetTagsGameplayEffectComponent` and
  `AssetTagsGameplayEffectComponent`. **It has no `HitStateGameplayEffectComponent`**, so the effect
  itself does not select or play a hit reaction.
- The hit reaction state machine lives on `HitreactComponent` (native, `/Script/SGameCombatSystem`):
  `RuntimeStateData` = `RuntimeHitreactStateData { ExitListener, StateData, StateAnimation }`.
  `StateData` is an object; it is a nullptr whenever the character is not in a reaction.
- State table: `HitreactStatesConfig` =
  `/PBZCombatAsset/Config/HitReact/PBZ_HitStatesConfig`, field `HitStateData`
  (`Map<GameplayTag, HitreactStateData>`), 21 entries. Break related tags:
  - `CharacterState.HitReact.State.Break.Normal`
  - `CharacterState.Hitreact.State.Break.State`
  - `CharacterState.Hitreact.State.PoiseBreak`
- `PDA_GlobalCombatConfig_C` (Nightmare instance) holds `Mob Break Duration = 4.0`,
  `Player Break Duration = 3.0`, `Lie Duration = 1.0`. Writing `Mob Break Duration` changes the state
  duration value but **not** the visible stagger.
- Mob hit reaction assets (`PDA_HitAnim_MobNew_C`, e.g. `Hit_MobMan_Elite`) carry
  `DeflectBreakComboTime = 0.76`, `DeflectBreakCancelTime = 0.86`, `BreakStateEnd* = 0`.
  Raising these to 2.0 was written successfully and had **no noticeable effect**.

## What did not work (each verified in game)

1. Applying `GE_ActionPoiseBreak` to the attacker's ability system (`BP_ApplyGameplayEffectToSelf`).
   The apply succeeds (`applied=true`, valid handle, removable), but the mob's
   `RuntimeStateData.StateData` stays nullptr: no hit reaction is driven.
2. Re-applying the effect on a timer (0.8 s hold). Removing the old instance first
   (`RemoveActiveGameplayEffect(handle, 1)`; a one-argument call throws `UFunction expected 2
   parameters, received 1`) also succeeds, but still no reaction.
3. `MobBreakDuration = 4.0` (the game value anyway), `MobDeflectBreakTime = 2.0`, player hit reaction
   timing caps: all written, no felt change.
4. Writing the player attribute `HeavyAttack_ShachiCostReduction` (see the cost notes) is unrelated to
   break, but was also proven to be ignored by the ability.

## What did work, and its limitation

`HitreactComponent` exposes a direct API (31 class functions). Parameter signatures dumped with
`UFunction:ForEachProperty`:

```
ChangeHitState(NewHitState: struct<GameplayTag>, CustomNewHitStateData: Object, EndStrengthAnimTask: bool) -> bool
PlayHitAnimation(StrengthAnimation: struct, NewHitState: struct, Additive: bool, StateChanged: bool) -> bool
PlayHitreact(AttackSource: Interface, HitComponent: Object, HitBone: Name,
             AttackDirection: struct, HitLocation: struct, HitNormal: struct, SweepDirection: struct)
PlayHitreactToAvatar(AttackSource: Interface, ...)
PlayKnockback(AttackSource: Interface, AttackDirection: struct)
GetCurrentHitState() -> FName (or GameplayTag on some builds)
GetCurrentHitStateData(), GetCurrentExtraFrames(), ChangeHitPhase(), OnStateEnd(),
StopStrengthAnim(), StopLaunch(), CanBreakEndure(), ...
```

`ChangeHitState(tag, nil, true)` with a tag from `HitStateData` **does switch the state**: the log line
`change hit state` printed `now=<tag>` afterwards, and `GetCurrentHitState()` reported
`CharacterState.Hitreact.State.PoiseBreak` while the hold re-applied it every 0.8 s.

Observed result in game: the boss **stops moving** (a valid damage window) but plays **no reaction
animation** — `ChangeHitState` only changes the state, the animation is a separate
`PlayHitAnimation` call with a `StrengthAnimation` payload.

The `bool` return of `ChangeHitState` is not a success signal: it returned `true` while
`GetCurrentHitState()` showed `Normal`, and `false` while the state had in fact changed. Treat
`GetCurrentHitState()` as the signal.

## Code sketch if this is picked up again

The complete working implementation (v0.29) is archived next to this file as
[break-research-v0.29-main.lua](break-research-v0.29-main.lua): hold timer, state-table reading, break
candidate ranking and the per-repeat `ChangeHitState` call. The sketch below is the minimal form.

```lua
-- read the state table (TMap callbacks give RemoteUnrealParam wrappers: unwrap first!)
local config = comp.HitreactStatesConfig
config.HitStateData:ForEach(function(key, value)
    key = key:get()
    value = value:get()
    local tagName = key.TagName:ToString()          -- FName, not GetName()
    local stateClass = value.StateDataClass          -- object class, names the reaction
end)

-- switch state (works, but no animation)
comp:ChangeHitState(poiseBreakTag, nil, true)
```

Next steps that were not tried:

1. Provide the animation: `PlayHitAnimation(StrengthAnimation, NewHitState, Additive, StateChanged)`.
   `StrengthAnimation` is a struct (likely `HitreactStrengthAnimation { Animation: interface,
   Rotate, HitPhaseTimer }`); the animation interface object may be reachable from
   `RuntimeStateData.StateAnimation`.
2. Do it "the game way": drive the mob's poise to zero through `GA_PoisePassive_C`
   (`PoiseValue` map) or `BP_PoiseForceResetPayload_C` (`Poise Name`, `Source Avatar`) so the game
   runs its full break flow, animation included.
3. Check `HitStateGameplayEffectComponent` (`HitState` tag, `EndStrengthAnimTask`, `RemoveOnEnd`):
   a gameplay effect carrying this component should be what normally triggers a reaction; find the
   game's own break GE that carries it and apply that instead of `GE_ActionPoiseBreak`.

## UE4SS gotchas met on the way

- `HitreactComponent` instance: `ForEachFunction` throws `TrivialObject`; use `comp:GetClass():ForEachFunction`.
- `comp:GetClass():GetSuperClass()` also throws `TrivialObject`; the parent chain is not reachable this
  way.
- `ForEachFunction` only lists functions declared on that class, not inherited ones.
- `TMap:ForEach` callback arguments are `RemoteUnrealParam`; call `:get()` before reading fields.
- `FName` has no `GetName()`; use `ToString()`.
- `GetActiveGameplayEffects()` is unavailable on this UE4SS build.
- `RemoveActiveGameplayEffect` requires both the handle and a stack count.
