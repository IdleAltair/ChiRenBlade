local UEHelpers = require("UEHelpers")

local MOD = "ChiRenBlade"
local VERSION = "0.29"

local DEFAULTS = {
    Charges = 6,
    FireEnabled = true,
    FireSeconds = 5,
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    BreakOnDeflect = true,
    BreakHoldSeconds = 3.0,
    BreakRepeatSeconds = 0.8,
    HeavyCostScale = 0.5,
    PlayerBreakDuration = 0.5,
    PlayerHitreactTime = 0,
    LieDuration = 0,
    MobBreakDuration = 4.0,
    MobDeflectBreakTime = 2.0,
    LogEvents = true,
}

-- The game's global combat config asset holds the parry window and break durations.
local COMBAT_CONFIG_CLASS = "PDA_GlobalCombatConfig_C"
-- This effect is what the game itself applies when an enemy's poise breaks: the stagger that interrupts it.
local BREAK_GE_PATH = "/PBZCombatAsset/Prototypes/GameplayEffects/GE_ActionPoiseBreak.GE_ActionPoiseBreak_C"

local HEAVY_CLASSES = {
    "GA_Hun_ChiRen_B_C",
    "GA_Hun_ChiRen_BB_C",
    "GA_Hun_ChiRen_BBB_C",
    "GA_Hun_ChiRen_BD_C",
    "GA_Hun_ChiRen_BSup_C",
    "GA_Hun_ChiRen_C_C",
}

local errors = 0
local charges = 0
local freeApplied = 0
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
        return safe(function() return value.CurrentValue end)
    end
    return nil
end

