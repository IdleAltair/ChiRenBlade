local UEHelpers = require("UEHelpers")

local MOD = "ChiRenBlade"
local VERSION = "1.0"

local DEFAULTS = {
    Charges = 6,
    FireEnabled = true,
    FireSeconds = 5,
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    HeavyCostScale = 0.5,
    DeflectWindowFrames = 0,
    ClashWindowFrames = 0,
    SwitchAttackBlock = false,
    SwitchAttackBranch = "Normal",
    SwitchAttackWindowFrames = 7,
    SwitchDeflectInject = true,
    SwitchDeflectFrames = 10,
    SwitchDeflectAngle = 120,
    SwitchDeflectRedEye = false,
    SwitchKeepStacks = true,
    InvulnSeconds = 1.2,
    HealthGuard = false,
    TornadoInvulnSeconds = 2.5,
    TornadoClashMin = 1,
    TornadoClashMax = 6,
    TornadoDamageScale = 1.0,
    TornadoDamageSeconds = 4.0,
    TornadoBurnSeconds = 15,
    TornadoEasyCast = false,
    BreakOnClash = true,
    BreakThreshold = 3,
    BreakHoldSeconds = 1.2,
    ClashSlowmoEnabled = false,
    ClashSlowmoSpeed = 0.3,
    ClashSlowmoSeconds = 0.4,
    LogEvents = true,
    LogDamage = false,
    ProbeSwitchAttack = false,
}

-- The game's global combat config asset holds the block-parry perfect window.
local COMBAT_CONFIG_CLASS = "PDA_GlobalCombatConfig_C"
-- The game's own effects. GE_DodgeInvulnerable did not grant any invulnerability tag in game, so the
-- damage-ignoring effect is tried first; the dodge effect stays as a fallback. Assets are lazy-loaded,
-- so they are loaded by path on the first clash.
local INVULN_GE_CANDIDATES = {
    {
        -- The shipped "invulnerable while casting the ultimate" talent effect: a real invulnerability
        -- state, so it should also suppress the hit reaction that ignore-damage does not.
        class = "GE_PBZSpecialMoveInvulnerable_C",
        path = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_PBZSpecialMoveInvulnerable.GE_PBZSpecialMoveInvulnerable_C",
    },
    {
        class = "GE_IgnoreAllDamage_C",
        path = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_IgnoreAllDamage.GE_IgnoreAllDamage_C",
    },
    {
        class = "GE_DodgeInvulnerable_C",
        path = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_DodgeInvulnerable.GE_DodgeInvulnerable_C",
    },
}

local HEAVY_CLASSES = {
    "GA_Hun_ChiRen_B_C",
    "GA_Hun_ChiRen_BB_C",
    "GA_Hun_ChiRen_BBB_C",
    "GA_Hun_ChiRen_BD_C",
    "GA_Hun_ChiRen_BSup_C",
    "GA_Hun_ChiRen_C_C",
}

-- Light chains also put the player into an attack, which is the real signal that a deflect frame
-- came from a clash rather than a held block.
local ATTACK_CLASSES = {
    "GA_Hun_ChiRen_A_C", "GA_Hun_ChiRen_AA_C", "GA_Hun_ChiRen_AAA_C",
    "GA_Hun_ChiRen_AAAA_C", "GA_Hun_ChiRen_AAAAB_C", "GA_Hun_ChiRen_AAAABB_C",
    "GA_Hun_ChiRen_AAAB_C", "GA_Hun_ChiRen_AAABB_C", "GA_Hun_ChiRen_AAB_C",
    "GA_Hun_ChiRen_AABB_C", "GA_Hun_ChiRen_AB_C", "GA_Hun_ChiRen_ABB_C",
}

local errors = 0
local charges = 0
-- Clash streak for 风回云卷 (GA_Hun_ChiRen_BSup): the streak sets the damage multiplier from
-- TornadoClashMin to TornadoClashMax, and a cast consumes the whole streak. The cast itself still
-- needs the game's blade-force Lv3, which is what turns LB+Y into the whirlwind. The streak lives in
-- TORNADO.combo; TornadoEasyCast can top the tier to Lv3 so a single clash can cast.
local origCosts = {}
local hookedHeavy = {}
local hookedDeflect = false
local lastClash = 0

local function log(fmt, ...)
    print(string.format("[%s] " .. fmt .. "\n", MOD, ...))
end

local function logError(message)
    errors = errors + 1
    if errors <= 15 then
        log("ERROR " .. tostring(message))
    end
end

local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        logError(result)
        return nil
    end
    return result
end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function Unwrap(context)
    if context == nil then return nil end
    local ok, object = pcall(function() return context:get() end)
    if ok and object ~= nil then return object end
    return context
end

