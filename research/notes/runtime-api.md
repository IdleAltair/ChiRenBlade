# Runtime API notes

Verified against Phantom Blade Zero Steam build `26367565` with the custom UE4SS
`v3.0.1-1195-g1ceefac8` (Shipping MSVC, loaded through `platform/steam/dwmapi.dll`).

Addresses and class names below are for this build only.

## Clash and block

- A weapon clash is a consumed deflect frame:
  `DeflectComponent:ConsumeReceivedFrame` (player component, outer `BP_Renewal_Hun_C`).
  The hook fires several times for one clash, so a debounce (0.6 s) is required.
- The block impact hook (`BP_StanceAction_Base_Player_C:On Impact`) could not be registered:
  `no UFunction with the specified name was found`. The mod classifies a block by the last heavy attack age and
  the stance's `In Deflect` flag instead.
- `In Deflect` can be true during a real clash as well, so it is only a fallback.

## Abilities and effects

| Purpose | Object |
| --- | --- |
| ChiRen heavy attacks | `GA_Hun_ChiRen_B`, `BB`, `BBB`, `BD`, `BSup`, `C` |
| ChiRen whirlwind | `GA_Hun_ChiRen_BSup_C` (blade-force Lv3 input) |
| Shachi-cost whirlwind | `GA_Hun_ChiRen_C_C` |
| Fire state | `GE_ChiRen_FireState` (duration normally comes from a SetByCaller tag) |
| Invulnerability | `GE_PBZSpecialMoveInvulnerable_C` |
| Break hit reaction | `BP_DeflectHitreactAttackSource_Break_C` |
| Whirlwind bullets | `BD_GA_Hun_ChiRen_BSup_01`, `BD_GA_Hun_ChiRen_BSup_02` |

The two whirlwind bullets carry `DamageData` fields named
`Damage.Attack.Target.PhysicalDamage` and `Damage.Attack.Target.ElementDamage`.
`AngerDamage` is never touched.

## Break

`HitreactComponent:PlayHitreactToAvatar` with a `BP_DeflectHitreactAttackSource_Break_C` object is the native way to
interrupt an enemy. The state goes to `CharacterState.HitReact.State.Break.Normal` and exits by itself in about
1.0–1.8 s.

- The source object is created with
  `StaticConstructObject(cls, playerPawn, FName("...", EFindName.FNAME_Add))`.
- Set `Source Avatar`, `Is Source Attacker = true`, `Counter = true` on the object.
- `HitreactComponent:ChangeHitState` / `ChangeHitPhase` only freeze the AI; they do not play the exit animation or
  release the AI. Do not use them as the main path.
- A normal hit can replace the Break state before its animation finishes. Replaying the source once or twice
  keeps the reaction visible, but state `None` does not by itself prove that the AI has recovered.

## Lua/UE4SS API behaviour

- `AddLooseGameplayTag`, `RemoveLooseGameplayTag` and `SetLooseGameplayTagCount` are unbound (`TrivialObject`) on
  this build. `GetGameplayTagCount` is readable. Cross-runtime tag signalling is not available through them.
- `UGameplayAbility::IsActive()` is a plain C++ method, not a reflected UFunction. Calling it from Lua returns a
  `TrivialObject`. The reflected `bIsActive` property is readable.
- A `FName` returned by `UObject["SomeName"]` is a userdata whose `tostring` prints the temporary wrapper address
  (for example `FNameUserdata: 0000001...`), and that address changes on every read. Never use it as a change
  signal.
- `RegisterHook` fails for some Blueprint classes/functions with
  `no UFunction with the specified name was found`, for example `GA_Hun_ChiRen_SWT_C:K2_ActivateAbility`.
  `AnimInstance:Montage_Play` registers successfully but was never observed firing in this build.
- `StaticFindObject` does not load assets. Call `LoadAsset(path)` first when the class may still be lazy-loaded.
- Properties with spaces are indexed as strings: `self["Shachi Cost"]`, `self["Shachi Cost Min"]`.
- The main Lua chunk is limited to 200 active locals. Above that the whole mod fails to load with
  `too many local variables (limit is 200)`. Wrap self-contained sections in `do ... end`.
- Use `ExecuteInGameThread` inside `ExecuteWithDelay` callbacks; use `LoopInGameThreadWithDelay` for periodic work,
  not `LoopAsync`, so UObject property access stays on the game thread.
- `GE_ChiRen_FireState` ignores the duration passed by `BP_ApplyGameplayEffectToSelf`; switch its CDO
  `DurationMagnitude` to a fixed value for one apply and restore it immediately.

## Logs

The Lua log is `<game>\platform\steam\ue4ss\UE4SS.log`. It is overwritten on every launch; copy it before the next
run if a crash needs to be analysed.
