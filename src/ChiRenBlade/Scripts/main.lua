local UEHelpers = require("UEHelpers")

local MOD = "ChiRenBlade"
local VERSION = "0.31"

local DEFAULTS = {
    Charges = 6,
    FireEnabled = true,
    FireSeconds = 5,
    CooldownSeconds = 0.6,
    TriggerOnDeflect = true,
    HeavyCostScale = 0.5,
    DeflectWindowFrames = 0,
    LogEvents = true,
}

-- The game's global combat config asset holds the block-parry perfect window.
local COMBAT_CONFIG_CLASS = "PDA_GlobalCombatConfig_C"

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
    HeavyCostScale = { 0.05, 1.0 },
    DeflectWindowFrames = { 0, 60 },
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
            LogEvent("fire lasted %.2f s (asked %.1f)", os.clock() - fireAppliedAt, Settings.FireSeconds)
            fireAppliedAt = nil
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

local function TryDeflectHook()
    if hookedDeflect or not Settings.TriggerOnDeflect then return end
    local components = safe(FindAllOf, "DeflectComponent")
    if not components or #components == 0 then return end
    local classPath = classPathOf(components[1])
    if not classPath then return end
    hookedDeflect = true
    local ok, err = pcall(RegisterHook, classPath .. ":ConsumeReceivedFrame", function(context)
        local self = Unwrap(context)
        local name = FullName(self)
        if not name:find("BP_Renewal_Hun") then
            return
        end
        GrantCharges("deflect frame consumed")
    end)
    if ok then
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

local costScaleLogged = false

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
            for _, delay in ipairs({ 60, 150, 400 }) do
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
    end)
    if ok then
        LogEvent("hooked heavy %s", name)
    else
        logError("heavy hook " .. name .. ": " .. tostring(err))
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
-- Loops
---------------------------------------------------------------------------------------------------------------------

local function Tick()
    TryDeflectHook()
    for _, name in ipairs(HEAVY_CLASSES) do
        HookHeavy(name)
    end
    TuneDeflectWindow()
end

local function TickSafe()
    local ok, err = pcall(Tick)
    if not ok then logError(err) end
end

local function SampleSafe()
    local ok, err = pcall(CheckBurning)
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
