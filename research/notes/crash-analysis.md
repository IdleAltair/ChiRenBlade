# Crash analysis (2026-11-04 to 2026-11-07)

All dumps below are `0xC0000005` access violations on the **GameThread**. The faulting thread was read from the
minidump's `ThreadNamesStream`.

| Time (local) | Faulting module and offset | Notes |
| --- | --- | --- |
| 2026-11-04 20:30 | `UE4SS.dll+0x2DB4D1` | different function from the rest |
| 2026-11-06 20:31 | `UE4SS.dll+0xC7F600` | property accessor family |
| 2026-11-06 22:23 | `UE4SS.dll+0xC7FB58` | property hash/index leaf |
| 2026-11-07 03:21 | `ucrtbase.dll+0xED921` | CRT-side fault; likely secondary |
| 2026-11-07 11:44 | `UE4SS.dll+0xC808D9` | property accessor family |
| 2026-11-07 11:59 | `UE4SS.dll+0xC7FB58` | same address as 22:23 |
| 2026-11-07 13:09 | `UE4SS.dll+0xC7210D` | property accessor family |
| 2026-11-07 13:39 | `UE4SS.dll+0xC808D9` | same address as 11:44 |

## What the faulting code does

- `0xC80790` reads an `FProperty` type byte (`& 0x3F`, then a 22-entry jump table) and computes a value address
  from `[property + 0xb]` (element-size bits) and `[property + 0x18]` (value array).
- `0xC7F5E0` calls `0xC80790`, then dereferences the returned pointer with `movzx eax, [rbx+9]` before checking it.
- `0xC7FA30` / `0xC7FB58` is a leaf routine in the same property hash/index path (no unwind entry in `.pdata`).
- `0xC720D0` / `0xC7210D` is another function in the same Lua-to-property lookup chain.

A sample stack from the 11:59 dump:

```
RIP               UE4SS.dll+0xC7FB58
return address    UE4SS.dll+0xC72181
                  UE4SS.dll+0xC7F1D5
                  UE4SS.dll+0xC87717
                  UE4SS.dll+0xC870B7
                  UE4SS.dll+0x2D54FD
                  main.dll+0x1589E08
                  UE4SS.dll+0x200AEB
                  PBZ.exe+0x46BF358
```

This is a game-thread Lua callback reaching UE4SS's property lookup with a property pointer or property wrapper that
is null or already freed. The access violation happens inside native code, so `pcall` in Lua cannot catch it.

## What was ruled out

- It is not a cross-thread race: all dumps are on `GameThread`, and every timer callback in the mod is wrapped in
  `ExecuteInGameThread`.
- It is not a Lua syntax/local limit problem: the local-variable checker reports well under 200.
- It is not always tied to one feature: crashes happened with the basic clash reward only, during the 2.5 s
  whirlwind invulnerability, and during a long chain of blocks.

## Current mitigation

- `HealthGuard` is off by default. The 16 ms player-health write was the highest-frequency reflection access in the
  mod; the game's own invulnerability effect is enough in the recorded tests.
- The weapon-switch polling was removed (it also caused a separate bug: `FName` `tostring` changed on every read,
  which fired the reward every 0.6 s).
- Player-pawn changes stop the health guard and reset the watch state, so a level change does not keep writing to a
  stale `AttributeSet`.
- The root cause is not fixed. A future dump can be narrowed by looking at whether the faulting pointer is null
  (`0xC7F600` reading `[rbx+9]`) or a freed/reused address, and by recording the last property path before the
  access.

These RVAs are specific to UE4SS `v3.0.1-1195-g1ceefac8`; a different build will not match.