-- Values outside these ranges keep the default.
local LIMITS = {
    Charges = { 0, 20 },
    FireSeconds = { 0.5, 30 },
    CooldownSeconds = { 0, 2 },
    BreakHoldSeconds = { 0, 6 },
    BreakRepeatSeconds = { 0.2, 2 },
    HeavyCostScale = { 0.05, 1.0 },
    PlayerBreakDuration = { 0, 10 },
    PlayerHitreactTime = { 0, 5 },
    LieDuration = { 0, 5 },
    MobBreakDuration = { 0, 6 },
    MobDeflectBreakTime = { 0, 10 },
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

local BURNING_FNAME = FName("CharacterState.AbilityState.ChiRen.Burning", EFindName.FNAME_Add)
local lastBurning = nil
local fireAppliedAt = nil
-- FireStateGE is a class; its default object holds the duration that the effect copies on apply.
local fireCdo = nil

local function LogEvent(fmt, ...)
    if Settings.LogEvents then
        log(fmt, ...)
    end
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
            LogEvent("fire lasted %.2f s (asked %.1f)", os.clock() - fireAppliedAt, Settings.FireSeconds)
            fireAppliedAt = nil
        end
        LogEvent("burning=%s at %.1f (shachi=%s)", tostring(count), os.clock(), tostring(PlayerShachi()))
    end
end

-- The mob hit reaction state would be the direct measurement of the hold window, but the names below are
-- guesses: the state tracker that used them never printed a line, so nothing it read was valid. Dump the
-- real shape once, so a later version can read the right field.
local hitreactDumped = false

local function DumpHitreact()
    if hitreactDumped then
        return
    end
    local comps = safe(FindAllOf, "HitreactComponent")
    if not comps then
        return
    end
    for _, comp in ipairs(comps) do
        if valid(comp) then
            local compName = FullName(comp)
            if not compName:find("Hun", 1, true) and not compName:find("Player", 1, true) then
                hitreactDumped = true
                local runtime = readField(comp, "RuntimeStateData")
                LogEvent("hitreact: %s runtime=%s (%s)", compName,
                    tostring(safe(function() return tostring(runtime) end)), type(runtime))
                if runtime == nil then
                    return
                end
                for _, field in ipairs({ "StateData", "CurrentState", "State", "HitAnimData", "CurrentHitAnim" }) do
                    local value = readField(runtime, field)
                    LogEvent("  hitreact.%s=%s (%s)", field,
                        tostring(safe(function() return tostring(value) end)), type(value))
                end
                return
            end
        end
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

local function TryFire()
    if not Settings.FireEnabled then
        return
    end
    -- Each clash stacks another independent GE instance, which multiplies the fire damage. One layer at
    -- a time is enough for the free-attack window; a new one is allowed only in the last second.
    if fireAppliedAt then
        local elapsed = os.clock() - fireAppliedAt
        if elapsed > Settings.FireSeconds * 2 then
            fireAppliedAt = nil
        elseif elapsed < Settings.FireSeconds - 1.0 then
            LogEvent("fire: still burning, skipped")
            return
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
    local setValue, valueError = pcall(function() magnitude.ScalableFloatMagnitude.Value = Settings.FireSeconds end)
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
        fireAppliedAt = os.clock()
        LogEvent("fire: applied, asked %.1f s", Settings.FireSeconds)
    else
        LogEvent("fire: BP_ApplyGameplayEffectToSelf failed (%s)", tostring(err))
    end
end

local function GrantCharges(reason)
    local now = os.clock()
    if now - lastClash < Settings.CooldownSeconds then
        return
    end
    lastClash = now
    charges = Settings.Charges
    LogEvent("clash (%s): %d free heavy attacks", reason, charges)
    TryFire()
end

---------------------------------------------------------------------------------------------------------------------
-- Clash trigger: player's DeflectComponent consumes a deflect frame
---------------------------------------------------------------------------------------------------------------------

local BreakFromDeflectFrame

local function TryDeflectHook()
    if hookedDeflect or not Settings.TriggerOnDeflect then return end
    local components = safe(FindAllOf, "DeflectComponent")
    if not components or #components == 0 then return end
    local classPath = classPathOf(components[1])
    if not classPath then return end
    hookedDeflect = true
    local ok, err = pcall(RegisterHook, classPath .. ":ConsumeReceivedFrame", function(context, handle)
        local self = Unwrap(context)
        local name = FullName(self)
        if not name:find("BP_Renewal_Hun") then
            return
        end
        GrantCharges("deflect frame consumed")
        BreakFromDeflectFrame(self, handle)
    end)
    if ok then
        LogEvent("hooked ConsumeReceivedFrame")
    else
        logError("deflect hook: " .. tostring(err))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Break the attacker on a parry (interrupt its combo)
---------------------------------------------------------------------------------------------------------------------

local breakGe = nil
local breakGeDumped = false

local function ResolveBreakGe()
    if valid(breakGe) then
        return breakGe
    end
    breakGe = safe(StaticFindObject, BREAK_GE_PATH)
    if not valid(breakGe) then
        return nil
    end
    if not breakGeDumped then
        breakGeDumped = true
        LogEvent("break effect: %s", FullName(breakGe))
        local cdo = FindCDO(breakGe)
        local components = cdo and readField(cdo, "GEComponents") or nil
        local count = components and #components or 0
        for index = 1, count do
            local component = components[index]
            if component then
                LogEvent("  break component %s", FullName(component))
            end
        end
    end
    return breakGe
end

-- A successful clash applies the poise-break effect to the attacker: the break takes the enemy out of
-- its current action, which is the opening a long combo does not otherwise leave. Repeats against the
-- same enemy inside the window are ignored so the hit reaction cannot be restarted every frame; the
-- hold below passes force = true to get past that guard.
local lastBreakName = nil
local lastBreakAt = 0
local lastBreakHandle = nil

local function HandleText(handle)
    if handle == nil then return "nil" end
    if type(handle) == "table" then
        -- UE4SS returns the FActiveGameplayEffectHandle struct as a Lua table.
        local inner = handle.Handle
        if inner ~= nil then
            return "table(Handle=" .. tostring(inner) .. ")"
        end
        return "table"
    end
    local ok, text = pcall(function() return tostring(handle) end)
    return ok and text or "?"
end

local function ApplyBreak(attacker, label, force)
    if not valid(attacker) then
        return false
    end
    local attackerName = FullName(attacker)
    local now = os.clock()
    if not force and attackerName == lastBreakName and now - lastBreakAt < 0.8 then
        return false
    end
    local abilities = readField(attacker, "AbilitySystemComponent")
    if not valid(abilities) then
        LogEvent("break: %s has no ability system", attackerName)
        return false
    end
    local ge = ResolveBreakGe()
    if not ge then
        LogEvent("break: GE_ActionPoiseBreak not found")
        return false
    end
    local context = safe(function() return abilities:MakeEffectContext() end)
    if not context then
        LogEvent("break: no effect context")
        return false
    end
    lastBreakName = attackerName
    lastBreakAt = now
    local ok, result = pcall(function()
        return abilities:BP_ApplyGameplayEffectToSelf(ge, 1.0, context)
    end)
    lastBreakHandle = ok and result or nil
    LogEvent("break on %s: %s applied=%s handle=%s%s", label, attackerName, tostring(ok),
        HandleText(lastBreakHandle), ok and "" or (" err=" .. tostring(result)))
    return ok
end

-- One break only plays one hit reaction (about 0.76 s of animation in the game data; the break duration
-- in the combat config does not stretch it). To keep the enemy out of the fight for a real window the
-- effect is re-applied on a timer. The active instance is removed first: a second apply on an already
-- active effect is a refresh and would not restart the reaction.
local holdTarget = nil
local holdName = nil
local holdComp = nil
local holdUntil = 0
local holdNextAt = 0
local holdRepeats = 0
local holdHandle = nil

-- The hit reaction component of the target actor: its RuntimeStateData.StateData is the state the mob
-- is currently playing. Comparing it across a repeat shows whether the remove+apply really restarted
-- the break or was just a refresh.
local function FindHitreactComp(actor)
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

-- A readable label for a UObject that may only answer to toString. The state objects under
-- RuntimeStateData do not answer GetFullName reliably, so the address is the fallback identity.
local function ObjectLabel(object)
    if object == nil then
        return "nil"
    end
    -- The state fields are often a nullptr wrapped in a UObject; calling into it throws.
    if not valid(object) then
        return "null"
    end
    local name = safe(function()
        local value = object:GetName()
        return type(value) == "string" and value or nil
    end)
    if type(name) ~= "string" then
        name = safe(function()
            local value = object:GetFullName()
            return type(value) == "string" and value or nil
        end)
    end
    local text = safe(function() return tostring(object) end)
    local address = type(text) == "string" and text:match("(%x+)$") or nil
    return string.format("%s@%s", tostring(name), tostring(address))
end

-- FName values do not answer GetName; ToString is their text.
local function FNameText(value)
    if value == nil then
        return "nil"
    end
    if type(value) == "string" then
        return value
    end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" then
        return text
    end
    local okText, raw = pcall(function() return tostring(value) end)
    return okText and tostring(raw) or "?"
end

local function HitreactState(comp)
    if not valid(comp) then
        return "nocomp"
    end
    local runtime = readField(comp, "RuntimeStateData")
    if runtime == nil then
        return "noruntime"
    end
    local state = readField(runtime, "StateData")
    if state == nil then
        return "nostate"
    end
    if not valid(state) then
        return "null"
    end
    return ObjectLabel(state)
end

-- The tag of the reaction the mob is in right now, straight from the component: the direct measure of
-- whether the hold put it back into a break state.
local function CurrentHitState(comp)
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
    -- GetCurrentHitState returns a GameplayTag (a table with TagName) on some builds and an FName on
    -- others.
    if type(value) == "table" then
        local tag = readField(value, "TagName")
        if tag ~= nil then
            return FNameText(tag)
        end
    end
    return FNameText(value)
end

-- One look at what the hit reaction component exposes, including the functions of its class. The
-- component instance itself answers ForEachFunction with a TrivialObject, the class does not.
local hitreactFunctionsDumped = false
local breakCandidates = {}

local function DumpHitreactInfo(comp)
    if hitreactFunctionsDumped or not valid(comp) then
        return
    end
    hitreactFunctionsDumped = true
    LogEvent("hitreact actorState=%s config=%s", ObjectLabel(readField(comp, "ActorState")),
        ObjectLabel(readField(comp, "HitreactStatesConfig")))
    -- The state table: tag -> state data. The class of the value names the reaction (Break, Knockback...).
    local config = readField(comp, "HitreactStatesConfig")
    if valid(config) then
        local data = readField(config, "HitStateData")
        if data ~= nil then
            local count = 0
            pcall(function()
                data:ForEach(function(key, value)
                    count = count + 1
                    -- TMap callbacks hand over RemoteUnrealParam wrappers, not the values themselves.
                    key = Unwrap(key)
                    value = Unwrap(value)
                    local tagName = key and readField(key, "TagName") or nil
                    local tagText = FNameText(tagName)
                    local stateClass = value and readField(value, "StateDataClass") or nil
                    if count <= 30 then
                        LogEvent("  hitstate %d: %s -> %s", count, tagText, ObjectLabel(stateClass))
                    end
                    -- The break reactions are hit states; a tag without state data cannot play.
                    local lower = tagText:lower()
                    if lower:find("break", 1, true) and not lower:find("end", 1, true) then
                        breakCandidates[#breakCandidates + 1] = {
                            tag = key,
                            name = tagText,
                            hasData = stateClass ~= nil,
                        }
                    end
                end)
            end)
            LogEvent("hitstate entries=%d", count)
            table.sort(breakCandidates, function(a, b)
                -- PoiseBreak is the state the poise system itself uses; prefer it over the generic ones.
                local aPoise = a.name:lower():find("poisebreak", 1, true) ~= nil
                local bPoise = b.name:lower():find("poisebreak", 1, true) ~= nil
                if aPoise ~= bPoise then
                    return aPoise
                end
                if a.hasData ~= b.hasData then
                    return a.hasData
                end
                local aState = a.name:lower():find(".state", 1, true) ~= nil
                local bState = b.name:lower():find(".state", 1, true) ~= nil
                if aState ~= bState then
                    return aState
                end
                return false
            end)
            for index, candidate in ipairs(breakCandidates) do
                LogEvent("break candidate %d: %s (data=%s)", index, candidate.name,
                    tostring(candidate.hasData))
            end
        end
    end
    local classObject = safe(function() return comp:GetClass() end)
    if classObject == nil then
        LogEvent("hitreact functions: no class")
        return
    end
    local names = {}
    local wanted = {
        PlayHitreact = true,
        PlayHitreactToAvatar = true,
        PlayHitAnimation = true,
        PlayKnockback = true,
        ChangeHitState = true,
    }
    local ok, err = pcall(function()
        classObject:ForEachFunction(function(fn)
            local name = safe(function() return fn:GetFullName() end)
            if name == nil then
                return
            end
            name = tostring(name)
            names[#names + 1] = name
            local short = name:match(":([^:]+)$")
            if short and wanted[short] then
                pcall(function()
                    fn:ForEachProperty(function(prop)
                        local propName = safe(function() return prop:GetFullName() end)
                        local propType = safe(function() return prop:GetClass():GetFullName() end)
                        LogEvent("    %s param %s (%s)", short, tostring(propName), tostring(propType))
                    end)
                end)
            end
        end)
    end)
    LogEvent("hitreact functions ok=%s count=%d", tostring(ok), #names)
    for index = 1, math.min(#names, 60) do
        LogEvent("  hitreact fn %s", names[index])
    end
    if not ok then
        LogEvent("hitreact functions error: %s", tostring(err))
    end
end

-- RemoveActiveGameplayEffect takes the handle and a stack count; a one-argument call throws and the
-- old instance stays active, which makes the re-apply a silent refresh.
local function RemoveBreak(abilities)
    local removed = false
    if holdHandle ~= nil then
        local ok, result = pcall(function()
            return abilities:RemoveActiveGameplayEffect(holdHandle, 1)
        end)
        removed = ok and result ~= false
        if not ok then
            LogEvent("hold break: remove failed (%s)", tostring(result))
        end
    end
    if not removed then
        local ge = ResolveBreakGe()
        if ge then
            local ok, result = pcall(function()
                abilities:RemoveActiveGameplayEffectBySourceEffect(ge, nil, 1)
            end)
            removed = ok and result ~= false
            if not ok then
                LogEvent("hold break: class remove failed (%s)", tostring(result))
            end
        end
    end
    return removed
end

local function StartBreakHold(attacker, seconds)
    if seconds <= 0 then
        return
    end
    holdTarget = attacker
    holdName = FullName(attacker)
    holdComp = FindHitreactComp(attacker)
    holdUntil = os.clock() + seconds
    holdNextAt = os.clock() + Settings.BreakRepeatSeconds
    holdRepeats = 0
    holdHandle = lastBreakHandle
    LogEvent("hold break: %s for %.1f s, repeat %.2f s (comp=%s state=%s hitState=%s)", holdName,
        seconds, Settings.BreakRepeatSeconds, tostring(holdComp ~= nil), HitreactState(holdComp),
        CurrentHitState(holdComp))
    DumpHitreactInfo(holdComp)
    -- The poise-break effect is only tags; the reaction itself is a hit state on this component. Try the
    -- break states in order (one with state data first) until the component accepts one.
    if valid(holdComp) then
        for index, candidate in ipairs(breakCandidates) do
            local ok, result = pcall(function()
                return holdComp:ChangeHitState(candidate.tag, nil, true)
            end)
            LogEvent("change hit state %d %s: ok=%s result=%s now=%s", index, candidate.name,
                tostring(ok), tostring(result), CurrentHitState(holdComp))
            if ok and result == true then
                break
            end
        end
    end
end

local function HoldBreak()
    if holdTarget == nil then
        return
    end
    local now = os.clock()
    if now >= holdUntil or not valid(holdTarget) then
        -- Clearing the last instance keeps the break state from lingering for its own 4 s after the
        -- window ends, which would block the next clash from landing a fresh break.
        if valid(holdTarget) and holdHandle ~= nil then
            local abilities = readField(holdTarget, "AbilitySystemComponent")
            if valid(abilities) then
                pcall(function() abilities:RemoveActiveGameplayEffect(holdHandle, 1) end)
            end
        end
        LogEvent("hold break: done, %d repeats on %s", holdRepeats, holdName or "?")
        holdTarget, holdName, holdComp, holdHandle = nil, nil, nil, nil
        return
    end
    if now < holdNextAt then
        return
    end
    holdNextAt = now + Settings.BreakRepeatSeconds
    local before = CurrentHitState(holdComp)
    local removed = false
    local abilities = readField(holdTarget, "AbilitySystemComponent")
    if valid(abilities) then
        removed = RemoveBreak(abilities)
    end
    local afterRemove = CurrentHitState(holdComp)
    holdRepeats = holdRepeats + 1
    if ApplyBreak(holdTarget, string.format("hold %d", holdRepeats), true) then
        holdHandle = lastBreakHandle
    end
    local candidate = breakCandidates[1]
    if valid(holdComp) and candidate ~= nil then
        local ok, result = pcall(function()
            return holdComp:ChangeHitState(candidate.tag, nil, true)
        end)
        LogEvent("hold state %d: %s ok=%s result=%s now=%s", holdRepeats, candidate.name,
            tostring(ok), tostring(result), CurrentHitState(holdComp))
    end
    LogEvent("hold break: repeat %d removed=%s hitState %s | %s | %s", holdRepeats, tostring(removed),
        tostring(before), tostring(afterRemove), CurrentHitState(holdComp))
end

-- A clash while attacking (the same event that grants the charges) does not go through the parry
-- action, so the attacker has to come from the consumed deflect frame: its SourceAction leads up the
-- outer chain to the enemy actor.
local function FindActorFrom(object)
    local current = object
    for _ = 1, 10 do
        local outer = safe(function() return current:GetOuter() end)
        if outer == nil then
            return nil
        end
        local name = FullName(outer)
        if name:find("BP_Monster", 1, true) then
            return outer
        end
        current = outer
    end
    return nil
end

local function FindDeflectFrameAttacker(self)
    local frames = readField(self, "ReceiveFrames")
    if frames == nil then
        return nil, "no ReceiveFrames"
    end
    local actions = {}
    pcall(function()
        frames:ForEach(function(_, value)
            local action = value and readField(value, "SourceAction") or nil
            if action ~= nil then
                actions[#actions + 1] = action
            end
        end)
    end)
    if #actions == 0 then
        return nil, "no source action"
    end
    for _, action in ipairs(actions) do
        local actor = FindActorFrom(action)
        if actor then
            return actor
        end
    end
    return nil, "no actor from " .. FullName(actions[1])
end

-- The frame entry is already gone when the hook runs, so fall back to the closest enemy: every character
-- with a hit reaction component is an enemy; the player is excluded by name and by distance.
local function FindClashTarget()
    local comps = safe(FindAllOf, "HitreactComponent")
    if not comps then
        return nil, "no hitreact components"
    end
    local pawn = GetPlayerPawn()
    local playerName = valid(pawn) and FullName(pawn) or nil
    local playerLoc = nil
    if valid(pawn) then
        local root = readField(pawn, "RootComponent")
        playerLoc = root and readField(root, "RelativeLocation") or nil
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
                        local loc = root and readField(root, "RelativeLocation") or nil
                        if loc then
                            local dx, dy, dz = loc.X - playerLoc.X, loc.Y - playerLoc.Y, loc.Z - playerLoc.Z
                            dist = dx * dx + dy * dy + dz * dz
                        end
                    end
                    if best == nil or dist < bestDist then
                        best, bestDist = owner, dist
                    end
                end
            end
        end
    end
    if best then
        return best
    end
    return nil, "no enemy with a hitreact component"
end

BreakFromDeflectFrame = function(self, handle)
    if not Settings.BreakOnDeflect then
        return
    end
    local attacker, reason = FindDeflectFrameAttacker(self)
    if not valid(attacker) then
        local nearest, scanReason = FindClashTarget()
        if not valid(nearest) then
            LogEvent("clash: no attacker (%s)", tostring(scanReason))
            return
        end
        LogEvent("clash: frame had %s, using nearest %s", tostring(reason), FullName(nearest))
        attacker = nearest
    end
    if ApplyBreak(attacker, "clash") then
        StartBreakHold(attacker, Settings.BreakHoldSeconds)
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Heavy attack cost
---------------------------------------------------------------------------------------------------------------------

-- The ability's own cost fields are what the game scales per combo step; accessories instead grant the
-- HeavyAttack_ShachiCostReduction attribute and the ability applies that on top of these numbers.
local function PlayerCostReduction()
    local pawn = GetPlayerPawn()
    if not valid(pawn) then
        return nil
    end
    local set = readField(pawn, "AttributeSetBase")
    if not valid(set) then
        return nil
    end
    return readNumber(set, "HeavyAttack_ShachiCostReduction")
end

-- The attribute may sit on a different set instance than AttributeSetBase, so every set owned by the
-- player is printed once with both its current and base value.
local function DumpCostReduction()
    local sets = safe(FindAllOf, "BasicAttributeSet")
    if not sets then
        LogEvent("cost reduction: no BasicAttributeSet instances")
        return
    end
    local seen = false
    for _, set in ipairs(sets) do
        if valid(set) then
            local owner = safe(function() return set:GetOuter() end)
            local ownerName = valid(owner) and FullName(owner) or "?"
            if ownerName:find("Hun", 1, true) then
                seen = true
                local data = readField(set, "HeavyAttack_ShachiCostReduction")
                local current = data ~= nil and safe(function() return data.CurrentValue end) or nil
                local base = data ~= nil and safe(function() return data.BaseValue end) or nil
                LogEvent("cost reduction %s: current=%s base=%s", ownerName, tostring(current), tostring(base))
            end
        end
    end
    if not seen then
        LogEvent("cost reduction: no player BasicAttributeSet")
    end
end

-- The active effects are the direct answer to what an accessory actually does.
local function DumpActiveEffects(abilities)
    local ok, effects = pcall(function() return abilities:GetActiveGameplayEffects() end)
    if not ok or effects == nil then
        LogEvent("active effects: unavailable")
        return
    end
    local count = nil
    pcall(function() count = #effects end)
    if type(count) ~= "number" then
        count = safe(function() return effects:GetArrayNum() end)
    end
    LogEvent("active effects count=%s", tostring(count))
    if type(count) ~= "number" then
        return
    end
    for index = 1, count do
        local entry = safe(function() return effects[index] end)
        if entry == nil then
            break
        end
        local spec = readField(entry, "Spec")
        local def = spec ~= nil and readField(spec, "Def") or nil
        LogEvent("  effect %d: %s", index, ObjectLabel(def))
    end
end

local costScaleLogged = false

-- The attribute is the lever the game itself uses for cost reductions. Writing it directly is the
-- closest thing to "the accessory, but permanent"; it is rewritten on every activation in case the
-- attribute aggregator puts it back.
local lastAttrReduction = nil

local function ApplyAttributeReduction(pawn)
    if not valid(pawn) then
        return
    end
    local set = readField(pawn, "AttributeSetBase")
    if not valid(set) then
        return
    end
    local data = readField(set, "HeavyAttack_ShachiCostReduction")
    if data == nil then
        return
    end
    local target = 1.0 - Settings.HeavyCostScale
    local ok = pcall(function() data.CurrentValue = target end)
    local current = safe(function() return data.CurrentValue end)
    if lastAttrReduction ~= current then
        lastAttrReduction = current
        LogEvent("attribute reduction: target=%.2f current=%s write=%s", target, tostring(current),
            tostring(ok))
    end
end

-- ForEachFunction only walks the class itself, so the parent chain is walked by hand to find the
-- function that actually consumes the Shachi.
local abilityFunctionsDumped = false
local function DumpAbilityFunctions(classObject)
    if abilityFunctionsDumped or classObject == nil then
        return
    end
    abilityFunctionsDumped = true
    local current = classObject
    for depth = 1, 3 do
        if current == nil then
            return
        end
        local names = {}
        local ok = pcall(function()
            current:ForEachFunction(function(fn)
                local name = safe(function() return fn:GetFullName() end)
                if name ~= nil then
                    names[#names + 1] = tostring(name)
                end
            end)
        end)
        LogEvent("ability class %d %s functions=%d ok=%s", depth, ObjectLabel(current), #names,
            tostring(ok))
        for index = 1, math.min(#names, 40) do
            LogEvent("  ability fn %s", names[index])
        end
        current = safe(function() return current:GetSuperClass() end)
    end
end

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

-- The game ignores the ability's cost fields and the cost-reduction attribute, so the cost is taken back
-- after it is charged: watch the bar for about a second and return the part HeavyCostScale keeps. A newer
-- activation cancels the watchers of the previous one, and a rise (regen) just moves the baseline.
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

local function HookHeavy(name)
    if hookedHeavy[name] then return end
    local objects = safe(FindAllOf, name)
    if not objects or #objects == 0 then return end
    local classPath = classPathOf(objects[1])
    if not classPath then return end
    hookedHeavy[name] = true
    local ok, err = pcall(RegisterHook, classPath .. ":K2_ActivateAbility", function(context)
        local self = Unwrap(context)
        if not valid(self) then return end
        local original = origCosts[classPath]
        if not original then
            original = {
                cost = readNumber(self, "Shachi Cost"),
                min = readNumber(self, "Shachi Cost Min"),
            }
            origCosts[classPath] = original
        end
        local before = PlayerShachi()
        ApplyAttributeReduction(GetPlayerPawn())
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
                DumpCostReduction()
                local owner = GetPlayerPawn()
                local abilities = valid(owner) and readField(owner, "AbilitySystemComponent") or nil
                if valid(abilities) then
                    DumpActiveEffects(abilities)
                end
                DumpAbilityFunctions(safe(function() return self:GetClass() end))
            end
        end
        if before ~= nil then
            for _, delay in ipairs({ 60, 150, 400 }) do
                ExecuteWithDelay(delay, function()
                    ExecuteInGameThread(function()
                        local after = PlayerShachi()
                        local consumed = valid(self) and readNumber(self, "Actual Shachi Consumed") or nil
                        if after ~= nil then
                            LogEvent("heavy cost +%dms: %.0f -> %.0f (delta %.0f) consumed=%s reduction=%s",
                                delay, before, after, before - after, tostring(consumed),
                                tostring(PlayerCostReduction()))
                        end
                    end)
                end)
            end
        end
        if before ~= nil and not freeAttack then
            ScheduleShachiRefund(before)
        end
    end)
    if ok then
        LogEvent("hooked heavy %s", name)
    else
        logError("heavy hook " .. name .. ": " .. tostring(err))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Global combat config (break durations)
---------------------------------------------------------------------------------------------------------------------

local combatConfig = nil
local combatConfigTuned = false
local configsDumped = false
local tunedHitAnims = {}

-- How many combat config assets this build carries and which one the game actually points at. The
-- tuning writes into the first instance found, so this line proves it is the right one.
local function DumpCombatConfigs()
    if configsDumped then
        return
    end
    local configs = safe(FindAllOf, COMBAT_CONFIG_CLASS)
    if not configs or #configs == 0 then
        return
    end
    configsDumped = true
    for _, config in ipairs(configs) do
        LogEvent("combat config instance: %s break=%s/%s lie=%s", FullName(config),
            tostring(readField(config, "Player Break Duration")), tostring(readField(config, "Mob Break Duration")),
            tostring(readField(config, "Lie Duration")))
    end
    local combined = safe(FindFirstOf, "PDA_GlobalConfig_Combined_C")
    if valid(combined) then
        LogEvent("combined config %s references %s", FullName(combined), FullName(readField(combined, "Combat Config")))
    else
        LogEvent("combined config not found")
    end
end

local function WriteNumber(object, name, value)
    local before = readField(object, name)
    local ok, err = pcall(function() object[name] = value end)
    local after = readField(object, name)
    LogEvent("%s %s -> %s (ok=%s%s)", name, tostring(before), tostring(after), tostring(ok),
        ok and "" or (", " .. tostring(err)))
end

local function TuneCombatConfig()
    if Settings.PlayerBreakDuration <= 0 and Settings.MobBreakDuration <= 0 and Settings.LieDuration <= 0 then
        return
    end
    if not valid(combatConfig) then
        combatConfig = safe(FindFirstOf, COMBAT_CONFIG_CLASS)
        combatConfigTuned = false
        if not valid(combatConfig) then
            return
        end
        LogEvent("combat config: %s", FullName(combatConfig))
    end
    if combatConfigTuned then
        return
    end
    combatConfigTuned = true
    if Settings.PlayerBreakDuration > 0 then
        WriteNumber(combatConfig, "Player Break Duration", Settings.PlayerBreakDuration)
    end
    if Settings.MobBreakDuration > 0 then
        WriteNumber(combatConfig, "Mob Break Duration", Settings.MobBreakDuration)
    end
    if Settings.LieDuration > 0 then
        WriteNumber(combatConfig, "Lie Duration", Settings.LieDuration)
    end
end

-- The deflect damage calculators hold CanBreakAttacker / CanBreakTarget, which decide whether a deflect
-- can break either side. Dumped once: if the forced break ever needs a different lever, this is the place.
-- The player's stun comes from hit reaction animations, not from poise break. The timings below are the
-- windows after a hit: ComboTime is when the player can act, CancelTime when the animation can be cut.
-- They are only ever lowered, so a short animation never gets longer.
local PLAYER_HIT_TIMINGS = {
    "VeryLightComboTime", "VeryLightCancelTime",
    "LightComboTime", "LightCancelTime",
    "MiddleComboTime", "MiddleCancelTime",
    "HeavyComboTime", "HeavyCancelTime",
    "KnockbackComboTime", "KnockbackCancelTime",
    "GetupDashEscapeTime", "GetupComboTime", "GetupCancelTime",
    "NormalBreakComboTime", "NormalBreakCancelTime",
    "KnockbackBreakComboTime", "KnockbackBreakCancelTime",
    "DeflectBreakComboTime", "DeflectBreakCancelTime",
    "BreakStateEndComboTime", "BreakStateEndCancelTime",
    "FrightenedComboTime", "FrightenedCancelTime",
}

-- Which hit reaction the forced break actually plays is not visible from Lua, so every break animation
-- on the mob gets the same floor: whichever state the game picks, the enemy stays down for the time.
local MOB_BREAK_TIMINGS = {
    "DeflectBreakComboTime", "DeflectBreakCancelTime",
    "NormalBreakComboTime", "NormalBreakCancelTime",
    "KnockbackBreakComboTime", "KnockbackBreakCancelTime",
    "BreakStateEndComboTime", "BreakStateEndCancelTime",
}

local function TunePlayerHitAnim(set, key)
    local limit = Settings.PlayerHitreactTime
    if limit <= 0 then
        return
    end
    LogEvent("player hit anim %s: knockback=%s/%s getup=%s/%s break=%s/%s", key,
        tostring(readField(set, "KnockbackComboTime")), tostring(readField(set, "KnockbackCancelTime")),
        tostring(readField(set, "GetupComboTime")), tostring(readField(set, "GetupCancelTime")),
        tostring(readField(set, "NormalBreakComboTime")), tostring(readField(set, "NormalBreakCancelTime")))
    for _, field in ipairs(PLAYER_HIT_TIMINGS) do
        local value = readField(set, field)
        if type(value) == "number" and value > limit then
            WriteNumber(set, field, limit)
        end
    end
end

-- Every mob hit reaction set carries the break timings; the sets load with the mobs they belong to, so
-- the scan keeps running. The deflect-break value is only ever raised: a lower value would shorten the
-- stagger instead of extending it.
local function TuneMobHitAnim()
    local sets = safe(FindAllOf, "PDA_HitAnim_MobNew_C")
    if not sets then
        return
    end
    for _, set in ipairs(sets) do
        if valid(set) then
            local key = FullName(set)
            if not tunedHitAnims[key] then
                tunedHitAnims[key] = true
                if key:find("/Players/Hun/", 1, true) then
                    TunePlayerHitAnim(set, key)
                else
                    LogEvent("hit anim %s: deflectBreak=%s/%s normalBreak=%s/%s knockbackBreak=%s/%s breakEnd=%s/%s",
                        key, tostring(readField(set, "DeflectBreakComboTime")),
                        tostring(readField(set, "DeflectBreakCancelTime")),
                        tostring(readField(set, "NormalBreakComboTime")),
                        tostring(readField(set, "NormalBreakCancelTime")),
                        tostring(readField(set, "KnockbackBreakComboTime")),
                        tostring(readField(set, "KnockbackBreakCancelTime")),
                        tostring(readField(set, "BreakStateEndComboTime")),
                        tostring(readField(set, "BreakStateEndCancelTime")))
                    if Settings.MobDeflectBreakTime > 0 then
                        for _, field in ipairs(MOB_BREAK_TIMINGS) do
                            local value = readField(set, field)
                            -- 0 means "not configured" on these assets; leave it alone.
                            if type(value) == "number" and value > 0 and value < Settings.MobDeflectBreakTime then
                                WriteNumber(set, field, Settings.MobDeflectBreakTime)
                            end
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------------------------------------------------------

local function Tick()
    TryDeflectHook()
    for _, name in ipairs(HEAVY_CLASSES) do
        HookHeavy(name)
    end
    TuneCombatConfig()
    TuneMobHitAnim()
    DumpCombatConfigs()
end

local function TickSafe()
    local ok, err = pcall(Tick)
    if not ok then logError(err) end
end

local function SampleSafe()
    local ok, err = pcall(CheckBurning)
    if not ok then logError(err) end
    ok, err = pcall(HoldBreak)
    if not ok then logError(err) end
    ok, err = pcall(DumpHitreact)
    if not ok then logError(err) end
end

log(VERSION .. " loaded")

if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(1500, TickSafe)
    -- Faster than the hook loop, so the fire duration in the log is close to the real one.
    LoopInGameThreadWithDelay(300, SampleSafe)
else
    LoopAsync(1500, function()
        ExecuteInGameThread(TickSafe)
        return false
    end)
end
