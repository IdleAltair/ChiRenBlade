# Shachi cost: free and reduced heavies

How the mod makes ChiRen heavy attacks cost less sha-chi, and a bug that made "free" heavies silently
keep charging. Verified against Steam build `26367565`.

## The game ignores the cost fields

Writing the ability's `Shachi Cost` / `Shachi Cost Min` fields, or the
`HeavyAttack_ShachiCostReduction` attribute, succeeds (the value reads back changed) but **changes
nothing** — the game does not read them when it charges a heavy. So cost reduction cannot be done by
editing the cost up front.

The working mechanism is a **refund**: after the heavy charges the bar, watch the player's sha-chi for
about a second and write back the portion that should be kept (`ScheduleShachiRefund`). A newer
activation cancels the previous watchers (a `refundToken`); a rise (regen) just moves the baseline.
Heavies are animation-gated, normally >850 ms apart, so the refund window (80–850 ms) completes before
the next activation cancels it.

## The bug: "free" heavies were not free

A clash grants charges; with charges > 0 the heavy is meant to be free. The free path wrote
`Shachi Cost = 0`, decremented the charge counter and logged `free heavy: ... (N left)` — but it
**scheduled no refund** (the refund call was gated `not freeAttack`). Since the cost write is ignored,
the game still charged the heavy.

A feedback log showed exactly this: `free heavy` firing and charges decrementing, yet the game's own
`Actual Shachi Consumed` field read 180.8 / 60.8 on those "free" heavies and the sha-chi bar drained to
0 under spam. The clash trigger, the heavy hooks (6 variants, B/BBB via the `BP_HeavyAttack_Base`
grandparent fallback) and the charge counter were all fine — the cost was simply never refunded.

**The earlier "it works" check was on the wrong metric.** Watching the charge counter decrement proves
the write happened, not that the cost was prevented. *A successful write is not proof of effect.*

## The fix

Route free heavies through the same refund watcher, keeping nothing:

```lua
if before ~= nil then
    if freeAttack then
        ScheduleShachiRefund(before, 0)              -- free: refund 100% of the charged shachi
    elseif Settings.HeavyCostScale < 1 then
        ScheduleShachiRefund(before, Settings.HeavyCostScale)  -- reduced: keep the scaled part
    end
end
```

`ScheduleShachiRefund(before, keepScale)` now takes the kept fraction (default `HeavyCostScale`);
`target = expected - spent * keepScale`, so `keepScale = 0` returns everything.

## Verify

- On a free heavy, look for `refund +Xms: spent Y, kept 0, wrote ... ok=true` and the sha-chi bar
  staying full under spam. No refund log means the watcher never saw the drop.
- The refund baseline (`before`, read in the `K2_ActivateAbility` post-hook) must be **pre-deduction**
  for the watcher to catch the drop. This assumes the cost is charged during the montage after the
  activation event; *pending confirmation from the refund logs*. If `before` is already post-deduction
  the watcher sees no drop and never refunds — that would need a pre-hook or a different baseline.
- `Actual Shachi Consumed` is the game's record of what it charged; it is the direct evidence of
  consumption, independent of regen masking the net bar change.