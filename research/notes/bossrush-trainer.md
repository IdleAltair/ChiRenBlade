# BossRushTrainer: "the boss takes no damage"

This is not part of ChiRen Blade, but it looks exactly like a mod bug and is worth checking first.

If the enemy's poise/break meter fills and hit reactions play, but its health bar never moves (and a whirlwind
deals no damage), check the BossRushTrainer training profile before touching the damage code.

BossRushTrainer has a per-boss setting called **Boss 免伤** (`boss_immortal`). Its own description is: keep hits and
hit reactions, only stop the boss's health from decreasing; phase changes that depend on health will not happen.

- UI: open the trainer settings for the selected boss and turn off the `Boss 免伤` switch.
- File: `BossRushTrainer/trainer_profiles.lua` stores the profiles next to the mod's `Scripts` folder. A profile
  with `boss_immortal=true` will lock that boss's health for every training session.
- The flag is per boss. One boss can be locked while the others are normal.

A reliable way to tell it apart from a real damage bug is to log the boss's current health on a low-frequency timer:
if the number never changes while the poise meter does, the health is being locked outside the damage code.

The `BP_Monster_YuBi_Stand_C` actor is a stand-form hit-reaction actor and can keep a constant health value even
when the main `BP_Monster_YuBi_C` is taking damage; do not use the stand actor alone as proof of a lock.