local function FullName(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    return ok and name or "?"
end

local function classPathOf(object)
    local path = safe(function() return object:GetClass():GetFullName() end)
    if not path then return nil end
    return path:gsub("^Class ", "")
end

local function readField(object, name)
    return safe(function() return object[name] end)
end

local function readNumber(object, name)
    local value = readField(object, name)
    if type(value) == "number" then return value end
    if type(value) == "table" or type(value) == "userdata" then
        local current = safe(function() return value.CurrentValue end)
        if type(current) == "number" then return current end
    end
    return nil
end

local function ResolveObject(path)
    local object = safe(StaticFindObject, path)
    if valid(object) then return object end
    safe(LoadAsset, path)
    object = safe(StaticFindObject, path)
    return valid(object) and object or nil
end

-- Values outside these ranges keep the default.
local LIMITS = {
    Charges = { 0, 20 },
    FireSeconds = { 0.5, 30 },
    CooldownSeconds = { 0, 2 },
    HeavyCostScale = { 0.05, 1.0 },
    DeflectWindowFrames = { 0, 60 },
    ClashWindowFrames = { 0, 60 },
    SwitchAttackWindowFrames = { 0, 60 },
    SwitchDeflectFrames = { 0, 60 },
    SwitchDeflectAngle = { 1, 360 },
    InvulnSeconds = { 0, 5 },
    TornadoInvulnSeconds = { 0, 5 },
    TornadoClashMin = { 1, 6 },
    TornadoClashMax = { 3, 10 },
    TornadoDamageScale = { 1.0, 3.0 },
    TornadoDamageSeconds = { 1.0, 8.0 },
    TornadoBurnSeconds = { 0, 60 },
    BreakThreshold = { 1, 10 },
    BreakHoldSeconds = { 0, 3 },
    ClashSlowmoSpeed = { 0.05, 1.0 },
    ClashSlowmoSeconds = { 0.05, 2.0 },
}

local Settings = {}
for name, value in pairs(DEFAULTS) do
    Settings[name] = value
end
local okConfig, config = pcall(require, "config")
if okConfig and type(config) == "table" then
    for name, value in pairs(config) do
        local default = DEFAULTS[name]
        if default == nil then
            log("config.lua: unknown setting " .. tostring(name) .. " ignored.")
        elseif type(value) ~= type(default) then
            log(string.format("config.lua: %s must be a %s; the default %s is used.", name, type(default),
                tostring(default)))
        else
            local limit = LIMITS[name]
            if limit and (value < limit[1] or value > limit[2]) then
                log(string.format("config.lua: %s must be from %s to %s; the default %s is used.", name,
                    tostring(limit[1]), tostring(limit[2]), tostring(default)))
            else
                Settings[name] = value
            end
        end
    end
elseif not okConfig then
    log("config.lua not read; every setting uses its default.")
end
if Settings.TornadoClashMin > Settings.TornadoClashMax then
    log("config.lua: TornadoClashMin is above TornadoClashMax; 1 and 6 are used.")
    Settings.TornadoClashMin = 1
    Settings.TornadoClashMax = 6
end

local BURNING_FNAME = FName("CharacterState.AbilityState.ChiRen.Burning", EFindName.FNAME_Add)
local lastBurning = nil
local fireAppliedAt = nil
-- Wall-clock end of the current fire window. The tornado can extend an existing fire past the
-- mod's short clash fire, so the anti-stacking guard has to follow the real end time.
local fireUntil = nil
local fireAskedSeconds = nil
local fireReapplyAt = nil
local TryFire
-- FireStateGE is a class; its default object holds the duration that the effect copies on apply.
local fireCdo = nil

local function LogEvent(fmt, ...)
    if Settings.LogEvents then
        log(fmt, ...)
    end
end

local function WriteNumber(object, name, value)
    local before = readField(object, name)
    local ok, err = pcall(function() object[name] = value end)
    local after = readField(object, name)
    LogEvent("%s: %s -> %s (ok=%s%s)", name, tostring(before), tostring(after), tostring(ok),
        ok and "" or (", " .. tostring(err)))
end

-- The class default object of a Blueprint class: the field first, then the Default__ path.
local function FindCDO(classObject)
    local cdo = readField(classObject, "ClassDefaultObject")
    if valid(cdo) then return cdo end
    local full = safe(function() return classObject:GetFullName() end)
    if full then
        local trimmed = full:gsub("^%w+ ", "")
        local package, name = trimmed:match("^(.-)%.([^%.]+)$")
        if package and name then
            local found = safe(StaticFindObject, package .. ".Default__" .. name)
            if valid(found) then return found end
        end
    end
    return nil
end

local function GetPlayerPawn()
    local controller = safe(UEHelpers.GetPlayerController)
    if not valid(controller) then return nil end
    local pawn = safe(function() return controller.Pawn end)
    if not valid(pawn) then return nil end
    return pawn
end

local function PlayerShachi()
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return nil end
    local set = safe(function() return pawn.AttributeSetBase end)
    if not valid(set) then return nil end
    return readNumber(set, "Shachi")
end

local function CheckBurning()
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return end
    local abilities = readField(pawn, "AbilitySystemComponent")
    if not valid(abilities) then return end
    local count = safe(function() return abilities:GetGameplayTagCount({ TagName = BURNING_FNAME }) end)
    if count == nil then return end
    if count ~= lastBurning then
        lastBurning = count
        if count == 0 and fireAppliedAt then
            local now = os.clock()
            local untilAt = fireUntil or (fireAppliedAt + Settings.FireSeconds)
            if now < untilAt then
                -- A hit clears the temporary fire state. Put it back for the rest of the window so
                -- FireSeconds still means what the setting says, but rate-limit the retries.
                if now - (fireReapplyAt or 0) >= 1.0 then
                    fireReapplyAt = now
                    local remaining = math.max(0.5, untilAt - now)
                    if type(TryFire) == "function" then
                        TryFire(true, remaining)
                    end
                    LogEvent("fire: cleared by a hit, reapplied %.1f s", remaining)
                end
            else
                LogEvent("fire lasted %.2f s (last target %.1f)", now - fireAppliedAt,
                    fireAskedSeconds or Settings.FireSeconds)
                fireAppliedAt = nil
                fireUntil = nil
                fireAskedSeconds = nil
            end
        end
        LogEvent("burning=%s at %.1f (shachi=%s)", tostring(count), os.clock(), tostring(PlayerShachi()))
    end
end

-- The fire duration of GE_ChiRen_FireState comes from SetByCaller, which BP_ApplyGameplayEffectToSelf
-- cannot set. The default object is switched to a fixed duration for the one apply and then restored.
local fireCdoLogged = false

local function ResolveFireCdo(ge)
    if valid(fireCdo) then
        return fireCdo
    end
    fireCdo = FindCDO(ge)
    if not valid(fireCdo) then
        return nil
    end
    if not fireCdoLogged then
        fireCdoLogged = true
        local magnitude = readField(fireCdo, "DurationMagnitude")
        local calc = magnitude and readField(magnitude, "MagnitudeCalculationType") or nil
        local value = magnitude and safe(function() return magnitude.ScalableFloatMagnitude.Value end) or nil
        LogEvent("fire: GE default calc=%s value=%s", tostring(calc), tostring(value))
    end
    return fireCdo
end

-- The passive holds the effect class; kept after the first find because TryFire can run on every clash.
local fireGe = nil

local function ResolveFireGe()
    if valid(fireGe) then
        return fireGe
    end
    local passives = safe(FindAllOf, "GA_ChiRen_Passive")
    if not passives or #passives == 0 then
        return nil
    end
    for _, passive in ipairs(passives) do
        if valid(passive) then
            local ge = readField(passive, "FireStateGE")
            if ge then
                fireGe = ge
                return ge
            end
        end
    end
    return nil
end

TryFire = function(force, duration)
    if not Settings.FireEnabled then
        return
    end
    local applySeconds = duration or Settings.FireSeconds
    -- Each clash used to stack another independent GE instance, which multiplies the fire damage;
    -- a long fight reached dozens of layers. A new layer is only applied after the current one has
    -- fully expired, so the player never carries more than one mod layer. `force` is the reapply
    -- after a hit cleared the state; it keeps the original window end.
    if fireAppliedAt then
        local now = os.clock()
        local untilAt = fireUntil or (fireAppliedAt + Settings.FireSeconds)
        if now < untilAt and not force then
            LogEvent("fire: still burning, skipped")
            return
        end
        if now - fireAppliedAt > Settings.FireSeconds * 2 then
            fireAppliedAt = nil
            fireUntil = nil
            fireAskedSeconds = nil
        end
    end
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return
    end
    local ge = ResolveFireGe()
    if not ge then
        LogEvent("fire: no FireStateGE")
        return
    end
    local abilities = readField(pawn, "AbilitySystemComponent")
    if not valid(abilities) then
        LogEvent("fire: no ASC")
        return
    end
    local context = safe(function() return abilities:MakeEffectContext() end)
    if not context then
        LogEvent("fire: no effect context")
        return
    end
    local cdo = ResolveFireCdo(ge)
    if not valid(cdo) then
        LogEvent("fire: no GE default object")
        return
    end
    local magnitude = readField(cdo, "DurationMagnitude")
    if magnitude == nil then
        LogEvent("fire: no DurationMagnitude")
        return
    end
    local originalCalc = readField(magnitude, "MagnitudeCalculationType")
    local originalValue = safe(function() return magnitude.ScalableFloatMagnitude.Value end)
    local setCalc, calcError = pcall(function() magnitude.MagnitudeCalculationType = 0 end)
    local setValue, valueError = pcall(function() magnitude.ScalableFloatMagnitude.Value = applySeconds end)
    if not setCalc then
        LogEvent("fire: could not switch the duration calculation (%s)", tostring(calcError))
    end
    if not setValue then
        LogEvent("fire: could not write the duration (%s)", tostring(valueError))
    end
    local ok, err = pcall(function()
        abilities:BP_ApplyGameplayEffectToSelf(ge, 1.0, context)
    end)
    if originalCalc ~= nil then
        pcall(function() magnitude.MagnitudeCalculationType = originalCalc end)
    end
    if originalValue ~= nil then
        pcall(function() magnitude.ScalableFloatMagnitude.Value = originalValue end)
    end
    if ok then
        if force then
            LogEvent("fire: reapplied for %.1f s", applySeconds)
        else
            fireAppliedAt = os.clock()
            fireUntil = fireAppliedAt + applySeconds
            fireAskedSeconds = applySeconds
            LogEvent("fire: applied, asked %.1f s", applySeconds)
        end
    else
        LogEvent("fire: BP_ApplyGameplayEffectToSelf failed (%s)", tostring(err))
    end
end

local function HandleText(handle)
    if handle == nil then
        return "nil"
    end
    local ok, value = pcall(function() return tostring(handle.Handle) end)
    return ok and value or tostring(handle)
end

local invulnGe = nil

local function ResolveInvulnGe()
    if valid(invulnGe) then
        return invulnGe
    end
    for _, candidate in ipairs(INVULN_GE_CANDIDATES) do
        local loaded = safe(LoadAsset, candidate.path)
        if valid(loaded) then
            invulnGe = loaded
            LogEvent("invuln: using %s", candidate.class)
            return loaded
        end
        local objects = safe(FindAllOf, candidate.class)
        if objects then
            for _, object in ipairs(objects) do
                if valid(object) then
                    invulnGe = object
                    LogEvent("invuln: using loaded %s", candidate.class)
                    return object
                end
            end
        end
    end
    return nil
end

-- The dodge GE takes its duration from a SetByCaller magnitude, which BP_ApplyGameplayEffectToSelf
-- cannot set. Switch the default object to a fixed duration for the one apply, then restore it (the
-- same trick as the fire GE).
local function ApplyTimedGe(abilities, ge, seconds)
    local cdo = FindCDO(ge)
    if not valid(cdo) then
        LogEvent("ge: no default object for %s", FullName(ge))
        return nil
    end
    local magnitude = readField(cdo, "DurationMagnitude")
    if magnitude == nil then
        LogEvent("ge: %s has no DurationMagnitude", FullName(ge))
        return nil
    end
    local originalCalc = readField(magnitude, "MagnitudeCalculationType")
    local originalValue = safe(function() return magnitude.ScalableFloatMagnitude.Value end)
    pcall(function() magnitude.MagnitudeCalculationType = 0 end)
    pcall(function() magnitude.ScalableFloatMagnitude.Value = seconds end)
    local context = safe(function() return abilities:MakeEffectContext() end)
    local ok, result = false, nil
    if context then
        ok, result = pcall(function()
            return abilities:BP_ApplyGameplayEffectToSelf(ge, 1.0, context)
        end)
    end
    if originalCalc ~= nil then
        pcall(function() magnitude.MagnitudeCalculationType = originalCalc end)
    end
    if originalValue ~= nil then
        pcall(function() magnitude.ScalableFloatMagnitude.Value = originalValue end)
    end
    if not ok then
        LogEvent("ge: apply failed (%s)", tostring(context and result or "no effect context"))
        return nil
    end
    return result
end

local INVULNERABLE_FNAME = FName("Invulnerable", EFindName.FNAME_Add)

local function InvulnerableCount(abilities)
    if not valid(abilities) then
        return nil
    end
    return safe(function() return abilities:GetGameplayTagCount({ TagName = INVULNERABLE_FNAME }) end)
end

-- GE_DodgeInvulnerable did not raise the "Invulnerable" tag in game, so the real tag (if any) is unknown.
-- Log a few likely names once to identify it from a single clash.
local INVULN_TAG_NAMES = {
    "Invulnerable",
    "State.Invulnerable",
    "CharacterState.Invulnerable",
    "CharacterState.AbilityState.Invulnerable",
    "CharacterState.AbilityState.Dodge.Invulnerable",
    "CharacterState.AbilityState.DodgeInvulnerable",
}
local invulnTagFnames = {}
for i, name in ipairs(INVULN_TAG_NAMES) do
    invulnTagFnames[i] = { name = name, fname = FName(name, EFindName.FNAME_Add) }
end
local invulnTagsLogged = false

local function LogInvulnTags(abilities, label)
    if invulnTagsLogged or not valid(abilities) then
        return
    end
    invulnTagsLogged = true
    local parts = {}
    for _, entry in ipairs(invulnTagFnames) do
        local count = safe(function()
            return abilities:GetGameplayTagCount({ TagName = entry.fname })
        end)
        parts[#parts + 1] = entry.name .. "=" .. tostring(count)
    end
    LogEvent("invuln tags after %s: %s", label, table.concat(parts, ", "))
end

-- The GE path cannot be trusted until the right tag is known. Keep the health at the value it had when
-- the clash landed for the whole window and skip the player's hit reaction, so a hit neither takes
-- health nor puts the player into a stagger.
local invulnGuardToken = 0
local invulnUntil = 0
local hitreactHooked = false
local hitreactSkipped = 0

local function AnimationOf(comp)
    if not valid(comp) then
        return "nocomp"
    end
    local runtime = readField(comp, "RuntimeStateData")
    if runtime == nil then
        return "noruntime"
    end
    local anim = readField(runtime, "StateAnimation")
    if anim == nil then
        return "nil"
    end
    if not valid(anim) then
        return "null"
    end
    return FullName(anim)
end

local hitreactLogs = 0
local hitreactArgLogs = 0
local FNameText, CurrentHitState, HitreactOwnerName
function HitreactOwnerName(comp)
    local owner = safe(function() return comp:GetOuter() end)
    return valid(owner) and FullName(owner) or "?"
end

local function SkipHitreact(name, context, ...)
    local self = Unwrap(context)
    local ownerName = HitreactOwnerName(self)
    local isPlayer = ownerName:find("BP_Renewal_Hun", 1, true) ~= nil
    -- UE4SS only uses the hook return value to overwrite the function's result after the original
    -- already ran, so returning anything here cannot suppress the reaction and would instead lie to
    -- the caller about it (bosses included). Always leave the stack empty.
    if isPlayer and os.clock() < invulnUntil then
        hitreactSkipped = hitreactSkipped + 1
        LogEvent("invuln: hitreact during window %s (%d) args=%d anim=%s", name, hitreactSkipped,
            select("#", ...), AnimationOf(self))
    end
    -- A hit clears the temporary fire state. Reapply it immediately (rate-limited) instead of
    -- waiting for the 300 ms burning sample, so the FireSeconds window is covered except for the
    -- hit frame itself. The 1.2 s invulnerability only protects the first part of that window.
    if isPlayer and fireAppliedAt then
        local now = os.clock()
        local untilAt = fireUntil or (fireAppliedAt + Settings.FireSeconds)
        if now < untilAt and now - (fireReapplyAt or 0) >= 1.0 then
            local pawn = GetPlayerPawn()
            local abilities = valid(pawn) and readField(pawn, "AbilitySystemComponent") or nil
            if valid(abilities) then
                local count = safe(function()
                    return abilities:GetGameplayTagCount({ TagName = BURNING_FNAME })
                end)
                if count == 0 then
                    fireReapplyAt = now
                    local remaining = math.max(0.5, untilAt - now)
                    if type(TryFire) == "function" then
                        TryFire(true, remaining)
                    end
                    LogEvent("fire: hit cleared it, reapplied %.1f s", remaining)
                end
            end
        end
    end
    -- Sample the attacker's own reaction so the interrupt can later play the same animation.
    if not isPlayer and hitreactLogs < 20 then
        hitreactLogs = hitreactLogs + 1
        LogEvent("hitreact sample: %s owner=%s args=%d anim=%s", name, ownerName, select("#", ...),
            AnimationOf(self))
        if hitreactArgLogs < 5 then
            hitreactArgLogs = hitreactArgLogs + 1
            local first = Unwrap(select(1, ...))
            local firstName = valid(first) and FullName(first) or tostring(first)
            local firstClass = valid(first) and safe(function() return first:GetClass():GetFullName() end)
                or "?"
            LogEvent("hitreact sample: first=%s class=%s", tostring(firstName), tostring(firstClass))
        end
        ExecuteWithDelay(120, function()
            ExecuteInGameThread(function()
                if valid(self) then
                    LogEvent("hitreact sample: +120ms anim=%s", AnimationOf(self))
                end
            end)
        end)
    end
end

local function TryHitreactHook()
    if hitreactHooked then
        return
    end
    local comps = safe(FindAllOf, "HitreactComponent")
    if not comps then
        return
    end
    for _, comp in ipairs(comps) do
        if valid(comp) then
            local owner = safe(function() return comp:GetOuter() end)
            local ownerName = valid(owner) and FullName(owner) or ""
            if ownerName:find("BP_Renewal_Hun", 1, true) then
                local path = classPathOf(comp)
                if path then
                    hitreactHooked = true
                    for _, fn in ipairs({ "PlayHitreact", "PlayHitreactToAvatar" }) do
                        local ok, err = pcall(RegisterHook, path .. ":" .. fn, function(context, ...)
                            return SkipHitreact(fn, context, ...)
                        end)
                        if ok then
                            LogEvent("invuln: hooked player %s", fn)
                        else
                            LogEvent("invuln: hook %s failed (%s)", fn, tostring(err))
                        end
                    end
                    return
                end
            end
        end
    end
end

local function HealthOf(pawn)
    if not valid(pawn) then
        return nil, nil
    end
    local set = readField(pawn, "AttributeSetBase")
    if not valid(set) then
        return nil, nil
    end
    return readNumber(set, "Health"), set
end

local function SetHealth(set, value)
    local health = readField(set, "Health")
    if health == nil then
        return false, "no Health"
    end
    -- CurrentValue alone is recomputed from BaseValue by the attribute aggregator on the next damage
    -- apply, so the base value is written too; otherwise the guard only flickers the bar.
    local okBase, errBase = pcall(function() health.BaseValue = value end)
    local okCur, errCur = pcall(function() health.CurrentValue = value end)
    local now = readNumber(set, "Health")
    return okBase or okCur, string.format("base=%s cur=%s now=%s%s", tostring(okBase), tostring(okCur),
        tostring(now), (okBase or okCur) and "" or (" err=" .. tostring(errBase or errCur)))
end

local function StartHealthGuard(seconds)
    local untilAt = os.clock() + seconds
    invulnUntil = untilAt
    if not Settings.HealthGuard then
        LogEvent("invuln guard: disabled by config, relying on the game invulnerability effect")
        return
    end
    local guardPawn = GetPlayerPawn()
    local startHealth = HealthOf(guardPawn)
    if startHealth == nil then
        LogEvent("invuln guard: no health on the player")
        return
    end
    local guardAddr = safe(function() return guardPawn:GetAddress() end)
    invulnGuardToken = invulnGuardToken + 1
    local token = invulnGuardToken
    local blocked = 0
    LogEvent("invuln guard: start health=%.0f for %.1f s", startHealth, seconds)
    local function step()
        ExecuteWithDelay(16, function()
            ExecuteInGameThread(function()
                if token ~= invulnGuardToken then
                    return
                end
                if os.clock() >= untilAt then
                    LogEvent("invuln guard: done, blocked=%d", blocked)
                    return
                end
                local pawn = GetPlayerPawn()
                if not valid(pawn) then
                    LogEvent("invuln guard: player gone, stopped")
                    return
                end
                -- A level change or a new pawn during the window would make every following write
                -- target a stale AttributeSet; stop instead of chasing the new pawn.
                local pawnAddr = safe(function() return pawn:GetAddress() end)
                if guardAddr ~= nil and pawnAddr ~= nil and pawnAddr ~= guardAddr then
                    LogEvent("invuln guard: player changed, stopped")
                    return
                end
                local now, set = HealthOf(pawn)
                if now ~= nil and now < startHealth - 0.5 then
                    blocked = blocked + 1
                    local ok, err = SetHealth(set, startHealth)
                    LogEvent("invuln guard: blocked %d, health %.0f -> %.0f ok=%s%s", blocked, now,
                        startHealth, tostring(ok), ok and "" or (" err=" .. tostring(err)))
                end
                step()
            end)
        end)
    end
    step()
end

---------------------------------------------------------------------------------------------------------------------
-- Invulnerability after a clash
---------------------------------------------------------------------------------------------------------------------

-- The game's own dodge invulnerability: GE_DodgeInvulnerable. It is applied for InvulnSeconds and removed
-- explicitly, so an infinite-duration effect cannot stay on the player.
local invulnHandle = nil
local invulnToken = 0

local function RemoveInvuln()
    if invulnHandle == nil then
        return
    end
    local pawn = GetPlayerPawn()
    if valid(pawn) then
        local abilities = readField(pawn, "AbilitySystemComponent")
        if valid(abilities) then
            local ok, err = pcall(function()
                abilities:RemoveActiveGameplayEffect(invulnHandle, 1)
            end)
            LogEvent("invuln: removed ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err)))
        end
    end
    invulnHandle = nil
end

local function TryInvulnerable(seconds)
    if seconds == nil then
        seconds = Settings.InvulnSeconds
    end
    if seconds <= 0 then
        return
    end
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return
    end
    local abilities = readField(pawn, "AbilitySystemComponent")
    if not valid(abilities) then
        return
    end
    StartHealthGuard(seconds)
    local ge = ResolveInvulnGe()
    if not ge then
        LogEvent("invuln: no invulnerability GE found")
        return
    end
    invulnToken = invulnToken + 1
    local token = invulnToken
    RemoveInvuln()
    local before = InvulnerableCount(abilities)
    local result = ApplyTimedGe(abilities, ge, seconds)
    if result == nil then
        return
    end
    invulnHandle = result
    LogEvent("invuln: applied %.1f s handle=%s tag %s -> %s", seconds, HandleText(result),
        tostring(before), tostring(InvulnerableCount(abilities)))
    LogInvulnTags(abilities, "apply")
    ExecuteWithDelay(math.floor(seconds * 1000), function()
        ExecuteInGameThread(function()
            if token ~= invulnToken then
                return
            end
            RemoveInvuln()
            local pawn = GetPlayerPawn()
            local abilities = valid(pawn) and readField(pawn, "AbilitySystemComponent") or nil
            LogEvent("invuln: ended, tag=%s", tostring(InvulnerableCount(abilities)))
        end)
    end)
end

---------------------------------------------------------------------------------------------------------------------
-- Probe: native invulnerability and endure (temporary)
---------------------------------------------------------------------------------------------------------------------

-- The skill tree has an "invulnerable while casting the ultimate" talent, so the shipped game already
-- has a real invulnerability effect; it should suppress the hit reaction too, unlike ignore-damage.
local NATIVE_INVULN_CLASSES = {
    "GE_PBZSpecialMoveInvulnerable_C",
    "GE_PBZLieInvulnerable_C",
    "GE_TemporaryEndureBase_C",
    "GE_TemporaryEndureBase_CannotCounter_C",
}
local NATIVE_INVULN_PATHS = {
    "/PBZCombatAsset/Prototypes/GameplayEffects/GE_PBZSpecialMoveInvulnerable.GE_PBZSpecialMoveInvulnerable_C",
}
local nativeInvulnProbeDone = false
local nativeGeHooked = false
local nativeGeLogs = 0

local function TagText(value)
    if value == nil then
        return "nil"
    end
    local ok, text = pcall(function() return value:ToString() end)
    return ok and tostring(text) or tostring(value)
end

local function LogGeTags(ge, label)
    if not valid(ge) then
        return
    end
    for _, fn in ipairs({ "GetGrantedTags", "GetAssetTags" }) do
        local ok, tags
        if fn == "GetGrantedTags" then
            ok, tags = pcall(function() return ge:GetGrantedTags() end)
        else
            ok, tags = pcall(function() return ge:GetAssetTags() end)
        end
        if ok and tags ~= nil then
            LogEvent("native probe: %s %s=%s", label, fn, TagText(tags))
        end
    end
    local cdo = safe(FindCDO, ge)
    if valid(cdo) then
        LogEvent("native probe: %s cdo policy=%s duration=%s", label,
            tostring(readField(cdo, "DurationPolicy")),
            tostring(safe(function() return cdo.DurationMagnitude.ScalableFloatMagnitude.Value end)))
    end
end

local function TryNativeInvulnProbe()
    if nativeInvulnProbeDone then
        return
    end
    if not valid(GetPlayerPawn()) then
        return
    end
    nativeInvulnProbeDone = true
    for _, path in ipairs(NATIVE_INVULN_PATHS) do
        local loaded = safe(LoadAsset, path)
        if valid(loaded) then
            LogEvent("native probe: loaded %s", FullName(loaded))
            LogGeTags(loaded, "native invuln")
        else
            LogEvent("native probe: load failed %s", path)
        end
    end
    for _, class in ipairs(NATIVE_INVULN_CLASSES) do
        local found = safe(FindAllOf, class)
        if found and #found > 0 then
            for index = 1, math.min(#found, 2) do
                if valid(found[index]) then
                    LogEvent("native probe: %s -> %s", class, FullName(found[index]))
                end
            end
        else
            LogEvent("native probe: %s not loaded", class)
        end
    end
end

-- The talent applies its effect through the ability system, so watching the player's own applies
-- reveals the real asset path even when the class was not loaded at start-up.
local function TryNativeGeHook()
    if nativeGeHooked then
        return
    end
    local pawn = GetPlayerPawn()
    local abilities = valid(pawn) and readField(pawn, "AbilitySystemComponent") or nil
    if not valid(abilities) then
        return
    end
    nativeGeHooked = true
    local function onApply(context, ge, level, effectContext)
        if nativeGeLogs >= 200 then
            return
        end
        local self = Unwrap(context)
        local owner = safe(function() return self:GetOuter() end)
        local ownerName = valid(owner) and FullName(owner) or "?"
        if not ownerName:find("BP_Renewal_Hun", 1, true) then
            return
        end
        local geObject = Unwrap(ge)
        nativeGeLogs = nativeGeLogs + 1
        local name = valid(geObject) and FullName(geObject) or tostring(geObject)
        LogEvent("native probe: GE apply %s", name)
        if name:find("Invulnerable", 1, true) or name:find("Endure", 1, true) then
            LogGeTags(geObject, name)
        end
    end
    -- The BP helper lives on the native class; a Blueprint subclass path cannot resolve it globally.
    local ok, err = pcall(RegisterHook,
        "/Script/GameplayAbilities.AbilitySystemComponent:BP_ApplyGameplayEffectToSelf", onApply)
    if not ok then
        local path = classPathOf(abilities)
        if path then
            ok, err = pcall(RegisterHook, path .. ":BP_ApplyGameplayEffectToSelf", onApply)
        end
    end
    LogEvent("native probe: GE hook ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err)))
end

---------------------------------------------------------------------------------------------------------------------
-- Break on clash
---------------------------------------------------------------------------------------------------------------------

local lastBreakName = nil
local lastBreakAt = 0

local function FindClashTarget()
    local comps = safe(FindAllOf, "HitreactComponent")
    if not comps then
        return nil
    end
    local pawn = GetPlayerPawn()
    local playerName = valid(pawn) and FullName(pawn) or nil
    local playerLoc = nil
    if valid(pawn) then
        local root = readField(pawn, "RootComponent")
        if valid(root) then
            playerLoc = readField(root, "RelativeLocation")
        end
    end
    local best, bestDist = nil, nil
    for _, comp in ipairs(comps) do
        if valid(comp) then
            local owner = safe(function() return comp:GetOuter() end)
            if valid(owner) then
                local name = FullName(owner)
                if name ~= playerName and not name:find("Hun", 1, true) then
                    local dist = 0
                    if playerLoc then
                        local root = readField(owner, "RootComponent")
                        if valid(root) then
                            local loc = readField(root, "RelativeLocation")
                            if loc then
                                local dx, dy, dz = loc.X - playerLoc.X, loc.Y - playerLoc.Y,
                                    loc.Z - playerLoc.Z
                                dist = dx * dx + dy * dy + dz * dz
                            end
                        end
                    end
                    if best == nil or dist < bestDist then
                        best, bestDist = owner, dist
                    end
                end
            end
        end
    end
    return best
end

function FNameText(value)
    if value == nil then
        return "nil"
    end
    if type(value) == "string" then
        return value
    end
    local ok, text = pcall(function() return value:ToString() end)
    return ok and tostring(text) or "?"
end

-- The hit state the target is in right now. ChangeHitState's bool return is not a success signal; this is.
function CurrentHitState(comp)
    if not valid(comp) then
        return "nocomp"
    end
    local ok, value = pcall(function() return comp:GetCurrentHitState() end)
    if not ok then
        return "err"
    end
    value = Unwrap(value)
    if value == nil then
        return "nil"
    end
    local tag = readField(value, "TagName")
    if tag ~= nil then
        return FNameText(tag)
    end
    return FNameText(value)
end

local function HitreactCompOf(actor)
    local comps = safe(FindAllOf, "HitreactComponent")
    if not comps then
        return nil
    end
    local targetName = FullName(actor)
    for _, comp in ipairs(comps) do
        if valid(comp) then
            local owner = safe(function() return comp:GetOuter() end)
            if valid(owner) and FullName(owner) == targetName then
                return comp
            end
        end
    end
    return nil
end

local breakToken = 0

-- The clash interrupt charges up over several clashes instead of firing on every one. Unfilled clashes
-- leave the target free to act, which also keeps the invulnerability window testable.
local breakMeter = {}
local BREAK_METER_IDLE_SECONDS = 30

-- One boss can be several actors (stand form, new instance after a phase/revive). Drop the
-- per-instance suffix and the stand marker so every form shares the same meter.
local function MeterKey(name)
    local key = name:gsub("_%d+$", "")
    return (key:gsub("_Stand_C", "_C"))
end

local function AddBreakMeter(name, now)
    local entry = breakMeter[name]
    if entry == nil or now - entry.at > BREAK_METER_IDLE_SECONDS then
        entry = { count = 0, at = now }
    end
    entry.count = entry.count + 1
    entry.at = now
    breakMeter[name] = entry
    return entry.count
end

-- A boss playing a new montage is the only reliable "the AI is moving again" signal: the hit state
-- name returns to Normal even while the boss stays parked. The montage hook below logs the boss's
-- plays around a break so a test can tell recovered from stuck without watching the screen.
local breakWatchName = nil
local breakWatchUntil = 0
local breakStartedAt = 0

-- PlayHitreactToAvatar with a constructed Break attack source drives the whole reaction natively:
-- state, strength montage and exit chain. Sources cached from natural hits were rejected by the
-- component; this Break source is accepted and the state leaves by itself after about a second.
-- This is the path the PBZModLoader F9 probe verified in game.
local ApplyBreakSource

do

local BREAK_SOURCE_PATH =
    "/PBZDeflectSystem/BP_DeflectHitreactAttackSource_Break.BP_DeflectHitreactAttackSource_Break_C"
local BREAK_SOURCE_BLUEPRINT = "/PBZDeflectSystem/BP_DeflectHitreactAttackSource_Break"
local breakSourceClass = nil
local breakSourceSerial = 0
local breakSourceLogged = false

local function ResolveBreakSourceClass()
    if valid(breakSourceClass) then
        return breakSourceClass
    end
    local cls = safe(StaticFindObject, BREAK_SOURCE_PATH)
    if not valid(cls) then
        cls = safe(LoadAsset, BREAK_SOURCE_PATH)
    end
    if not valid(cls) then
        -- LoadAsset on a generated-class path can miss while the blueprint asset itself loads.
        local blueprint = safe(LoadAsset, BREAK_SOURCE_BLUEPRINT)
        cls = valid(blueprint) and readField(blueprint, "GeneratedClass") or nil
    end
    if valid(cls) then
        breakSourceClass = cls
        LogEvent("break source: class %s", FullName(cls))
    end
    return valid(cls) and cls or nil
end

local function TagText(tag)
    if tag == nil then
        return "nil"
    end
    return FNameText(readField(tag, "TagName") or tag)
end

local function MakeBreakSource(pawn)
    local cls = ResolveBreakSourceClass()
    if not cls then
        return nil, "Break attack source class not found"
    end
    breakSourceSerial = breakSourceSerial + 1
    local src = safe(function()
        return StaticConstructObject(cls, pawn,
            FName("ChiRenBreakSource_" .. breakSourceSerial, EFindName.FNAME_Add))
    end)
    if not valid(src) then
        return nil, "construct failed"
    end
    local okAvatar = pcall(function() src["Source Avatar"] = pawn end)
    local okAttacker = pcall(function() src["Is Source Attacker"] = true end)
    local okCounter = pcall(function() src["Counter"] = true end)
    return src, string.format("avatar=%s attacker=%s counter=%s", tostring(okAvatar),
        tostring(okAttacker), tostring(okCounter))
end

ApplyBreakSource = function(target, label)
    local pawn = GetPlayerPawn()
    local comp = HitreactCompOf(target)
    if not valid(pawn) or not valid(comp) then
        LogEvent("break source %s: no pawn or hitreact component", label)
        return false
    end
    local src, notes = MakeBreakSource(pawn)
    if not src then
        LogEvent("break source %s: %s", label, notes)
        return false
    end
    if not breakSourceLogged then
        breakSourceLogged = true
        LogEvent("break source: %s strength=%s style=%s type=%s dir=%s (%s)", FullName(src),
            TagText(safe(function() return src:GetHitStrength() end)),
            TagText(safe(function() return src:GetAttackStyle() end)),
            TagText(safe(function() return src:GetAttackType() end)),
            TagText(safe(function() return src:GetAttackDirection() end)), notes)
    end
    local before = CurrentHitState(comp)
    local ok, result = pcall(function() return comp:PlayHitreactToAvatar(src) end)
    local after = CurrentHitState(comp)
    LogEvent("break source %s: ok=%s result=%s state %s -> %s", label, tostring(ok),
        tostring(result), before, after)
    return ok and after ~= "None" and after ~= before
end

end

local function WatchBreakState(comp, token, label)
    for _, delay in ipairs({ 300, 900, 1800, 3000, 5000 }) do
        ExecuteWithDelay(delay, function()
            ExecuteInGameThread(function()
                if token ~= breakToken or not valid(comp) then
                    return
                end
                LogEvent("%s: +%.1f s state=%s", label, delay / 1000, CurrentHitState(comp))
            end)
        end)
    end
end

-- The player's next hit replaces Break with a plain hit reaction within a few frames, so the enemy
-- looks untouched on video. Replay the Break source when the state has dropped out of Break, up to
-- BreakHoldSeconds. The reaction still ends by itself once the replays stop.
local BREAK_HOLD_REPEAT_MS = 250
local BREAK_HOLD_MAX_REPLAYS = 2

local function MaintainBreak(target, comp, token)
    if Settings.BreakHoldSeconds <= 0 then
        return
    end
    local untilAt = os.clock() + Settings.BreakHoldSeconds
    local replays = 0
    local function step()
        ExecuteWithDelay(BREAK_HOLD_REPEAT_MS, function()
            ExecuteInGameThread(function()
                if token ~= breakToken or not valid(target) or not valid(comp) then
                    return
                end
                local now = os.clock()
                if now >= untilAt or replays >= BREAK_HOLD_MAX_REPLAYS then
                    return
                end
                local state = CurrentHitState(comp)
                if state:find("Dead", 1, true) then
                    return
                end
                if not state:find("Break", 1, true) then
                    replays = replays + 1
                    LogEvent("break hold: replay %d at +%.2f s (state=%s)", replays,
                        now - breakStartedAt, state)
                    ApplyBreakSource(target, "hold")
                end
                step()
            end)
        end)
    end
    step()
end

-- The interrupt charges up over several clashes and is refused inside the game's own unbashable
-- windows, so the source is retried twice before the meter is dropped.
local BREAK_DEDUPE_SECONDS = 0.8
local BREAK_WATCH_SECONDS = 5.0
local BREAK_RETRY_DELAYS_MS = { 150, 400 }

local function TryBreakClash(isBlock, reason)
    if isBlock then
        LogEvent("break: %s, meter skipped", reason or "block impact")
        return
    end
    if not Settings.BreakOnClash then
        return
    end
    local target = FindClashTarget()
    if not valid(target) then
        LogEvent("break: no target")
        return
    end
    local name = FullName(target)
    local now = os.clock()
    if name == lastBreakName and now - lastBreakAt < BREAK_DEDUPE_SECONDS then
        return
    end
    lastBreakName, lastBreakAt = name, now
    local meterName = MeterKey(name)
    local count = AddBreakMeter(meterName, now)
    if count < Settings.BreakThreshold then
        LogEvent("break meter: %d/%d on %s, no interrupt", count, Settings.BreakThreshold, meterName)
        return
    end
    breakMeter[meterName] = nil
    local comp = HitreactCompOf(target)
    if not valid(comp) then
        LogEvent("break meter full: %s (%d/%d); no hitreact component", meterName, count,
            Settings.BreakThreshold)
        return
    end
    breakToken = breakToken + 1
    local token = breakToken
    breakWatchName = name
    breakWatchUntil = now + BREAK_WATCH_SECONDS
    breakStartedAt = now
    LogEvent("break meter full: %s (%d/%d); playing the native Break hitreact", meterName, count,
        Settings.BreakThreshold)
    local watched = false
    local function attempt(label)
        if token ~= breakToken or not valid(target) then
            return false
        end
        if ApplyBreakSource(target, label) then
            if not watched then
                watched = true
                WatchBreakState(comp, token, "break source")
                MaintainBreak(target, comp, token)
            end
            return true
        end
        return false
    end
    if attempt("clash") then
        return
    end
    LogEvent("break source: rejected at the clash, retrying")
    for _, delay in ipairs(BREAK_RETRY_DELAYS_MS) do
        ExecuteWithDelay(delay, function()
            ExecuteInGameThread(function()
                attempt(string.format("retry +%d ms", delay))
            end)
        end)
    end
end

local lastBlockImpactAt = 0
local lastAttackAt = 0
local blockHookState = { hooked = false, attempts = 0 }

---------------------------------------------------------------------------------------------------------------------
-- 风回云卷 (GA_Hun_ChiRen_BSup): clash streak and blade-force tier
---------------------------------------------------------------------------------------------------------------------

-- The game itself only turns LB+Y into the fire whirlwind at blade-force Lv3, and it ignores the
-- patched input rule (a cast was still possible at tier 0), so the clash streak is only the damage
-- multiplier here. The cast gate stays the game's own Lv3 requirement.
local PlayerAbilities, BladeBuffTier

do

local BLADE_BUFF = "CharacterState.AbilityState.Long.Buff"
local BLADE_BUFF_FNAMES = {
    [1] = FName(BLADE_BUFF .. ".Lv1", EFindName.FNAME_Add),
    [2] = FName(BLADE_BUFF .. ".Lv2", EFindName.FNAME_Add),
    [3] = FName(BLADE_BUFF .. ".Lv3", EFindName.FNAME_Add),
}

PlayerAbilities = function()
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return nil, nil end
    return pawn, readField(pawn, "AbilitySystemComponent")
end

BladeBuffTier = function(abilities)
    if not valid(abilities) then return 0 end
    for tier = 3, 1, -1 do
        local count = safe(function()
            return abilities:GetGameplayTagCount({ TagName = BLADE_BUFF_FNAMES[tier] })
        end)
        if count and count > 0 then return tier end
    end
    return 0
end

end

---------------------------------------------------------------------------------------------------------------------
-- Damage log: which action did how much
---------------------------------------------------------------------------------------------------------------------

-- The action name comes from the ability activation hooks; the damage comes from sampling the
-- nearest enemy's Health. A hit is credited to an action started within ACTION_WINDOW_SECONDS;
-- anything later (burning, other sources) is logged without an action. Hits of the same action are
-- summed until the action changes or the window lapses.
local NoteAction, TickDamage

do

local SAMPLE_SECONDS = 0.2
local TARGET_REFRESH_SECONDS = 1.0
local ACTION_WINDOW_SECONDS = 1.5

local target = nil
local targetName = nil
local lastHp = nil
local lastSampleAt = 0
local lastTargetAt = 0
local lastAction = nil
local lastActionAt = 0
local pendingAction = nil
local pendingTarget = nil
local pendingStartAt = 0
local pendingLastAt = 0
local pendingDamage = 0
local pendingHits = 0
local lastWatchAt = 0

local function ShortName(full)
    if not full then return "?" end
    return full:match("([^%.]+)$") or full
end

NoteAction = function(label)
    if not Settings.LogDamage then return end
    lastAction = label
    lastActionAt = os.clock()
end

local function ActorHealth(actor)
    local set = readField(actor, "AttributeSetBase")
    if not valid(set) then return nil end
    return readNumber(set, "Health")
end

local function FlushDamage(reason)
    if pendingAction == nil or pendingHits == 0 then
        pendingAction, pendingDamage, pendingHits = nil, 0, 0
        return
    end
    LogEvent("action damage: %s on %s = %.0f over %d hit(s) in %.2f s (%s)", pendingAction,
        pendingTarget or "?", pendingDamage, pendingHits, pendingLastAt - pendingStartAt, reason)
    pendingAction, pendingTarget, pendingDamage, pendingHits = nil, nil, 0, 0
end

local function CreditDamage(amount, now)
    local action = nil
    if lastAction and now - lastActionAt <= ACTION_WINDOW_SECONDS then
        action = lastAction
    end
    if action == nil then
        FlushDamage("no action")
        LogEvent("damage: %.0f on %s (no recent action)", amount, targetName or "?")
        return
    end
    if pendingAction ~= action then
        FlushDamage("action changed")
        pendingAction = action
        pendingStartAt = now
    end
    pendingLastAt = now
    pendingDamage = pendingDamage + amount
    pendingHits = pendingHits + 1
    pendingTarget = targetName
    LogEvent("damage hit: %.0f %s on %s", amount, action, targetName or "?")
end

TickDamage = function(now)
    if not Settings.LogDamage then return end
    if pendingAction and now - pendingLastAt > ACTION_WINDOW_SECONDS then
        FlushDamage("window ended")
    end
    if now - lastSampleAt < SAMPLE_SECONDS then return end
    lastSampleAt = now
    if not valid(target) or now - lastTargetAt >= TARGET_REFRESH_SECONDS then
        lastTargetAt = now
        local found = FindClashTarget()
        local foundName = valid(found) and FullName(found) or nil
        -- UObject wrappers compare by reference, so the same actor can come back as a new wrapper.
        -- Compare names instead of objects, otherwise the baseline resets on every refresh.
        if foundName ~= targetName then
            if pendingAction then FlushDamage("target changed") end
            targetName = foundName
            lastHp = valid(found) and ActorHealth(found) or nil
        end
        target = found
    end
    if not valid(target) then
        lastHp = nil
        if now - lastWatchAt >= 3.0 then
            lastWatchAt = now
            LogEvent("damage watch: no target")
        end
        return
    end
    local hp = ActorHealth(target)
    if hp == nil then
        if now - lastWatchAt >= 3.0 then
            lastWatchAt = now
            LogEvent("damage watch: %s hp unreadable", ShortName(targetName))
        end
        return
    end
    if now - lastWatchAt >= 3.0 then
        lastWatchAt = now
        LogEvent("damage watch: %s hp=%.0f", ShortName(targetName), hp)
    end
    if lastHp == nil then
        lastHp = hp
        return
    end
    local delta = hp - lastHp
    lastHp = hp
    if delta < -0.5 then
        CreditDamage(-delta, now)
    elseif delta > 0.5 then
        FlushDamage("target healed")
        LogEvent("damage: heal +%.0f on %s", delta, targetName or "?")
    end
end

end

---------------------------------------------------------------------------------------------------------------------
-- Clash slow-motion: a brief world slow-down on a successful clash, for hit feedback.
-- Borrows the mechanism of refs/phantombladezero_witchtime (MIT, Kintaro): the world factor is
-- WorldSettings.DemoPlayTimeDilation, which the engine multiplies with the game's own TimeDilation.
-- TimeDilation cannot hold a slow-down (the game resets it to 1.0 every frame, and its own red-light
-- slow-motion uses it); DemoPlayTimeDilation is the replay factor, so the two do not fight. Timing is
-- real time (os.clock), so the mod's invulnerability/fire/free-attack windows are not stretched. The
-- player slows with the world: no per-frame CustomTimeDilation hook. The frame loop reads/writes the
-- factor only while a slow-down runs; idle it is a single boolean check.
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
-- 风回云卷 easy cast: top the blade-force tier to Lv3 after a clash so a single clash can cast the
-- whirlwind. The game gates LB+Y into BSup at blade-force Lv3 and ignores a patched input rule, so
-- the mod raises the tier instead, with the same native tier-up effect the switch-keep restore uses
-- (GE_Weapon_Long_BuffIncreaseLevel applied by the ChiRen passive owner). Off by default: it fills
-- the blade meter on one clash and may buff normal heavy attacks before the cast.
-- 拼刀后把刀劲顶到三档，让 1 次拼刀就能放风回云卷。游戏在刀劲 Lv3 才把 LB+Y 派生成龙卷，
-- 改输入规则会被无视，所以 mod 改用切武保层同款的原生升档效果把档位顶上去。默认关闭：
-- 它会让拼刀 1 次刀劲条即满，放龙卷前的普通重攻击可能吃到满档加成。
---------------------------------------------------------------------------------------------------------------------
local TORNADO = {
    combo = 0, increase = nil, logs = 0, broken = false,
    -- Clash streak, double-cast followup state/window and easy-cast tier-up, kept here rather than
    -- as main-chunk locals (200-local cap).
    followup = nil, followupSeconds = 4.0,
}

function TORNADO.topTier()
    if not Settings.TornadoEasyCast or TORNADO.broken then return end
    local pawn, asc = PlayerAbilities()
    if not valid(asc) then return end
    local tier = BladeBuffTier(asc)
    if tier == nil or tier >= 3 then return end
    local passive = nil
    local passives = safe(FindAllOf, "GA_Hun_ChiRen_Passive_C")
    if passives then
        for _, p in ipairs(passives) do
            if valid(p) then
                local isActive = safe(function() return p.bIsActive end)
                local owner = safe(function() return p:GetAvatarActorFromActorInfo() end)
                local same = valid(owner) and valid(pawn) and safe(function()
                    return owner:GetAddress() == pawn:GetAddress()
                end)
                if isActive == true and same == true then
                    passive = p
                    break
                end
            end
        end
    end
    if not valid(TORNADO.increase) then
        local path = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Long/UpgradeData/" ..
            "GE_Weapon_Long_BuffIncreaseLevel.GE_Weapon_Long_BuffIncreaseLevel_C"
        TORNADO.increase = safe(StaticFindObject, path)
        if not valid(TORNADO.increase) then
            safe(LoadAsset, path)
            TORNADO.increase = safe(StaticFindObject, path)
        end
    end
    if not valid(passive) or not valid(TORNADO.increase) then
        TORNADO.broken = true
        logError("tornado easy: cannot top blade tier (passive or tier-up effect missing)")
        return
    end
    local before = tier
    for _ = before + 1, 3 do
        local ok = pcall(function() passive:BP_ApplyGameplayEffectToOwner(TORNADO.increase, 1, 1) end)
        local after = BladeBuffTier(asc)
        if not ok or after == nil or after <= before then break end
        before = after
    end
    if TORNADO.logs < 12 then
        TORNADO.logs = TORNADO.logs + 1
        LogEvent("tornado easy: blade tier %d->%d", tier, before)
    end
end

local CLASH_SLOWMO = {
    active = false, endsAt = 0, worldSettings = nil, broken = false, logs = 0,
}

function CLASH_SLOWMO.getWorldSettings()
    if valid(CLASH_SLOWMO.worldSettings) then return CLASH_SLOWMO.worldSettings end
    CLASH_SLOWMO.worldSettings = nil
    local controller = safe(UEHelpers.GetPlayerController)
    if not valid(controller) then return nil end
    local world = safe(function() return controller:GetWorld() end)
    if not valid(world) then return nil end
    local level = readField(world, "PersistentLevel")
    if not valid(level) then return nil end
    local ws = readField(level, "WorldSettings")
    if valid(ws) then CLASH_SLOWMO.worldSettings = ws end
    return CLASH_SLOWMO.worldSettings
end

function CLASH_SLOWMO.restore()
    CLASH_SLOWMO.active = false
    local ws = CLASH_SLOWMO.getWorldSettings()
    if not valid(ws) then return end
    local cur = readNumber(ws, "DemoPlayTimeDilation")
    -- Only take back our own value; leave a factor the game or another mod set.
    if cur ~= nil and math.abs(cur - Settings.ClashSlowmoSpeed) < 0.001 then
        safe(function() ws.DemoPlayTimeDilation = 1.0 end)
    end
end

function CLASH_SLOWMO.frameStep()
    if not CLASH_SLOWMO.active then return false end
    local ws = CLASH_SLOWMO.getWorldSettings()
    if not valid(ws) then
        CLASH_SLOWMO.active = false
        return false
    end
    if os.clock() >= CLASH_SLOWMO.endsAt then
        CLASH_SLOWMO.restore()
        return false
    end
    local cur = readNumber(ws, "DemoPlayTimeDilation")
    if cur ~= nil and math.abs(cur - Settings.ClashSlowmoSpeed) > 0.001 then
        safe(function() ws.DemoPlayTimeDilation = Settings.ClashSlowmoSpeed end)
    end
    return false
end

function CLASH_SLOWMO.start()
    if not Settings.ClashSlowmoEnabled or CLASH_SLOWMO.broken then return end
    local ws = CLASH_SLOWMO.getWorldSettings()
    if not valid(ws) then return end
    local ok = pcall(function() ws.DemoPlayTimeDilation = Settings.ClashSlowmoSpeed end)
    local after = readNumber(ws, "DemoPlayTimeDilation")
    if not ok or after == nil or math.abs(after - Settings.ClashSlowmoSpeed) > 0.001 then
        CLASH_SLOWMO.broken = true
        logError("clash slowmo: world factor write rejected")
        return
    end
    CLASH_SLOWMO.active = true
    CLASH_SLOWMO.endsAt = os.clock() + Settings.ClashSlowmoSeconds
    if CLASH_SLOWMO.logs < 12 then
        CLASH_SLOWMO.logs = CLASH_SLOWMO.logs + 1
        LogEvent("clash slowmo: %.2f x %.2f s", Settings.ClashSlowmoSpeed, Settings.ClashSlowmoSeconds)
    end
end

local function GrantCharges(reason, isBlock)
    local now = os.clock()
    if now - lastClash < Settings.CooldownSeconds then
        return
    end
    lastClash = now
    if isBlock then
        -- A block also consumes a deflect frame, but it is not a clash. It used to grant the full
        -- reward here, which made repeated blocks light the blade and refresh the free attacks.
        LogEvent("clash skipped (block): %s", reason)
        TryBreakClash(true, reason)
        return
    end
    charges = Settings.Charges
    LogEvent("clash (%s): %d free heavy attacks", reason, charges)
    TryFire()
    TryInvulnerable()
    TORNADO.combo = math.min(TORNADO.combo + 1, Settings.TornadoClashMax)
    LogEvent("tornado combo: %d/%d", TORNADO.combo, Settings.TornadoClashMax)
    TryBreakClash(false, reason)
    CLASH_SLOWMO.start()
    TORNADO.topTier()
end

---------------------------------------------------------------------------------------------------------------------
-- Temporary probes: montage/ability names and block/clash split
---------------------------------------------------------------------------------------------------------------------

local montageHooked = false
local montageLogs = 0

local function TryMontageHook()
    if montageHooked then
        return
    end
    local ok, err = pcall(RegisterHook, "/Script/Engine.AnimInstance:Montage_Play", function(context, montage)
        local self = Unwrap(context)
        local owner = safe(function() return self:GetOwningActor() end)
        if not valid(owner) then
            owner = safe(function() return self:GetOuter() end)
        end
        local ownerName = valid(owner) and FullName(owner) or "?"
        local anim = Unwrap(montage)
        local animName = valid(anim) and FullName(anim) or tostring(anim)
        if os.clock() <= breakWatchUntil then
            if breakWatchName and ownerName == breakWatchName then
                LogEvent("break watch: montage %s at +%.2f s", animName, os.clock() - breakStartedAt)
            end
            return
        end
        if not ownerName:find("BP_Renewal_Hun", 1, true) then
            return
        end
        if montageLogs >= 200 then
            return
        end
        montageLogs = montageLogs + 1
        LogEvent("ga probe: montage %s", animName)
    end)
    montageHooked = true
    LogEvent("ga probe: montage hook ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err)))
end

local CHIREN_GA_BASES = {
    "GA_Hun_ChiRen_A", "GA_Hun_ChiRen_AA", "GA_Hun_ChiRen_AAA", "GA_Hun_ChiRen_AAAA",
    "GA_Hun_ChiRen_AAAAB", "GA_Hun_ChiRen_AAAABB", "GA_Hun_ChiRen_AAAB", "GA_Hun_ChiRen_AAABB",
    "GA_Hun_ChiRen_AAB", "GA_Hun_ChiRen_AABB", "GA_Hun_ChiRen_AB", "GA_Hun_ChiRen_ABB",
    "GA_Hun_ChiRen_B", "GA_Hun_ChiRen_BB", "GA_Hun_ChiRen_BBB", "GA_Hun_ChiRen_BD",
    "GA_Hun_ChiRen_BSup", "GA_Hun_ChiRen_C", "GA_Hun_ChiRen_SWT",
}
local chirenGaTried = false

local function HookChiRenGas()
    if chirenGaTried then
        return
    end
    chirenGaTried = true
    local hooked = 0
    for _, base in ipairs(CHIREN_GA_BASES) do
        local path = "/PBZCombatAsset/ActorData/Players/Hun/Abilities/LongBlade/ChiRen/" ..
            base .. "." .. base .. "_C"
        local class = safe(LoadAsset, path)
        if not valid(class) then
            local found = safe(FindAllOf, base .. "_C")
            if found and found[1] and valid(found[1]) then
                class = safe(function() return found[1]:GetClass() end)
            end
        end
        if valid(class) then
            local classPath = FullName(class):gsub("^Class ", "")
            local ok = pcall(RegisterHook, classPath .. ":K2_ActivateAbility", function(context)
                local self = Unwrap(context)
                LogEvent("ga probe: %s on %s", base, FullName(self))
            end)
            if ok then
                hooked = hooked + 1
            end
        end
    end
    LogEvent("ga probe: hooked %d/%d ChiRen abilities", hooked, #CHIREN_GA_BASES)
end

local function TryBlockHook()
    if blockHookState.hooked or blockHookState.attempts >= 20 then
        return
    end
    -- The Impact UFunction lives on the stance action class itself, not on the owning ability that
    -- FindAllOf happens to return first (GA_Hun_Long_Stance_C has no On Impact). Use the fixed class
    -- path, matching the heavenorhell reference that hooks this successfully.
    local ok, err = pcall(RegisterHook,
        "/PBZDeflectSystem/Abilities/BP_StanceAction_Base_Player.BP_StanceAction_Base_Player_C:On Impact",
        function()
            lastBlockImpactAt = os.clock()
        end)
    if ok then
        blockHookState.hooked = true
        LogEvent("block probe: hooked On Impact")
    else
        blockHookState.attempts = blockHookState.attempts + 1
        if blockHookState.attempts >= 20 then
            logError("block probe: hook failed after 20 tries: " .. tostring(err))
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Clash trigger: player's DeflectComponent consumes a deflect frame
---------------------------------------------------------------------------------------------------------------------

local stanceProbeLogs = 0

-- A held block keeps the stance action in its deflect state; a weapon clash happens while attacking,
-- so the stance stays out of it. The old "any heavy in the last 1.5 s" guess dropped most clashes.
local function ReadStanceState()
    local stances = safe(FindAllOf, "BP_StanceAction_Base_Player_C")
    if not stances or #stances == 0 then
        return nil, "no stance instance"
    end
    local parts = {}
    for _, stance in ipairs(stances) do
        if valid(stance) then
            local inDeflect = readField(stance, "In Deflect")
            local inCombo = readField(stance, "In Combo")
            parts[#parts + 1] = string.format("deflect=%s combo=%s", tostring(inDeflect),
                tostring(inCombo))
            if inDeflect == true then
                return true, table.concat(parts, "; ")
            end
        end
    end
    return false, table.concat(parts, "; ")
end

local function TryDeflectHook()
    if hookedDeflect or not Settings.TriggerOnDeflect then return end
    local components = safe(FindAllOf, "DeflectComponent")
    if not components or #components == 0 then return end
    local classPath = classPathOf(components[1])
    if not classPath then return end
    local ok, err = pcall(RegisterHook, classPath .. ":ConsumeReceivedFrame", function(context)
        local self = Unwrap(context)
        local name = FullName(self)
        if not name:find("BP_Renewal_Hun") then
            return
        end
        local attackAge = os.clock() - lastAttackAt
        local blockAge = os.clock() - lastBlockImpactAt
        local inDeflect, stanceText = ReadStanceState()
        -- The stance On Impact hook fires for a block/parry but not for a weapon clash, so a fresh
        -- block impact wins over the attack-age guess: a held block followed by an attack press was
        -- being credited as a clash and interrupted the boss.
        local isBlock
        if blockAge <= 0.5 then
            isBlock = true
        elseif attackAge <= 0.8 then
            isBlock = false
        elseif inDeflect == true then
            isBlock = true
        else
            isBlock = false
        end
        if stanceProbeLogs < 40 then
            stanceProbeLogs = stanceProbeLogs + 1
            LogEvent("clash stance: attackAge=%.2f inDeflect=%s isBlock=%s [%s]",
                attackAge, tostring(inDeflect), tostring(isBlock), stanceText)
        end
        GrantCharges("deflect frame consumed", isBlock)
    end)
    if ok then
        hookedDeflect = true
        LogEvent("hooked ConsumeReceivedFrame")
    else
        logError("deflect hook: " .. tostring(err))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Heavy attack cost
---------------------------------------------------------------------------------------------------------------------

local function ShachiSet(value)
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return false
    end
    local set = readField(pawn, "AttributeSetBase")
    if not valid(set) then
        return false
    end
    local data = readField(set, "Shachi")
    if data == nil then
        return false
    end
    return pcall(function() data.CurrentValue = value end)
end

-- The game does not read the ability's Shachi Cost fields nor the HeavyAttack_ShachiCostReduction
-- attribute (both were written successfully and changed nothing), so the cost is taken back after it is
-- charged: watch the bar for about a second and return the part HeavyCostScale keeps. A newer activation
-- cancels the watchers of the previous one, and a rise (regen) just moves the baseline.
local refundToken = 0

local function ScheduleShachiRefund(before)
    refundToken = refundToken + 1
    local token = refundToken
    local expected = before
    for _, delay in ipairs({ 80, 160, 260, 400, 600, 850 }) do
        ExecuteWithDelay(delay, function()
            ExecuteInGameThread(function()
                if token ~= refundToken then
                    return
                end
                local current = PlayerShachi()
                if current == nil then
                    return
                end
                if current < expected - 1 then
                    local spent = expected - current
                    local target = expected - spent * (1.0 - Settings.HeavyCostScale)
                    local written = ShachiSet(target)
                    LogEvent("refund +%dms: spent %.0f, kept %.0f, wrote %s ok=%s", delay, spent,
                        spent * Settings.HeavyCostScale, string.format("%.0f", target), tostring(written))
                    expected = target
                else
                    expected = current
                end
            end)
        end)
    end
end

---------------------------------------------------------------------------------------------------------------------
-- 风回云卷: bullet damage, fire state and cast bookkeeping
---------------------------------------------------------------------------------------------------------------------

local OnTornadoCast, RestoreTornadoBullets

do

local BSUP_BULLET_ROOT = "/PBZCombatAsset/ActorData/Players/Hun/BulletData/LongBlade/ChiRen/"
local BSUP_BULLETS = { "BD_GA_Hun_ChiRen_BSup_01", "BD_GA_Hun_ChiRen_BSup_02" }
-- HP damage only; the enemy-Shachi field (Damage.Attack.Target.AngerDamage) is left vanilla.
local BSUP_DAMAGE_FIELDS = {
    ["Damage.Attack.Target.PhysicalDamage"] = true,
    ["Damage.Attack.Target.ElementDamage"] = true,
}
local tornadoPatch = nil
local tornadoPatchToken = 0

local function EachBulletDamage(asset, callback)
    local damage = safe(function() return asset.DamageData end)
    if damage == nil then return end
    damage:ForEach(function(key, value)
        local tag = safe(function() return key:get() end)
        local name = tag and safe(function() return tag.TagName:ToString() end) or nil
        if name and BSUP_DAMAGE_FIELDS[name] then callback(name, value) end
    end)
end

local function PatchTornadoBullets(factor)
    local entries = {}
    for _, name in ipairs(BSUP_BULLETS) do
        local path = BSUP_BULLET_ROOT .. name .. "." .. name
        local asset = ResolveObject(path)
        if not valid(asset) then
            LogEvent("tornado damage: bullet %s missing", name)
        else
            entries[#entries + 1] = { asset = asset, name = name, changed = {} }
        end
    end
    if #entries ~= #BSUP_BULLETS then
        return nil
    end
    local written = 0
    for _, entry in ipairs(entries) do
        local ok, err = pcall(function()
            EachBulletDamage(entry.asset, function(name, value)
                local original = value:get()
                if type(original) ~= "number" or original <= 0 then
                    LogEvent("tornado damage: %s %s base is %s", entry.name, name, tostring(original))
                    return
                end
                value:set(original * factor)
                local now = value:get()
                if type(now) ~= "number" or math.abs(now - original * factor) > 0.01 then
                    LogEvent("tornado damage: %s %s write failed (%s -> %s)", entry.name, name,
                        tostring(original), tostring(now))
                    return
                end
                entry.changed[name] = original
                written = written + 1
                LogEvent("tornado damage: %s %s %.2f -> %.2f", entry.name, name, original, now)
            end)
        end)
        if not ok then LogEvent("tornado damage: %s scan failed (%s)", entry.name, tostring(err)) end
    end
    if written == 0 then
        LogEvent("tornado damage: no damage field was written")
        return nil
    end
    return { entries = entries, factor = factor, written = written }
end

RestoreTornadoBullets = function(reason)
    local patch = tornadoPatch
    if not patch then return true end
    tornadoPatch = nil
    tornadoPatchToken = tornadoPatchToken + 1
    local pending = 0
    for _, entry in ipairs(patch.entries) do
        if valid(entry.asset) then
            local ok, err = pcall(function()
                EachBulletDamage(entry.asset, function(name, value)
                    local original = entry.changed[name]
                    if original == nil then return end
                    local actual = value:get()
                    if type(actual) ~= "number" then return end
                    if math.abs(actual - original) <= 0.01 then
                        entry.changed[name] = nil
                    elseif math.abs(actual - original * patch.factor) > 0.01 then
                        -- Another writer owns this value now; restoring would clobber it.
                        LogEvent("tornado damage: %s %s changed externally (%.2f), left alone", entry.name,
                            name, actual)
                        entry.changed[name] = nil
                    else
                        value:set(original)
                        local now = value:get()
                        if type(now) == "number" and math.abs(now - original) <= 0.01 then
                            entry.changed[name] = nil
                        else
                            LogEvent("tornado damage: %s %s restore failed (%s)", entry.name, name,
                                tostring(now))
                        end
                    end
                end)
            end)
            if not ok then LogEvent("tornado damage: %s restore scan failed (%s)", entry.name, tostring(err)) end
        end
        for _ in pairs(entry.changed) do pending = pending + 1 end
    end
    LogEvent("tornado damage: restored (%s), pending=%d", reason, pending)
    return pending == 0
end

-- The fire state is a timed GE on the player. The clash fire is short; a tornado cast has to bring
-- the fire to its own duration, extending the running effect when one is already up.
local FIRE_TAG = "CharacterState.AbilityState.ChiRen.Burning"
local FIRE_OBJECT_PATHS = {
    tags = "/Script/GameplayTags.Default__BlueprintGameplayTagLibrary",
    gameplay = "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary",
    utils = "/Script/PBZCombatAsset.Default__PBZCombatUtils",
    pbz = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary",
}
local fireObjects = nil

local function FireObjects()
    if fireObjects then return fireObjects end
    local objects = {}
    for key, path in pairs(FIRE_OBJECT_PATHS) do
        local object = safe(StaticFindObject, path)
        if valid(object) then objects[key] = object end
    end
    if not (objects.tags and objects.gameplay and objects.pbz) then
        return nil
    end
    fireObjects = objects
    return objects
end

local function ActiveFire()
    local pawn, abilities = PlayerAbilities()
    if not valid(pawn) or not valid(abilities) then return nil, nil, nil, nil end
    local objects = FireObjects()
    if not objects then
        LogEvent("tornado burn: script libraries unavailable")
        return nil, nil, nil, nil
    end
    local tag = safe(function() return objects.pbz:ConvertStringToGameplayTag(FIRE_TAG) end)
    local container = tag and safe(function() return objects.tags:MakeGameplayTagContainerFromTag(tag) end) or nil
    if container == nil then
        LogEvent("tornado burn: could not build the fire tag container")
        return nil, nil, nil, nil
    end
    local matches = safe(function() return abilities:GetActiveEffectsWithAllTags(container) end)
    if type(matches) ~= "table" then
        LogEvent("tornado burn: active effect query returned %s", type(matches))
        return nil, objects, pawn, abilities
    end
    if #matches == 0 then
        return nil, objects, pawn, abilities
    end
    if #matches > 1 then
        LogEvent("tornado burn: %d active fire effects, using the first", #matches)
    end
    local entry = matches[1]
    local value = type(entry) == "userdata" and safe(function() return entry:get() end) or entry
    local handle = value and safe(function() return value.Handle end) or nil
    if type(handle) ~= "number" or handle < 0 then
        LogEvent("tornado burn: queried fire handle is %s", tostring(handle))
        return nil, objects, pawn, abilities
    end
    return { Handle = handle }, objects, pawn, abilities
end

local function ExtendFire(seconds)
    local handle, objects, pawn, abilities = ActiveFire()
    if not handle or not objects or not valid(pawn) or not valid(abilities) then
        LogEvent("tornado burn: active fire handle unavailable")
        return false
    end
    local lib = objects.gameplay
    local remaining = safe(function() return lib:GetActiveGameplayEffectRemainingDuration(pawn, handle) end)
    if type(remaining) ~= "number" or remaining <= 0 or remaining >= math.huge then
        LogEvent("tornado burn: existing duration unreadable (%s)", tostring(remaining))
        return false
    end
    if remaining >= seconds - 0.2 then
        LogEvent("tornado burn: already burning %.1f s, no extension", remaining)
        return true
    end
    local total = safe(function() return lib:GetActiveGameplayEffectTotalDuration(handle) end)
    if type(total) ~= "number" or total < remaining - 0.2 or total >= math.huge then
        LogEvent("tornado burn: total duration unreadable (%s)", tostring(total))
        return false
    end
    local utils = objects.utils
    if not valid(utils) then
        LogEvent("tornado burn: PBZCombatUtils unavailable")
        return false
    end
    local requested = total + seconds - remaining
    local writeOk, writeErr = pcall(function() utils:SetActiveGEDuration(abilities, handle, requested) end)
    local now = safe(function() return lib:GetActiveGameplayEffectRemainingDuration(pawn, handle) end)
    if writeOk and type(now) == "number" and math.abs(now - seconds) > 0.25 then
        -- The first write can land a frame late; one corrective write closes the gap.
        pcall(function() utils:SetActiveGEDuration(abilities, handle, requested + seconds - now) end)
        now = safe(function() return lib:GetActiveGameplayEffectRemainingDuration(pawn, handle) end)
    end
    if not writeOk or type(now) ~= "number" or math.abs(now - seconds) > 0.3 then
        LogEvent("tornado burn: extension failed (remaining=%s%s)", tostring(now),
            writeOk and "" or (" err=" .. tostring(writeErr)))
        return false
    end
    fireAppliedAt = fireAppliedAt or os.clock()
    fireUntil = os.clock() + now
    fireAskedSeconds = now
    LogEvent("tornado burn: extended %.1f -> %.1f s", remaining, now)
    return true
end

local function ApplyTornadoBurn(seconds)
    if seconds <= 0 then return end
    local _, abilities = PlayerAbilities()
    if not valid(abilities) then
        LogEvent("tornado burn: no ability system")
        return
    end
    local count = safe(function() return abilities:GetGameplayTagCount({ TagName = BURNING_FNAME }) end)
    if count and count > 0 then
        if not ExtendFire(seconds) then
            LogEvent("tornado burn: already burning, extension skipped")
        end
        return
    end
    local ge = ResolveFireGe()
    if not ge then
        LogEvent("tornado burn: no FireStateGE")
        return
    end
    if ApplyTimedGe(abilities, ge, seconds) then
        fireAppliedAt = os.clock()
        fireUntil = fireAppliedAt + seconds
        fireAskedSeconds = seconds
        LogEvent("tornado burn: applied %.1f s", seconds)
    end
end

local tornadoCastAt = nil
local tornadoCastAbility = nil
local tornadoCastInvuln = 0

OnTornadoCast = function(self, freeAttack)
    local _, abilities = PlayerAbilities()
    local tier = BladeBuffTier(abilities)
    local streak = TORNADO.combo
    -- The second cast of a double cast has no fresh streak; reuse the first cast's factor.
    local factor, reused = nil, false
    if streak < Settings.TornadoClashMin and TORNADO.followup and
        os.clock() - TORNADO.followup.at <= TORNADO.followupSeconds then
        factor = TORNADO.followup.factor
        reused = true
        TORNADO.followup = nil
    else
        local stacks = math.max(Settings.TornadoClashMin, math.min(streak, Settings.TornadoClashMax))
        factor = stacks * Settings.TornadoDamageScale
        TORNADO.followup = { factor = factor, at = os.clock() }
    end
    tornadoCastAt = os.clock()
    tornadoCastAbility = valid(self) and self:GetAddress() or nil
    tornadoCastInvuln = Settings.TornadoInvulnSeconds
    LogEvent("tornado cast: streak=%d tier=%d multiplier=x%.2f free=%s%s", streak, tier, factor,
        tostring(freeAttack), reused and " followup" or "")
    NoteAction(string.format("GA_Hun_ChiRen_BSup_C x%.2f%s", factor, reused and " followup" or ""))
    TORNADO.combo = 0

    if Settings.TornadoInvulnSeconds > 0 then
        LogEvent("tornado invuln: %.1f s", Settings.TornadoInvulnSeconds)
        TryInvulnerable(Settings.TornadoInvulnSeconds)
    end

    if tornadoPatch then RestoreTornadoBullets("next-cast") end
    local patch = PatchTornadoBullets(factor)
    if patch then
        tornadoPatch = patch
        tornadoPatchToken = tornadoPatchToken + 1
        local token = tornadoPatchToken
        ExecuteWithDelay(math.floor(Settings.TornadoDamageSeconds * 1000), function()
            ExecuteInGameThread(function()
                if token == tornadoPatchToken and tornadoPatch == patch then
                    if tornadoCastAt then
                        LogEvent("tornado end: not seen after %.1f s; restoring by timeout",
                            os.clock() - tornadoCastAt)
                        tornadoCastAt = nil
                        tornadoCastAbility = nil
                    end
                    RestoreTornadoBullets("timeout")
                end
            end)
        end)
    end

    ApplyTornadoBurn(Settings.TornadoBurnSeconds)
end

end

local costScaleLogged = false
local heavyActivateLogs = 0

local function HeavyActivate(name, self, classPath)
    if not valid(self) then return end
        lastAttackAt = os.clock()
        NoteAction(name)
        if heavyActivateLogs < 200 then
            heavyActivateLogs = heavyActivateLogs + 1
            LogEvent("heavy activate: %s", name)
        end
        if name == "GA_Hun_ChiRen_BSup_C" then
            local castOk, castErr = pcall(OnTornadoCast, self, charges > 0)
            if not castOk then logError("tornado cast: " .. tostring(castErr)) end
        elseif name == "GA_Hun_ChiRen_C_C" then
            -- The paid whirlwind variant also gets the whirlwind invulnerability.
            if Settings.TornadoInvulnSeconds > 0 then
                LogEvent("tornado invuln: %.1f s (C)", Settings.TornadoInvulnSeconds)
                TryInvulnerable(Settings.TornadoInvulnSeconds)
            end
        end
        local original = origCosts[classPath]
        if not original then
            original = {
                cost = readNumber(self, "Shachi Cost"),
                min = readNumber(self, "Shachi Cost Min"),
            }
            origCosts[classPath] = original
        end
        local before = PlayerShachi()
        local freeAttack = charges > 0
        if charges > 0 then
            self["Shachi Cost"] = 0.0
            self["Shachi Cost Min"] = 0.0
            charges = charges - 1
            LogEvent("free heavy: %s (%d left)", name, charges)
        elseif original.cost ~= nil then
            local scale = Settings.HeavyCostScale
            local cost = original.cost * scale
            local min = original.min and original.min * scale or nil
            self["Shachi Cost"] = cost
            if min ~= nil then
                self["Shachi Cost Min"] = min
            end
            if not costScaleLogged then
                costScaleLogged = true
                LogEvent("heavy cost scale %.2f on %s: cost %s -> %s, min %s -> %s", scale, classPath,
                    tostring(original.cost), tostring(cost), tostring(original.min), tostring(min))
            end
        end
        if before ~= nil then
            for _, delay in ipairs({ 400 }) do
                ExecuteWithDelay(delay, function()
                    ExecuteInGameThread(function()
                        local after = PlayerShachi()
                        local consumed = valid(self) and readNumber(self, "Actual Shachi Consumed") or nil
                        if after ~= nil then
                            LogEvent("heavy cost +%dms: %.0f -> %.0f (delta %.0f) consumed=%s", delay, before,
                                after, before - after, tostring(consumed))
                        end
                    end)
                end)
            end
        end
        if before ~= nil and not freeAttack then
            ScheduleShachiRefund(before)
        end
end

local function HookHeavy(name)
    if hookedHeavy[name] then return end
    local objects = safe(FindAllOf, name)
    if not objects or #objects == 0 then return end
    local classPath = classPathOf(objects[1])
    if not classPath then return end
    hookedHeavy[name] = true
    local ok, err = pcall(RegisterHook, classPath .. ":K2_ActivateAbility", function(context)
        HeavyActivate(name, Unwrap(context), classPath)
    end)
    if ok then
        LogEvent("hooked heavy %s", name)
    else
        logError("heavy hook " .. name .. ": " .. tostring(err))
        if name == "GA_Hun_ChiRen_B_C" or name == "GA_Hun_ChiRen_BBB_C" then
            local classObj = safe(function() return objects[1]:GetClass() end)
            local parent = valid(classObj) and readField(classObj, "SuperStruct") or nil
            if valid(parent) then
                local parentPath = safe(function()
                    return parent:GetFullName():gsub("^Class ", "")
                end)
                if parentPath then
                    local pOk, pErr = pcall(RegisterHook, parentPath .. ":K2_ActivateAbility",
                        function(context)
                            local self = Unwrap(context)
                            if valid(self) and FullName(self):find("GA_Hun_ChiRen_", 1, true) then
                                HeavyActivate(name, self, classPath)
                            end
                        end)
                    LogEvent("heavy probe %s parent=%s hook ok=%s%s", name, parentPath,
                        tostring(pOk), pOk and "" or (" err=" .. tostring(pErr)))
                    if not pOk then
                        -- BP_B_Base_C / BP_BBB_Base_C are empty; the event graph is one level up.
                        local grand = readField(parent, "SuperStruct")
                        if valid(grand) then
                            local grandPath = safe(function()
                                return grand:GetFullName():gsub("^Class ", "")
                            end)
                            if grandPath then
                                local gOk, gErr = pcall(RegisterHook,
                                    grandPath .. ":K2_ActivateAbility", function(context)
                                        local self = Unwrap(context)
                                        if valid(self) and FullName(self):find(name, 1, true) then
                                            HeavyActivate(name, self, classPath)
                                        end
                                    end)
                                LogEvent("heavy probe %s grandparent=%s hook ok=%s%s", name, grandPath,
                                    tostring(gOk), gOk and "" or (" err=" .. tostring(gErr)))
                            end
                        end
                    end
                end
            else
                LogEvent("heavy probe %s has no SuperStruct", name)
            end
        end
    end
    if name == "GA_Hun_ChiRen_BSup_C" then
        local okEnd, errEnd = pcall(RegisterHook, classPath .. ":K2_OnEndAbility", function(context)
            local ability = Unwrap(context)
            local address = valid(ability) and ability:GetAddress() or nil
            if tornadoCastAt and (tornadoCastAbility == nil or address == tornadoCastAbility) then
                LogEvent("tornado end: %.2f s (invuln asked %.1f s)", os.clock() - tornadoCastAt,
                    tornadoCastInvuln)
                tornadoCastAt = nil
                tornadoCastAbility = nil
            end
            local restored, restoreErr = pcall(RestoreTornadoBullets, "cast-end")
            if not restored then logError("tornado restore: " .. tostring(restoreErr)) end
        end)
        LogEvent("tornado damage: end hook ok=%s%s", tostring(okEnd),
            okEnd and "" or (" err=" .. tostring(errEnd)))
    end
end


local hookedAttack = {}
local attackHookLogs = 0

local function HookAttack(name)
    if hookedAttack[name] then
        return
    end
    local objects = safe(FindAllOf, name)
    if not objects or #objects == 0 then
        return
    end
    local classPath = classPathOf(objects[1])
    if not classPath then
        return
    end
    hookedAttack[name] = true
    local ok, err = pcall(RegisterHook, classPath .. ":K2_ActivateAbility", function()
        lastAttackAt = os.clock()
        NoteAction(name)
        if attackHookLogs < 30 then
            attackHookLogs = attackHookLogs + 1
            LogEvent("attack activate: %s", name)
        end
    end)
    if ok then
        LogEvent("hooked attack %s", name)
    else
        logError("attack hook " .. name .. ": " .. tostring(err))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Block-parry perfect window
---------------------------------------------------------------------------------------------------------------------

-- This is the block parry's perfect window, not the weapon clash's: the clash has no global window field, its
-- frames live in each attack asset. Every difficulty has its own copy of the combat config, so all are written.
local deflectWindowTuned = false

local function TuneDeflectWindow()
    if deflectWindowTuned or Settings.DeflectWindowFrames <= 0 then return end
    local configs = safe(FindAllOf, COMBAT_CONFIG_CLASS)
    if not configs or #configs == 0 then return end
    deflectWindowTuned = true
    for _, config in ipairs(configs) do
        if valid(config) then
            LogEvent("deflect window on %s", FullName(config))
            WriteNumber(config, "Deflect Perfect Window Frames", Settings.DeflectWindowFrames)
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Weapon clash window (ChiRen heavy -> light counter)
---------------------------------------------------------------------------------------------------------------------

-- The clash has no global field: its window is the duration of the single GAA_DeflectFrame_C row in the
-- counter ability's private Main timeline, written before the native timeline autoplay starts.
-- Vanilla is 0.350606441 s, about 10.5 frames at 30 fps. Only the ChiRen blade is changed; any other
-- long blade gets the vanilla value back.
local CLASH_COUNTER_CLASS = "GA_Hun_Long_Counter_C"
local CLASH_DEFLECT_CLASS = "GAA_DeflectFrame_C"
local CLASH_ABILITY_BASE =
    "/MagCombatAbilities/Abilities/BP_AbilityBase.BP_AbilityBase_C:K2_ActivateAbility"
local CLASH_VANILLA_SECONDS = 0.35060644149780273
local CLASH_MIN_SECONDS, CLASH_MAX_SECONDS = 0.01, 3.0
local CLASH_FRAME_RATE = 30
local CHIREN_WEAPON_PATH =
    "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Long/Weapon_Hun_ChiRen.Weapon_Hun_ChiRen"
local CHIREN_EQUIP_TAG = "Weapon.Type.LongBlade.ChiRen"

local clashWindowHooked = false
local clashWindowRecords = {}
local clashWindowLogs = 0
local chirenWeaponAsset = nil

-- The ChiRen switch attack is GA_Hun_ChiRen_SWT_C (confirmed by the activation sequence: a weapon
-- swap fires it alone). Its single attack box already allows deflect, but Branch=None and a 0.100 s
-- window differ from BaiYing's Branch=Normal / 0.241 s. One table keeps this to a single local.
local SWITCH_BLOCK = {
    ability = "GA_Hun_ChiRen_SWT_C",
    box = "LGAAction_DurationBulletWithDeflect",
    logs = 0,
    activations = 0,
}

-- The switch attack has no GAA_DeflectFrame_C row (its only deflect rides on an attack box at
-- start=0.858 s), so the first 0.858 s of the move cannot parry. Injecting a standalone deflect row
-- at start=0 gives it a native counter window like GA_Hun_Long_Counter_C. Recipe from Infernal Rouge
-- Unbound's iru_clash.lua; TrackIndex 15 is the counter's deflect track (verify in game).
local SWITCH_DEFLECT = {
    path = "/PBZDeflectSystem/Actions/GAA_DeflectFrame.GAA_DeflectFrame_C",
    guidA = 0x43484952, guidB = 0x454E5357, track = 15,
    broken = false, logs = 0, frameClass = nil,
}

-- The probe body is defined after ProbeLog so it can share the probe log budget.
local ProbeSwitchActivate

-- nil = unknown: the weapon asset or its tag table is not loaded yet.
local function ChiRenEquipped(ability)
    if not valid(chirenWeaponAsset) then
        chirenWeaponAsset = safe(StaticFindObject, CHIREN_WEAPON_PATH)
    end
    if not valid(chirenWeaponAsset) then return nil end
    local asc = safe(function() return ability:GetAbilitySystemComponentFromActorInfo() end)
    if not valid(asc) then return nil end
    local tags = readField(chirenWeaponAsset, "Weapon Equip Tags")
    if tags == nil then return nil end
    local found, active = false, false
    safe(function()
        tags.GameplayTags:ForEach(function(_, ref)
            local tag = ref:get()
            local text = safe(function() return tag.TagName:ToString() end)
            if text == CHIREN_EQUIP_TAG then
                found = true
                active = asc:HasMatchingGameplayTag(tag) == true
            end
        end)
    end)
    if not found then return nil end
    return active
end

---------------------------------------------------------------------------------------------------------------------
-- Keep ChiRen blade stacks across a weapon switch
---------------------------------------------------------------------------------------------------------------------

-- The three tiers are gameplay tags (Buff.Lv1/Lv2/Lv3), not a field on the charge object. The tag
-- library is reached through its Default__ object: static methods on the class object are not
-- callable in this build. HasMatchingGameplayTag is already proven by ChiRenEquipped.
local SWITCH_KEEP = {
    buff = "CharacterState.AbilityState.Long.Buff",
    tagLibPath = "/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary",
    upgradeRoot = "/PBZCombatAsset/ActorData/Players/Hun/Weapon/Long/UpgradeData/",
    increaseName = "GE_Weapon_Long_BuffIncreaseLevel",
    lib = nil,
    tags = {},
    increase = nil,
    lastTier = nil,
    lastTickAt = 0,
    wasEquipped = nil,
    snap = nil,
    frozen = nil,
    backAt = 0,
    logs = 0,
    tierLogs = 0,
    apiLogged = false,
}

-- Burning flag only (1/0, nil when the tag API is unavailable). The fire effect itself is
-- infinite-duration, so its remaining time carries no information; restore uses FireSeconds.
local function KeepFire(asc)
    local count = safe(function() return asc:GetGameplayTagCount({ TagName = BURNING_FNAME }) end)
    if count == nil then return nil end
    return count > 0 and 1 or 0
end

-- Returns the current tier 0-3, or nil when the tag API is unavailable (so a caller can tell
-- "no stacks" apart from "cannot read").
local function KeepTier(asc)
    if not valid(asc) then return nil end
    local st = SWITCH_KEEP
    if not valid(st.lib) then
        st.lib = safe(StaticFindObject, st.tagLibPath)
    end
    if not valid(st.lib) then
        if not st.apiLogged then
            st.apiLogged = true
            logError("switch keep: tag library not found " .. st.tagLibPath)
        end
        return nil
    end
    for tier = 1, 3 do
        local name = st.buff .. ".Lv" .. tier
        if st.tags[name] == nil then
            local tag = safe(function() return st.lib:ConvertStringToGameplayTag(name) end)
            if tag == nil then
                if not st.apiLogged then
                    st.apiLogged = true
                    logError("switch keep: ConvertStringToGameplayTag failed for " .. name)
                end
                return nil
            end
            st.tags[name] = tag
        end
    end
    for tier = 3, 1, -1 do
        local tag = st.tags[st.buff .. ".Lv" .. tier]
        local has = safe(function() return asc:HasMatchingGameplayTag(tag) end)
        if has == true then return tier end
    end
    return 0
end

-- The ChiRen switch attack fires when swapping BACK to ChiRen; the clear happened earlier when
-- swapping away, so this only marks the return. The sampler overwrites the frozen snapshot.
local function KeepBack(context)
    if not Settings.SwitchKeepStacks then return end
    local ability = Unwrap(context)
    if not valid(ability) then return end
    local className = safe(function() return ability:GetClass():GetFName():ToString() end)
    if className ~= SWITCH_BLOCK.ability then return end
    local st = SWITCH_KEEP
    st.backAt = os.clock()
    if st.logs < 20 then
        st.logs = st.logs + 1
        local f = st.frozen
        LogEvent("switch keep: back to ChiRen, frozen=%s",
            f and string.format("tier=%d fire=%d", f.tier, f.fire) or "nil")
    end
end

-- Runs on the 300 ms sampler. While ChiRen is equipped it keeps a snapshot of the last blade tier
-- and burning remainder; once the weapon swaps away the snapshot is frozen. On swapping back the
-- frozen state is overwritten onto the player: tiers via the native tier-up effect, fire via TryFire
-- with the remembered remainder.
local function KeepTick()
    local st = SWITCH_KEEP
    if not Settings.SwitchKeepStacks then return end
    local now = os.clock()
    if now - st.lastTickAt < 1.0 then return end
    st.lastTickAt = now
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return end
    local asc = readField(pawn, "AbilitySystemComponent")
    if not valid(asc) then return end
    local tier = KeepTier(asc)
    if tier == nil then return end
    if tier ~= st.lastTier then
        if st.tierLogs < 40 then
            st.tierLogs = st.tierLogs + 1
            LogEvent("switch keep: tier %s->%d", tostring(st.lastTier), tier)
        end
        st.lastTier = tier
    end
    local equipped = nil
    if not valid(chirenWeaponAsset) then
        chirenWeaponAsset = safe(StaticFindObject, CHIREN_WEAPON_PATH)
    end
    if valid(chirenWeaponAsset) then
        local equipTags = readField(chirenWeaponAsset, "Weapon Equip Tags")
        if equipTags ~= nil then
            local found, active = false, false
            safe(function()
                equipTags.GameplayTags:ForEach(function(_, ref)
                    local tag = ref:get()
                    local text = safe(function() return tag.TagName:ToString() end)
                    if text == CHIREN_EQUIP_TAG then
                        found = true
                        active = asc:HasMatchingGameplayTag(tag) == true
                    end
                end)
            end)
            if found then equipped = active end
        end
    end
    local fire = KeepFire(asc)
    if equipped == true then
        if tier > 0 then
            st.snap = {
                tier = tier,
                fire = fire or 0,
                at = now,
            }
        elseif st.snap and fire ~= nil and fire ~= 0 then
            st.snap.fire = fire
            st.snap.at = now
        end
    elseif equipped == false and st.wasEquipped == true and st.snap then
        st.frozen = st.snap
        if st.logs < 20 then
            st.logs = st.logs + 1
            LogEvent("switch keep: frozen tier=%d fire=%d", st.frozen.tier, st.frozen.fire)
        end
    end
    st.wasEquipped = equipped
    if st.backAt == 0 or now - st.backAt > 3.0 then return end
    local snap = st.frozen
    if snap == nil or now - snap.at > 60.0 then
        st.frozen = nil
        st.backAt = 0
        return
    end
    local before = tier
    if tier < snap.tier then
        local passive = nil
        local passives = safe(FindAllOf, "GA_Hun_ChiRen_Passive_C")
        if passives then
            for _, p in ipairs(passives) do
                if valid(p) then
                    local isActive = safe(function() return p.bIsActive end)
                    local owner = safe(function() return p:GetAvatarActorFromActorInfo() end)
                    local same = valid(owner) and safe(function()
                        return owner:GetAddress() == pawn:GetAddress()
                    end)
                    if isActive == true and same == true then
                        passive = p
                        break
                    end
                end
            end
        end
        if not valid(st.increase) then
            local path = st.upgradeRoot .. st.increaseName .. "." .. st.increaseName .. "_C"
            st.increase = safe(StaticFindObject, path)
            if not valid(st.increase) then
                safe(LoadAsset, path)
                st.increase = safe(StaticFindObject, path)
            end
        end
        if not valid(passive) or not valid(st.increase) then
            if st.logs < 20 then
                st.logs = st.logs + 1
                logError(string.format("switch keep: cannot restore to %d (passive=%s ge=%s)",
                    snap.tier, tostring(valid(passive)), tostring(valid(st.increase))))
            end
        else
            before = KeepTier(asc) or 0
            for _ = before + 1, snap.tier do
                local ok = pcall(function() passive:BP_ApplyGameplayEffectToOwner(st.increase, 1, 1) end)
                local after = KeepTier(asc)
                if not ok or after == nil or after <= before then break end
                before = after
            end
        end
    end
    if snap.fire ~= 0 and (KeepFire(asc) or 0) == 0 then
        TryFire(true, Settings.FireSeconds)
    end
    if st.logs < 20 then
        st.logs = st.logs + 1
        LogEvent("switch keep: restored tier %d->%d fire %d (snap tier=%d fire=%d)",
            tier, before, snap.fire, snap.tier, snap.fire)
    end
    st.frozen = nil
    st.snap = nil
    st.backAt = 0
end

-- Rides the same ability-base hook as the clash window so no second base hook is installed, and
-- writes in the same pre-ActivateAbility slot that made the clash window land before bAutoPlay.
local function TuneSwitchAttack(context)
    if not Settings.SwitchAttackBlock then return end
    local ability = Unwrap(context)
    if not valid(ability) then return end
    local className = safe(function() return ability:GetClass():GetFName():ToString() end)
    if className ~= SWITCH_BLOCK.ability then return end
    local timeline = readField(ability, "Main")
    if not valid(timeline) then return end
    local row, box, count = nil, nil, 0
    safe(function()
        timeline.Actions:ForEach(function(_, ref)
            local candidate = ref:get()
            local action = readField(candidate, "Action")
            if valid(action) and FullName(action):find(SWITCH_BLOCK.box, 1, true) then
                row, box, count = candidate, action, count + 1
            end
        end)
    end)
    if count ~= 1 or row == nil then
        if SWITCH_BLOCK.logs < 6 then
            SWITCH_BLOCK.logs = SWITCH_BLOCK.logs + 1
            LogEvent("switch block: expected one attack box, found %d", count)
        end
        return
    end
    local currentBranch = FNameText(readField(box, "Branch"))
    local currentSeconds = readNumber(row, "duration")
    if currentSeconds == nil then
        logError("switch block: the attack box row has no duration")
        return
    end
    local wantedBranch = Settings.SwitchAttackBranch
    local wantedSeconds = currentSeconds
    if Settings.SwitchAttackWindowFrames > 0 then
        wantedSeconds = Settings.SwitchAttackWindowFrames / CLASH_FRAME_RATE
        if wantedSeconds < CLASH_MIN_SECONDS then wantedSeconds = CLASH_MIN_SECONDS end
        if wantedSeconds > CLASH_MAX_SECONDS then wantedSeconds = CLASH_MAX_SECONDS end
    end
    local branchChanged = currentBranch ~= wantedBranch
    local durChanged = math.abs(currentSeconds - wantedSeconds) > 0.000001
    if not branchChanged and not durChanged then return end
    local branchOk, branchAfter = true, currentBranch
    if branchChanged then
        branchOk = pcall(function() box.Branch = FName(wantedBranch, EFindName.FNAME_Add) end)
        branchAfter = FNameText(readField(box, "Branch"))
    end
    local durOk, durAfter = true, currentSeconds
    if durChanged then
        durOk = pcall(function() row.duration = wantedSeconds end)
        durAfter = readNumber(row, "duration") or currentSeconds
    end
    if SWITCH_BLOCK.logs < 12 then
        SWITCH_BLOCK.logs = SWITCH_BLOCK.logs + 1
        LogEvent("switch block: branch %s->%s (ok=%s) dur %.4f->%.4f s / %.1f->%.1f frames (ok=%s)",
            currentBranch, branchAfter, tostring(branchOk), currentSeconds, durAfter,
            currentSeconds * CLASH_FRAME_RATE, durAfter * CLASH_FRAME_RATE, tostring(durOk))
    end
    if branchChanged and branchAfter ~= wantedBranch then
        logError("switch block: branch write rejected " .. currentBranch .. " -> " .. branchAfter)
    end
    if durChanged and math.abs(durAfter - wantedSeconds) > 0.000001 then
        logError(string.format("switch block: duration write rejected %.6f -> %.6f",
            currentSeconds, durAfter))
    end
end

-- Idempotent: finds our GUID-marked row and only retimes it, else constructs and appends one. Runs
-- in the same pre-ActivateAbility slot as the clash window, before the timeline autoplays. Any
-- self-check mismatch disables injection for the session rather than leaving a half-built row.
function SWITCH_DEFLECT.inject(context)
    if not Settings.SwitchDeflectInject or SWITCH_DEFLECT.broken then return end
    local ability = Unwrap(context)
    if not valid(ability) then return end
    local className = safe(function() return ability:GetClass():GetFName():ToString() end)
    if className ~= SWITCH_BLOCK.ability then return end
    local timeline = readField(ability, "Main")
    if not valid(timeline) then
        if SWITCH_DEFLECT.logs < 12 then
            SWITCH_DEFLECT.logs = SWITCH_DEFLECT.logs + 1
            LogEvent("switch deflect: SWT_C has no Main timeline")
        end
        return
    end
    -- SWT_C is ChiRen-only: its activation already means ChiRen is in hand. Do not gate on
    -- ChiRenEquipped here -- the ability's ASC is not bound yet in this pre-ActivateAbility slot,
    -- so that check returned nil and silently skipped every injection.
    local wanted = Settings.SwitchDeflectFrames / CLASH_FRAME_RATE
    if wanted > 0 then
        if wanted < CLASH_MIN_SECONDS then wanted = CLASH_MIN_SECONDS end
        if wanted > CLASH_MAX_SECONDS then wanted = CLASH_MAX_SECONDS end
    end
    local actions = readField(timeline, "Actions")
    if not valid(actions) then
        if SWITCH_DEFLECT.logs < 12 then
            SWITCH_DEFLECT.logs = SWITCH_DEFLECT.logs + 1
            LogEvent("switch deflect: SWT_C Main has no Actions")
        end
        return
    end
    local function findOurs()
        local found
        safe(function()
            actions:ForEach(function(_, ref)
                local row = ref:get()
                local guid = readField(row, "Guid")
                if guid and guid.A == SWITCH_DEFLECT.guidA and guid.B == SWITCH_DEFLECT.guidB then
                    found = row
                end
            end)
        end)
        return found
    end
    local existing = findOurs()
    if existing then
        local current = readNumber(existing, "duration")
        if current == nil or math.abs(current - wanted) < 0.000001 then return end
        local ok = pcall(function() existing.duration = wanted end)
        local after = readNumber(existing, "duration")
        if not ok or after == nil or math.abs(after - wanted) > 0.000001 then
            SWITCH_DEFLECT.broken = true
            logError(string.format("switch deflect: window write rejected %.6f -> %.6f",
                current or -1, after or -1))
            return
        end
        if SWITCH_DEFLECT.logs < 12 then
            SWITCH_DEFLECT.logs = SWITCH_DEFLECT.logs + 1
            LogEvent("switch deflect: window %.2f -> %.2f frames", current * CLASH_FRAME_RATE,
                after * CLASH_FRAME_RATE)
        end
        return
    end
    if wanted <= 0 then return end
    if not valid(SWITCH_DEFLECT.frameClass) then
        SWITCH_DEFLECT.frameClass = ResolveObject(SWITCH_DEFLECT.path)
    end
    if not valid(SWITCH_DEFLECT.frameClass) then
        SWITCH_DEFLECT.broken = true
        logError("switch deflect: deflect frame class not loaded")
        return
    end
    local frame = safe(StaticConstructObject, SWITCH_DEFLECT.frameClass, timeline,
        FName("GAA_DeflectFrame_C_ChiRenSW", EFindName.FNAME_Add))
    if not valid(frame) then
        SWITCH_DEFLECT.broken = true
        logError("switch deflect: could not construct deflect frame")
        return
    end
    local melee = safe(function() return frame["Melee Result"].TagName:ToString() end)
    if melee ~= "Deflect.Result.Perfect" then
        SWITCH_DEFLECT.broken = true
        logError("switch deflect: unexpected Melee Result " .. tostring(melee))
        return
    end
    -- The counter's frame raises blade force through these; the switch attack's must not.
    safe(function() frame["Impact Event"] = { TagName = FName("None", EFindName.FNAME_Add) } end)
    safe(function() frame["Prepare Event"] = { TagName = FName("None", EFindName.FNAME_Add) } end)
    -- Spatial gate and red-light acceptance are settings; the defaults match the shipped frame
    -- (120-degree front cone, no red light). 360 = all directions; RedEye true also parries red.
    safe(function() frame["Deflect Angle"] = Settings.SwitchDeflectAngle end)
    safe(function() frame["Accept Red Eye"] = Settings.SwitchDeflectRedEye end)
    local before = safe(function() return actions:GetArrayNum() end)
    if type(before) ~= "number" then
        SWITCH_DEFLECT.broken = true
        logError("switch deflect: cannot read action count")
        return
    end
    local ok, err = pcall(function()
        actions[before + 1] = {
            StartTime = 0.0, Duration = wanted, TriggerTimeOffset = 0.0, EndTriggerTimeOffset = 0.0,
            Action = frame, TrackIndex = SWITCH_DEFLECT.track,
            Guid = { A = SWITCH_DEFLECT.guidA, B = SWITCH_DEFLECT.guidB, C = 1, D = 0 },
        }
    end)
    local after = safe(function() return actions:GetArrayNum() end)
    local added = findOurs()
    local addedClass = added and safe(function() return added.Action:GetClass():GetFName():ToString() end)
    if not ok or after ~= before + 1 or added == nil or addedClass ~= CLASH_DEFLECT_CLASS then
        SWITCH_DEFLECT.broken = true
        logError(string.format("switch deflect: inject failed (%s; rows %s->%s, action %s)",
            ok and "no error" or tostring(err), tostring(before), tostring(after), tostring(addedClass)))
        if added then safe(function() added.duration = 0 end) end
        return
    end
    if SWITCH_DEFLECT.logs < 12 then
        SWITCH_DEFLECT.logs = SWITCH_DEFLECT.logs + 1
        LogEvent("switch deflect: injected row %d of %d at start=0, %.2f frames (%.4f s), track %d",
            before + 1, after, wanted * CLASH_FRAME_RATE, wanted, SWITCH_DEFLECT.track)
    end
end

local function TuneClashWindow(context)
    if Settings.ProbeSwitchAttack and ProbeSwitchActivate then
        ProbeSwitchActivate(context)
    end
    TuneSwitchAttack(context)
    SWITCH_DEFLECT.inject(context)
    KeepBack(context)
    -- The switch attack is not in ATTACK_CLASSES/HEAVY_CLASSES, so its activation never refreshes
    -- lastAttackAt. Without this the deflect frame we inject can be credited as a held block
    -- (attackAge stale, inDeflect true) and lose the clash reward. Refresh on the base hook: event
    -- driven, no extra polling.
    local switchAbility = Unwrap(context)
    if valid(switchAbility) then
        local switchClass = safe(function() return switchAbility:GetClass():GetFName():ToString() end)
        if switchClass == SWITCH_BLOCK.ability then
            lastAttackAt = os.clock()
        end
    end
    if Settings.ClashWindowFrames <= 0 then return end
    local ability = Unwrap(context)
    if not valid(ability) then return end
    local className = safe(function() return ability:GetClass():GetFName():ToString() end)
    if className ~= CLASH_COUNTER_CLASS then return end
    local timeline = readField(ability, "Main")
    if not valid(timeline) then return end
    local row, count = nil, 0
    safe(function()
        timeline.Actions:ForEach(function(_, ref)
            local candidate = ref:get()
            local action = readField(candidate, "Action")
            if valid(action) and FullName(action):find(CLASH_DEFLECT_CLASS, 1, true) then
                row = candidate
                count = count + 1
            end
        end)
    end)
    if count ~= 1 or row == nil then
        if clashWindowLogs < 6 then
            clashWindowLogs = clashWindowLogs + 1
            LogEvent("clash window: expected one deflect row, found %d", count)
        end
        return
    end
    local current = readNumber(row, "duration")
    if current == nil then
        logError("clash window: the deflect row has no duration")
        return
    end
    local key = tostring(timeline:GetAddress())
    local record = clashWindowRecords[key]
    local base
    if record then
        base = record.base
    elseif math.abs(current - CLASH_VANILLA_SECONDS) < 0.0001 then
        base = CLASH_VANILLA_SECONDS
    else
        base = current
    end
    local equipped = ChiRenEquipped(ability)
    if equipped == nil then return end
    local wanted = equipped and (Settings.ClashWindowFrames / CLASH_FRAME_RATE) or base
    if wanted < CLASH_MIN_SECONDS then wanted = CLASH_MIN_SECONDS end
    if wanted > CLASH_MAX_SECONDS then wanted = CLASH_MAX_SECONDS end
    if math.abs(current - wanted) < 0.000001 then
        clashWindowRecords[key] = { timeline = timeline, base = base }
        return
    end
    local ok = pcall(function() row.duration = wanted end)
    local after = readNumber(row, "duration")
    if not ok or after == nil or math.abs(after - wanted) > 0.000001 then
        logError(string.format("clash window: write rejected %.6f -> %.6f", current, wanted))
        return
    end
    clashWindowRecords[key] = { timeline = timeline, base = base }
    if clashWindowLogs < 12 then
        clashWindowLogs = clashWindowLogs + 1
        LogEvent("clash window %s: %.2f -> %.2f frames (%.6f -> %.6f s)", className,
            current * CLASH_FRAME_RATE, after * CLASH_FRAME_RATE, current, after)
    end
end

local function TryClashWindowHook()
    if clashWindowHooked then return end
    if Settings.ClashWindowFrames <= 0 and not Settings.ProbeSwitchAttack
        and not Settings.SwitchAttackBlock and not Settings.SwitchDeflectInject then return end
    local ok, err = pcall(RegisterHook, CLASH_ABILITY_BASE, TuneClashWindow)
    if not ok then
        logError("clash window hook: " .. tostring(err))
        return
    end
    clashWindowHooked = true
    LogEvent("clash window: hook ok (%d frames at %d fps; vanilla %.6f s; switch probe=%s)",
        Settings.ClashWindowFrames, CLASH_FRAME_RATE, CLASH_VANILLA_SECONDS,
        tostring(Settings.ProbeSwitchAttack))
end

---------------------------------------------------------------------------------------------------------------------
-- Probe: switch-weapon and deflect entry points (temporary, for the block-on-switch feature)
---------------------------------------------------------------------------------------------------------------------

local probeDone = false
local probeAttempts = 0
local probeLogs = 0

local function ProbeLog(fmt, ...)
    if probeLogs >= 500 then
        if probeLogs == 500 then
            probeLogs = probeLogs + 1
            log("probe: log limit reached")
        end
        return
    end
    probeLogs = probeLogs + 1
    log(fmt, ...)
end

local function ClassPath(object)
    local full = safe(function() return object:GetFullName() end)
    if not full then
        return nil
    end
    return (full:gsub("^Class ", ""))
end

local function ProbeFunctions(classObject, label, limit)
    local names = {}
    local ok = pcall(function()
        classObject:ForEachFunction(function(fn)
            local name = safe(function() return fn:GetFullName() end)
            if name then
                names[#names + 1] = tostring(name)
            end
        end)
    end)
    ProbeLog("probe: %s functions=%d ok=%s", label, #names, tostring(ok))
    for i = 1, math.min(#names, limit) do
        ProbeLog("probe: %s fn %s", label, names[i])
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Probe: switch-attack timeline (block judgement on the ChiRen switch attack)
---------------------------------------------------------------------------------------------------------------------

-- FName userdata fails IsValid(), so valid() must not gate these reads: that is what turned the
-- previous dump into wrapper addresses. Each reader is tried in turn without touching logError.
local function ProbeValue(value)
    if value == nil then return "nil" end
    local kind = type(value)
    if kind ~= "userdata" and kind ~= "table" then return tostring(value) end
    local ok, tag = pcall(function() return value.TagName end)
    if ok and tag ~= nil then return TagText(value) end
    -- UObject:ToString() yields "UObject: 0x...", so names must be tried before it. A UClass's own
    -- class is "Class", which is useless: for those the object's own name IS the ability class.
    local okName, name = pcall(function() return value:GetFName():ToString() end)
    local okClass, cls = pcall(function() return value:GetClass():GetFName():ToString() end)
    if okName and okClass and type(name) == "string" and type(cls) == "string" then
        if cls == "Class" then return name end
        return cls .. "/" .. name
    end
    if okClass and type(cls) == "string" then return cls end
    if okName and type(name) == "string" then return name end
    ok, tag = pcall(function() return value:ToString() end)
    if ok and type(tag) == "string" then return tag end
    return kind
end

local function ProbeFloatArray(value, limit)
    if value == nil then return "nil" end
    local parts = {}
    local ok = pcall(function()
        value:ForEach(function(_, ref)
            if #parts >= limit then return end
            local item = ref
            pcall(function() item = ref:get() end)
            parts[#parts + 1] = tostring(item)
        end)
    end)
    if #parts == 0 then return "empty(iterOk=" .. tostring(ok) .. ")" end
    return table.concat(parts, ",")
end

-- Read-only dump of an ability's Main timeline. Two deflect mechanisms exist: a standalone
-- GAA_DeflectFrame_C row (the clash window) and an attack box that carries its own deflect config.
-- The switch attack has no former row, so the latter is what the block judgement would ride on.
local function DumpAbilityTimeline(ability, label, verbose)
    local timeline = readField(ability, "Main")
    if not valid(timeline) then
        ProbeLog("%s: no Main timeline", label)
        return
    end
    local rows, deflects, bulletDumps = 0, 0, 0
    local ok = pcall(function()
        timeline.Actions:ForEach(function(_, ref)
            local row = ref:get()
            rows = rows + 1
            local action = readField(row, "Action")
            local actionName = valid(action) and FullName(action) or "nil"
            local startTime = readNumber(row, "StartTime")
            local duration = readNumber(row, "duration")
            if verbose and rows <= 60 then
                ProbeLog("%s row%d start=%s dur=%s action=%s", label, rows,
                    tostring(startTime), tostring(duration), actionName)
            end
            if actionName:find(CLASH_DEFLECT_CLASS, 1, true) then
                deflects = deflects + 1
                ProbeLog("%s DEFLECT onlyBlock=%s angle=%s weaponIndex=%s breakTimeline=%s comp=%s",
                    label, ProbeValue(readField(action, "Only Block Hit")),
                    ProbeValue(readNumber(action, "Deflect Angle")),
                    ProbeValue(readNumber(action, "Weapon Index")),
                    ProbeValue(readField(action, "Break Deflect Timeline")),
                    ProbeValue(readField(action, "Deflect Component")))
                ProbeLog("%s DEFLECT melee=%s projectile=%s prepare=%s impact=%s maxHitTime=%s",
                    label, ProbeValue(readField(action, "Melee Result")),
                    ProbeValue(readField(action, "Projectile Result")),
                    ProbeValue(readField(action, "Prepare Event")),
                    ProbeValue(readField(action, "Impact Event")),
                    ProbeValue(readNumber(action, "Max Hit Game Time")))
            end
            -- Matched by family keyword, then confirmed by field presence, so empty subclasses such
            -- as LGAAction_AddtiveBullet_PreZui_Hun are covered without walking the super chain.
            if actionName:find("Deflect", 1, true) or actionName:find("Bullet", 1, true) then
                local hasType, bulletType = pcall(function() return action.DeflectBulletType end)
                if hasType and bulletType ~= nil and bulletDumps < 4 then
                    bulletDumps = bulletDumps + 1
                    ProbeLog("%s BOX row%d start=%s dur=%s type=%s(0=CantDeflect,1=Normal,5=Hold) angle=%s radius=%s knockback=%s holdDist=%s staticRadius=%s",
                        label, rows, tostring(startTime), tostring(duration), ProbeValue(bulletType),
                        ProbeValue(readNumber(action, "DeflectAngle")),
                        ProbeValue(readNumber(action, "DeflectRadius")),
                        ProbeValue(readNumber(action, "DeflectKnockback")),
                        ProbeValue(readNumber(action, "HoldDeflectDistance")),
                        ProbeValue(readField(action, "bStaticRadius")))
                    ProbeLog("%s BOX row%d strength=%s direction=%s counterAbility=%s branch=%s cachedComp=%s",
                        label, rows, ProbeValue(readField(action, "DeflectStrength")),
                        ProbeValue(readField(action, "DeflectDirection")),
                        ProbeValue(readField(action, "CounterAbility")),
                        ProbeValue(readField(action, "Branch")),
                        ProbeValue(readField(action, "CachedDeflectComponent")))
                    ProbeLog("%s BOX row%d bulletDur=%s preHit=%s runtimePreHit=%s reps=%s sendFrames=[%s] startBullet=[%s] endBullet=[%s]",
                        label, rows, ProbeValue(readNumber(action, "BulletDuration")),
                        ProbeValue(readNumber(action, "PreHitPointDuration")),
                        ProbeValue(readNumber(action, "RuntimePreHitPointDuration")),
                        ProbeValue(readNumber(action, "BulletRepetitions")),
                        ProbeFloatArray(readField(action, "SendFrameTimes"), 12),
                        ProbeFloatArray(readField(action, "StartBulletTimes"), 8),
                        ProbeFloatArray(readField(action, "EndBulletTimes"), 8))
                end
            end
        end)
    end)
    ProbeLog("%s: rows=%d deflectRows=%d boxRows=%d iterOk=%s", label, rows, deflects, bulletDumps,
        tostring(ok))
end

local switchSeen = {}
local switchDumped = {}
local switchActivateLogs = 0
local switchSeqLogs = 0

-- Rides the clash-window hook so only one ability-base hook is ever installed. Records the first
-- activation of every player ability, which is how the talent's LB+Y replacement gets identified.
ProbeSwitchActivate = function(context)
    local ability = Unwrap(context)
    if not valid(ability) then return end
    local outer = safe(function() return ability:GetOuter() end)
    local outerName = valid(outer) and FullName(outer) or "?"
    if not outerName:find("BP_Renewal_Hun", 1, true) then return end
    local className = safe(function() return ability:GetClass():GetFName():ToString() end)
    if not className then return end
    local isSwitch = className:find("SWT", 1, true) or className:find("Switch", 1, true)
        or className:find("Counter", 1, true)
    -- The user confirmed the ChiRen switch attack IS the LB+Y fire sweep, and that switching may call
    -- the same ability as the manual button. GA_Hun_ChiRen_C_C is the likely manual entry, so every
    -- ChiRen ability gets dumped; non-switch ones only log their deflect boxes to stay in budget.
    local isChiRen = className:find("ChiRen", 1, true)
    if not switchSeen[className] then
        switchSeen[className] = true
        if switchActivateLogs < 40 then
            switchActivateLogs = switchActivateLogs + 1
            ProbeLog("switch probe: activate %s", className)
        end
        if (isSwitch or isChiRen) and not switchDumped[className] then
            switchDumped[className] = true
            DumpAbilityTimeline(ability, "switch probe " .. className, isSwitch)
        end
    end
    -- Every activation, not just the first: this shows whether a weapon swap fires SWT_C, C_C or
    -- both. Light-attack chains are excluded so they cannot spend the budget before the swap.
    local isChiRenKey = isChiRen and not className:find("ChiRen_A", 1, true)
    if switchSeqLogs < 60 and (isSwitch or isChiRenKey or className:find("Heavy", 1, true)) then
        switchSeqLogs = switchSeqLogs + 1
        ProbeLog("switch seq %d: %s", switchSeqLogs, className)
    end
    if className == SWITCH_BLOCK.ability then
        SWITCH_BLOCK.activations = SWITCH_BLOCK.activations + 1
    end
end

local switchInstancesDone = false

-- Does not depend on the player actually switching: dumps whatever switch-attack instances exist.
-- Skips classes the activation hook already dumped so the two paths cannot spend the budget twice.
local function ProbeSwitchInstances()
    if switchInstancesDone then return end
    if not valid(GetPlayerPawn()) then return end
    switchInstancesDone = true
    local found = safe(FindAllOf, "BP_SwitchAttack_Base_C")
    if not found or #found == 0 then
        ProbeLog("switch probe: no BP_SwitchAttack_Base_C instance")
        return
    end
    ProbeLog("switch probe: %d switch-attack instances", #found)
    local dumped = 0
    for _, ability in ipairs(found) do
        if dumped >= 2 then break end
        if valid(ability) then
            local className = safe(function() return ability:GetClass():GetFName():ToString() end)
            if className and not switchDumped[className] then
                switchDumped[className] = true
                dumped = dumped + 1
                ProbeLog("switch probe: instance %d %s", dumped, className)
                DumpAbilityTimeline(ability, "switch probe inst" .. dumped, true)
            end
        end
    end
end

local function ProbeSwitchWeapon()
    local classObject = safe(StaticFindObject,
        "/PBZCombatAsset/Prototypes/Actions/GAA_SwitchWeapon.GAA_SwitchWeapon_C")
    if not valid(classObject) then
        local found = safe(FindAllOf, "GAA_SwitchWeapon_C")
        if found and #found > 0 then
            classObject = found[1]
        end
    end
    if not valid(classObject) then
        ProbeLog("probe: GAA_SwitchWeapon_C not found")
        return false
    end
    local path = ClassPath(classObject)
    ProbeLog("probe: switch class=%s path=%s", FullName(classObject), tostring(path))
    ProbeFunctions(classObject, "switch", 40)
    if path then
        for _, fn in ipairs({ "OnStart", "OnEnd", "OnActivate", "OnDeactivate", "Activate", "Deactivate",
            "Execute", "K2_ActivateAbility", "StartSwitchWeapon" }) do
            local hooked, err = pcall(RegisterHook, path .. ":" .. fn, function(context)
                local self = Unwrap(context)
                ProbeLog("probe: switchWeapon %s instance=%s", fn, FullName(self))
            end)
            ProbeLog("probe: hook %s ok=%s%s", fn, tostring(hooked),
                hooked and "" or (" err=" .. tostring(err)))
        end
    end
    return true
end

local function ProbeStances()
    local stances = safe(FindAllOf, "BP_StanceAction_Base_Player_C")
    if not stances or #stances == 0 then
        ProbeLog("probe: no player stance instances")
        return
    end
    ProbeLog("probe: player stance instances=%d", #stances)
    for i, stance in ipairs(stances) do
        if i > 6 then
            break
        end
        if valid(stance) then
            ProbeLog("probe: stance %s slot=%s perfect=%s great=%s normal=%s", FullName(stance),
                tostring(readField(stance, "Weapon Slot")),
                tostring(readNumber(stance, "Perfect Window")),
                tostring(readNumber(stance, "Great Window")),
                tostring(readNumber(stance, "Normal Window")))
            if i == 1 then
                ProbeFunctions(stance:GetClass(), "stance", 30)
                local path = classPathOf(stance)
                if path then
                    local hooked = pcall(RegisterHook, path .. ":K2_ActivateAbility", function()
                        ProbeLog("probe: stance K2_ActivateAbility")
                    end)
                    ProbeLog("probe: hook stance K2_ActivateAbility ok=%s", tostring(hooked))
                end
            end
        end
    end
end

local function ProbeDeflect()
    local comps = safe(FindAllOf, "DeflectComponent")
    if not comps then
        return
    end
    for _, comp in ipairs(comps) do
        if valid(comp) then
            local owner = safe(function() return comp:GetOuter() end)
            local name = owner and FullName(owner) or ""
            if name:find("BP_Renewal_Hun", 1, true) then
                local path = classPathOf(comp)
                if path then
                    for _, fn in ipairs({ "SendDeflectFrame", "StopSendDeflectFrame" }) do
                        local hooked = pcall(RegisterHook, path .. ":" .. fn, function()
                            ProbeLog("probe: player %s", fn)
                        end)
                        ProbeLog("probe: hook player %s ok=%s", fn, tostring(hooked))
                    end
                end
                break
            end
        end
    end
end

local hitstateProbeDone = false
local hitstateProbeTries = 0

-- Every loaded hit-state GE component names the state it drives. One of these GEs should play the full
-- reaction animation; the probe lists them so the interrupt can use that instead of ChangeHitState.
local function ProbeHitStateGes()
    if hitstateProbeDone then
        return
    end
    local comps = safe(FindAllOf, "HitStateGameplayEffectComponent")
    if not comps or #comps == 0 then
        comps = safe(FindAllOf, "/Script/SGameCombatSystem.HitStateGameplayEffectComponent")
    end
    if not comps or #comps == 0 then
        hitstateProbeTries = hitstateProbeTries + 1
        if hitstateProbeTries <= 5 then
            ProbeLog("probe: no HitStateGameplayEffectComponent instances")
            return
        end
        -- The short name did not resolve; filter every loaded effect component by class name.
        local all = safe(FindAllOf, "GameplayEffectComponent")
        if all then
            local filtered = {}
            for _, comp in ipairs(all) do
                if valid(comp) then
                    local class = safe(function() return comp:GetClass():GetFullName() end)
                    if class and class:find("HitState", 1, true) then
                        filtered[#filtered + 1] = comp
                    end
                end
            end
            comps = filtered
        end
        if not comps or #comps == 0 then
            hitstateProbeDone = true
            ProbeLog("probe: hitstate component probe gave up")
            return
        end
        ProbeLog("probe: hitstate components=%d (filtered)", #comps)
    else
        ProbeLog("probe: hitstate components=%d", #comps)
    end
    hitstateProbeDone = true
    for i, comp in ipairs(comps) do
        if i > 20 then
            break
        end
        if valid(comp) then
            local owner = safe(function() return comp:GetOuter() end)
            local tag = readField(comp, "HitState")
            local tagName = tag and FNameText(readField(tag, "TagName")) or "nil"
            ProbeLog("probe: hitstate GE %s tag=%s end=%s remove=%s stop=%s",
                valid(owner) and FullName(owner) or "?",
                tostring(tagName),
                tostring(readField(comp, "EndStrengthAnimTask")),
                tostring(readField(comp, "RemoveOnEnd")),
                tostring(readField(comp, "StopGEOnHitStateEnd")))
        end
    end
end

local animSetProbeDone = false

local function ProbeAnimSets()
    if animSetProbeDone then
        return
    end
    local sets = safe(FindAllOf, "HitStrengthAnimSetBase")
    if not sets or #sets == 0 then
        return
    end
    animSetProbeDone = true
    ProbeLog("probe: hitstrength anim sets=%d", #sets)
    local shown = 0
    for _, set in ipairs(sets) do
        if shown >= 20 then
            break
        end
        if valid(set) then
            local name = FullName(set)
            if name:find("YuBi", 1, true) or name:find("Monster", 1, true) then
                shown = shown + 1
                local parts = {}
                for _, field in ipairs({ "F", "B", "L", "R", "FLoop", "BLoop" }) do
                    local value = readField(set, field)
                    if valid(value) then
                        parts[#parts + 1] = field .. "=" .. FullName(value)
                    end
                end
                ProbeLog("probe: animset %s %s", name, table.concat(parts, " "))
            end
        end
    end
end

local hitAnimProbeDone = false

local function ProbeHitAnims()
    if hitAnimProbeDone then
        return
    end
    local anims = safe(FindAllOf, "PDA_HitAnim_MobNew_C")
    if not anims or #anims == 0 then
        return
    end
    hitAnimProbeDone = true
    ProbeLog("probe: mob hit anim data=%d", #anims)
    local shown = 0
    for i, anim in ipairs(anims) do
        if shown >= 20 then
            break
        end
        if valid(anim) then
            local name = FullName(anim)
            if i <= 10 or name:find("YuBi", 1, true) or name:find("Monster", 1, true) then
                shown = shown + 1
                ProbeLog("probe: hitanim %s", name)
            end
        end
    end
end

local function ProbeOnce()
    if probeDone then
        return
    end
    probeAttempts = probeAttempts + 1
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return
    end
    if ProbeSwitchWeapon() then
        ProbeStances()
        ProbeDeflect()
        probeDone = true
    elseif probeAttempts >= 5 then
        probeDone = true
        ProbeLog("probe: switch weapon class was never found")
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------------------------------------------------------

-- The ChiRen passive keeps its own "blade energy" (BurningEnergy) and enters a timed FireState; the
-- mod's free-attack counter is separate. This one-shot dump records the real fields and values so
-- the tornado multiplier can key off the native state instead of guessing.
local chiRenDataProbeDone = false
local CHARGE_FIELD_CANDIDATES = {
    "BurningEnergy", "BurningCharge", "Charge", "ChargeValue", "CurrentCharge", "MaxCharge",
    "Energy", "BladeEnergy", "WeaponEnergy", "KnifeForce", "BladeCharge",
}

-- State for the switch-weapon retention question: does blade energy / fire survive a weapon swap?
-- Kept in one table so the probe costs a single top-level local.
local ChiRenSwitchProbe = {
    tries = 0, passive = nil, charge = nil, tagName = nil, fields = {},
    lastActivations = 0, prevSnapshot = nil, watchUntil = 0, logs = 0,
}

local function DumpNumberFields(label, obj, fields)
    if not valid(obj) then
        return
    end
    local parts = {}
    for _, name in ipairs(fields) do
        local value = readNumber(obj, name)
        if value ~= nil then
            parts[#parts + 1] = name .. "=" .. string.format("%.3f", value)
        end
    end
    if #parts > 0 then
        LogEvent("%s: %s", label, table.concat(parts, ", "))
    end
end

local function DumpPropertyNames(label, obj)
    if not valid(obj) then
        return
    end
    local cls = safe(function() return obj:GetClass() end)
    if not valid(cls) then
        return
    end
    local names = {}
    pcall(function()
        cls:ForEachProperty(function(prop)
            local name = safe(function() return prop:GetFName():ToString() end)
            if name then
                names[#names + 1] = name
            end
        end)
    end)
    LogEvent("%s props(%d): %s", label, #names, table.concat(names, ","))
end

-- One-shot only once it actually finds the passive: the assets load lazily, and burning the flag on
-- the first tick (13:11:44 in the previous log) is why the earlier runs never dumped anything.
local function ProbeChiRenData()
    if chiRenDataProbeDone then
        return
    end
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return
    end
    -- The passive showed up ~113 s after the pawn became valid last run, so the retry budget has to
    -- outlast that. FindAllOf walks the whole object array: only run it every third tick.
    ChiRenSwitchProbe.tries = ChiRenSwitchProbe.tries + 1
    local passives = nil
    if ChiRenSwitchProbe.tries % 3 == 0 then
        passives = safe(FindAllOf, "GA_Hun_ChiRen_Passive_C")
    end
    if not passives or #passives == 0 then
        if ChiRenSwitchProbe.tries >= 240 then
            chiRenDataProbeDone = true
            LogEvent("chiren data: no passive instance after %d tries", ChiRenSwitchProbe.tries)
        end
        return
    end
    chiRenDataProbeDone = true
    for i, passive in ipairs(passives) do
        if i > 3 then
            break
        end
        if valid(passive) then
            LogEvent("chiren passive %d: %s", i, FullName(passive))
            DumpPropertyNames("chiren passive", passive)
            for _, field in ipairs({ "BurningEnergyThreshold", "DecayDelaySeconds",
                "DecayFullToZeroSeconds", "FireStateDurationSeconds", "BurnDamagePerHit" }) do
                LogEvent("chiren passive %s: %s", field, tostring(readNumber(passive, field)))
            end
            local burningTag = readField(passive, "BurningStateTag")
            local tagName = TagText(burningTag)
            LogEvent("chiren passive BurningStateTag: %s", tagName)
            LogEvent("chiren passive MainWeaponSlotTag: %s",
                TagText(readField(passive, "MainWeaponSlotTag")))
            local row = readField(passive, "BurningChargeTableRow")
            LogEvent("chiren passive BurningChargeTableRow: %s", ProbeValue(row))
            local ge = readField(passive, "FireStateGE")
            LogEvent("chiren passive FireStateGE: %s", ProbeValue(ge))
            local charge = readField(passive, "BurningChargeObject")
            LogEvent("chiren passive BurningChargeObject: %s", ProbeValue(charge))
            DumpPropertyNames("chiren charge", charge)
            DumpNumberFields("chiren charge", charge, CHARGE_FIELD_CANDIDATES)
            if i == 1 then
                ChiRenSwitchProbe.passive = passive
                ChiRenSwitchProbe.charge = charge
                ChiRenSwitchProbe.tagName = tagName
                -- The real stack field name is unknown, so pick the plausible numeric ones out of
                -- the class instead of guessing a single name.
                local cls = safe(function() return charge:GetClass() end)
                if valid(cls) then
                    pcall(function()
                        cls:ForEachProperty(function(prop)
                            local name = safe(function() return prop:GetFName():ToString() end)
                            if not name then return end
                            for _, key in ipairs({ "Charge", "Energy", "Stack", "Layer", "Count",
                                "Level", "Value", "Num" }) do
                                if name:find(key, 1, true) then
                                    ChiRenSwitchProbe.fields[#ChiRenSwitchProbe.fields + 1] = name
                                    return
                                end
                            end
                        end)
                    end)
                end
                LogEvent("chiren switch probe: watching %d charge fields, tag=%s",
                    #ChiRenSwitchProbe.fields, tagName)
            end
            local abilities = readField(pawn, "AbilitySystemComponent")
            if valid(abilities) and tagName and tagName ~= "nil" and tagName ~= "?" then
                local count = safe(function()
                    return abilities:GetGameplayTagCount({ TagName = FName(tagName, EFindName.FNAME_Add) })
                end)
                LogEvent("chiren passive tag count %s = %s", tagName, tostring(count))
            end
        end
    end
end

-- Runs on the 1.5 s hook loop rather than the 300 ms sampler: extra reflection at high frequency is
-- the known crash family. The switch signal is SWT_C's own activation count and the fire state comes
-- from the pawn's ASC with the tag name the mod already uses: last run the passive's ASC lookup and
-- the weapon tag container both yielded nothing, which is why zero snapshots were logged.
local function ProbeChiRenSwitch()
    local st = ChiRenSwitchProbe
    if st.logs >= 60 then
        return
    end
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return
    end
    local asc = readField(pawn, "AbilitySystemComponent")
    if not valid(asc) then
        return
    end
    local now = os.clock()
    local fire = tostring(safe(function()
        return asc:GetGameplayTagCount({ TagName = BURNING_FNAME })
    end))
    local parts = {}
    if valid(st.charge) then
        for _, name in ipairs(st.fields) do
            parts[#parts + 1] = name .. "=" .. tostring(readNumber(st.charge, name))
        end
    end
    local snapshot = string.format("fireTagCount=%s charge[%s]", fire, table.concat(parts, ","))
    local activations = SWITCH_BLOCK.activations
    if activations ~= st.lastActivations then
        st.lastActivations = activations
        st.watchUntil = now + 6.0
        st.logs = st.logs + 2
        ProbeLog("chiren SWITCH before: %s", st.prevSnapshot or "?")
        ProbeLog("chiren SWITCH after: %s", snapshot)
    elseif now <= st.watchUntil then
        st.logs = st.logs + 1
        ProbeLog("chiren watch: %s", snapshot)
    end
    st.prevSnapshot = snapshot
end

local function Tick()
    TryDeflectHook()
    TryHitreactHook()
    TryNativeInvulnProbe()
    TryNativeGeHook()
    TryBlockHook()
    TryMontageHook()
    HookChiRenGas()
    ProbeChiRenData()
    if Settings.ProbeSwitchAttack then
        ProbeChiRenSwitch()
    end
    for _, name in ipairs(HEAVY_CLASSES) do
        HookHeavy(name)
    end
    for _, name in ipairs(ATTACK_CLASSES) do
        HookAttack(name)
    end
    TuneDeflectWindow()
    TryClashWindowHook()
    ProbeSwitchInstances()
    ProbeOnce()
    ProbeHitStateGes()
    ProbeAnimSets()
    ProbeHitAnims()
end

local function TickSafe()
    local ok, err = pcall(Tick)
    if not ok then logError(err) end
end

local function SampleSafe()
    local ok, err = pcall(CheckBurning)
    if not ok then logError(err) end
    local keepOk, keepErr = pcall(KeepTick)
    if not keepOk then logError(keepErr) end
    local dmgOk, dmgErr = pcall(TickDamage, os.clock())
    if not dmgOk then logError(dmgErr) end
    -- Safety net: if the slow-motion frame loop ever stops restoring, take the factor back here.
    if CLASH_SLOWMO.active and os.clock() > CLASH_SLOWMO.endsAt + 0.3 then
        local slowOk, slowErr = pcall(CLASH_SLOWMO.restore)
        if not slowOk then logError(slowErr) end
    end
end

log(VERSION .. " loaded")

if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(1500, TickSafe)
    -- Faster than the hook loop, so the fire duration in the log is close to the real one.
    LoopInGameThreadWithDelay(300, SampleSafe)
    -- Real-time frame loop for the clash slow-down (idle: a single boolean check).
    LoopInGameThreadWithDelay(16, CLASH_SLOWMO.frameStep)
else
    LoopAsync(1500, function()
        ExecuteInGameThread(TickSafe)
        return false
    end)
    LoopAsync(300, function()
        ExecuteInGameThread(SampleSafe)
        return false
    end)
    LoopAsync(16, function()
        ExecuteInGameThread(CLASH_SLOWMO.frameStep)
        return false
    end)
end
