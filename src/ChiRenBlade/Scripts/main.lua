local UEHelpers
do
    local required = { "RegisterHook", "FindAllOf", "StaticFindObject" }
    if type(ExecuteInGameThreadWithDelay) ~= "function" then
        required[#required + 1] = "ExecuteWithDelay"
        required[#required + 1] = "ExecuteInGameThread"
    end
    if type(LoopInGameThreadWithDelay) ~= "function" then
        required[#required + 1] = "ExecuteInGameThread"
    end
    for _, name in ipairs(required) do
        if type(_G[name]) ~= "function" then
            print("[ChiRenBlade] Disabled: missing UE4SS API " .. name .. "\n")
            return
        end
    end
    -- FName is a callable userdata in UE4SS, not a Lua function; only require that it exists.
    if FName == nil then
        print("[ChiRenBlade] Disabled: missing UE4SS API FName\n")
        return
    end
    if EFindName == nil or EFindName.FNAME_Add == nil
        or (type(LoopInGameThreadWithDelay) ~= "function" and type(LoopAsync) ~= "function") then
        print("[ChiRenBlade] Disabled: incompatible UE4SS name/timer API\n")
        return
    end
    local ok, helpers = pcall(require, "UEHelpers")
    if not ok or type(helpers) ~= "table" or type(helpers.GetPlayerController) ~= "function" then
        print("[ChiRenBlade] Disabled: UEHelpers.GetPlayerController unavailable\n")
        return
    end
    UEHelpers = helpers
end

local MOD = "ChiRenBlade"
local VERSION = "1.1"

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
    SwitchDeflectFrames = 15,
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
    HighlightTornadoReady = true,
    BreakOnClash = true,
    BreakThreshold = 3,
    BreakHoldSeconds = 1.2,
    ClashSlowmoEnabled = false,
    ClashSlowmoSpeed = 0.3,
    ClashSlowmoSeconds = 0.4,
    SwitchSlowmoEnabled = true,
    SwitchSlowmoSpeed = 0.6,
    SwitchSlowmoSeconds = 0.2,
    SlowmoRushSpeed = 1.0,
    SlowmoRushSeconds = 0.15,
    SwitchTornadoEnabled = true,
    SwitchTornadoDelaySeconds = 0.6,
    SwitchTornadoDistance = 215,
    SwitchTornadoDrop = 120,
    SwitchTornadoDamageScale = 2.0,
    SwitchTornadoDamageBase = 1100,
    SwitchTornadoRadius = 300,
    SwitchTornadoAngle = 360,
    SwitchTornadoTicks = 16,
    SwitchTornadoTickSeconds = 2.0,
    SwitchTornadoCalibratedAttack = 100,
    SwitchTornadoSpeed = 600,
    SwitchTornadoBurnSeconds = 5,
    SwitchTornadoBurnEvery = 4,
    SwitchTornadoStopDistance = 100,
    LogImportant = true,
    LogEvents = false,
    EnemyBurnVisual = true,
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

local errors = 0
local STABILITY = { errorCounts = {}, hookFailures = {}, discovery = {}, loopFailures = {} }
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
    message = tostring(message)
    local key = message:match("^[^\r\n]+") or message
    if STABILITY.errorCounts[key] then return end
    if errors >= 51 then return end
    STABILITY.errorCounts[key] = true
    errors = errors + 1
    if errors <= 50 then
        log("ERROR %s", message)
    elseif errors == 51 then
        log("ERROR: further distinct errors suppressed; restart before collecting another log")
    end
end

-- Registration failures may be lazy loading OR incompatibility. Retry slowly, then stop for
-- this path; never run the same missing reflection lookup on every discovery tick forever.


function STABILITY.DiscoveryReady(key)
    -- Stagger first expiry by key length so the 18 heavy/attack lookups do not all fire on the same
    -- frame (a burst of FindAllOf over the global object array spikes the game thread on a fresh save).
    local state = STABILITY.discovery[key] or { delay = 1.5, nextAt = (#key % 7) * 0.4 }
    local now = os.clock()
    if now < state.nextAt then return false end
    state.nextAt = now + state.delay
    -- A class that never loads (skills not yet unlocked on a new playthrough) must keep retrying so it
    -- hooks once unlocked, but only rarely: 60s cap halves the old 30s steady-state FindAllOf cost
    -- while keeping the worst-case hook registration delay under a minute.
    state.delay = math.min(state.delay * 2, 60)
    STABILITY.discovery[key] = state
    return true
end
function STABILITY.HookExhausted(path)
    local state = STABILITY.hookFailures[path]
    return state ~= nil and state.attempts >= 3
end
function STABILITY.TryRegisterHook(path, callback)
    local state = STABILITY.hookFailures[path]
    local now = os.clock()
    if state and (state.attempts >= 3 or now < state.nextAt) then
        return false, "hook unavailable (retry deferred or limit reached): " .. path
    end
    local callbackFailures = 0
    local ok, result = pcall(RegisterHook, path, function(...)
        if callbackFailures >= 3 then return end
        local result = table.pack(pcall(callback, ...))
        if not result[1] then
            callbackFailures = callbackFailures + 1
            logError("hook callback " .. path .. ": " .. tostring(result[2]))
            if callbackFailures == 3 then
                logError("hook callback disabled after 3 failures: " .. path)
            end
            return
        end
        return table.unpack(result, 2, result.n)
    end)
    if ok then
        STABILITY.hookFailures[path] = nil
        return true, result
    end
    state = state or { attempts = 0 }
    state.attempts = state.attempts + 1
    state.nextAt = now + (state.attempts == 1 and 5 or 30)
    STABILITY.hookFailures[path] = state
    return false, tostring(result):match("^[^\r\n]+") or tostring(result)
end

local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        logError(result)
        return nil
    end
    return result
end

function STABILITY.After(delay, callback)
    local function run()
        local ok, err = pcall(callback)
        if not ok then logError("delayed callback: " .. tostring(err)) end
    end
    if type(ExecuteInGameThreadWithDelay) == "function" then
        return safe(ExecuteInGameThreadWithDelay, delay, run)
    end
    -- Older builds keep the original route; this is not a guarantee against runtime races.
    return safe(ExecuteWithDelay, delay, function()
        safe(ExecuteInGameThread, run)
    end)
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
    return path:gsub("^%S+%s+", "")
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

function STABILITY.IsFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
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
    SwitchSlowmoSpeed = { 0.05, 1.0 },
    SwitchSlowmoSeconds = { 0.05, 2.0 },
    SlowmoRushSpeed = { 1.0, 3.0 },
    SlowmoRushSeconds = { 0.05, 1.0 },
    SwitchTornadoDelaySeconds = { 0, 3 },
    SwitchTornadoDistance = { 0, 600 },
    SwitchTornadoDrop = { 0, 300 },
    SwitchTornadoDamageScale = { 0, 5 },
    SwitchTornadoDamageBase = { 0, 20000 },
    SwitchTornadoRadius = { 0, 1000 },
    SwitchTornadoAngle = { 1, 360 },
    SwitchTornadoTicks = { 1, 20 },
    SwitchTornadoTickSeconds = { 0.2, 3.0 },
    SwitchTornadoCalibratedAttack = { 1, 10000 },
    SwitchTornadoSpeed = { 0, 1000 },
    SwitchTornadoBurnSeconds = { 0, 30 },
    SwitchTornadoBurnEvery = { 1, 20 },
    SwitchTornadoStopDistance = { 0, 500 },
}

local Settings = {}
for name, value in pairs(DEFAULTS) do
    Settings[name] = value
end
local okConfig, config
do
    local src = debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source
    local dir = type(src) == "string" and src:sub(1, 1) == "@" and src:sub(2):match("^(.*[/\\])") or nil
    if dir and type(loadfile) == "function" then
        local chunk, loadErr = loadfile(dir .. "config.lua")
        if chunk then
            okConfig, config = pcall(chunk)
        else
            okConfig, config = false, loadErr
        end
    else
        okConfig, config = pcall(require, "config")
    end
end
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
            if limit and (not STABILITY.IsFiniteNumber(value) or value < limit[1] or value > limit[2]) then
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

-- Key functional events (clash grants, tornado, invuln, fire, keep-tier, hook registration, player
-- change). Low-frequency and on by default so a released build still leaves enough to locate bugs.
local function LogKey(fmt, ...)
    if Settings.LogImportant then
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
    -- The bundled helper scans PlayerController objects on each call. Cache the controller
    -- briefly, but always read its current Pawn so replacement pawns remain visible.
    local now = os.clock()
    local controller = STABILITY.controller
    if not valid(controller) or now >= (STABILITY.controllerRefreshAt or 0) then
        if now < (STABILITY.controllerLookupAt or 0) then return nil end
        STABILITY.controllerLookupAt = now + 1.0
        controller = safe(UEHelpers.GetPlayerController)
        STABILITY.controller = valid(controller) and controller or nil
        STABILITY.controllerRefreshAt = now + 1.0
    end
    if not valid(controller) then return nil end
    local pawn = safe(function() return controller.Pawn end)
    if not valid(pawn) then return nil end
    return pawn
end

-- Compare the freshly obtained pawn first. Delayed work must not write into a replacement
-- pawn after death/loading. Keep both address and full name to reduce address-reuse risk.
function STABILITY.PlayerKey()
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return nil end
    local address = safe(function() return pawn:GetAddress() end)
    local name = FullName(pawn)
    if address == nil or name == "?" then return nil end
    return tostring(address) .. "|" .. name
end

function STABILITY.SamePlayer(key)
    return key ~= nil and STABILITY.PlayerKey() == key
end

local function IsPlayerActor(actor)
    if not valid(actor) then return false end
    local pawn = GetPlayerPawn()
    if valid(pawn) then
        local a1 = safe(function() return actor:GetAddress() end)
        local a2 = safe(function() return pawn:GetAddress() end)
        if a1 ~= nil and a2 ~= nil then
            return a1 == a2
        end
    end
    return FullName(actor):find("BP_Renewal_Hun", 1, true) ~= nil
end

local function CheckBurning()
    if not Settings.FireEnabled or (not Settings.LogEvents and not fireAppliedAt) then return end
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
        LogEvent("burning=%s", tostring(count))
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

-- GameplayEffect defaults are shared assets. Never apply a timed effect unless its temporary
-- duration override was both writable and readable; otherwise a reflection mismatch could leave
-- the effect at its asset default (including an unintended infinite duration).
function SetTemporaryDuration(magnitude, seconds, label)
    if STABILITY.durationOverridesBroken or not STABILITY.IsFiniteNumber(seconds) or seconds <= 0 then return nil end
    local originalCalc = readField(magnitude, "MagnitudeCalculationType")
    local originalValue = safe(function() return magnitude.ScalableFloatMagnitude.Value end)
    if not STABILITY.IsFiniteNumber(originalCalc) or not STABILITY.IsFiniteNumber(originalValue) then
        LogEvent("%s: duration default unreadable; effect skipped", label)
        return nil
    end
    local function restore()
        -- Do not overwrite a value another callback changed while the GE was being applied.
        local calc = readField(magnitude, "MagnitudeCalculationType")
        local value = safe(function() return magnitude.ScalableFloatMagnitude.Value end)
        if calc == 0 then pcall(function() magnitude.MagnitudeCalculationType = originalCalc end) end
        if STABILITY.IsFiniteNumber(value) and math.abs(value - seconds) <= 0.001 then
            pcall(function() magnitude.ScalableFloatMagnitude.Value = originalValue end)
        end
        local afterCalc = readField(magnitude, "MagnitudeCalculationType")
        local afterValue = safe(function() return magnitude.ScalableFloatMagnitude.Value end)
        local restored = afterCalc == originalCalc and STABILITY.IsFiniteNumber(afterValue)
            and math.abs(afterValue - originalValue) <= 0.001
        if not restored then
            -- A shared asset left uncertain must not become the baseline for another override.
            STABILITY.durationOverridesBroken = true
            logError(label .. ": duration restore failed or changed externally; temporary GE duration overrides disabled")
        end
        return restored
    end
    local okCalc, errCalc = pcall(function() magnitude.MagnitudeCalculationType = 0 end)
    local okValue, errValue = pcall(function() magnitude.ScalableFloatMagnitude.Value = seconds end)
    local writtenCalc = readField(magnitude, "MagnitudeCalculationType")
    local writtenValue = safe(function() return magnitude.ScalableFloatMagnitude.Value end)
    if not okCalc or not okValue or writtenCalc ~= 0 or not STABILITY.IsFiniteNumber(writtenValue)
        or math.abs(writtenValue - seconds) > 0.001 then
        restore()
        LogEvent("%s: duration override rejected; effect skipped (%s)", label,
            tostring(not okCalc and errCalc or (not okValue and errValue or "readback mismatch")))
        return nil
    end
    return restore
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
    local restoreDuration = SetTemporaryDuration(magnitude, applySeconds, "fire")
    if not restoreDuration then return end
    local ok, err = pcall(function()
        abilities:BP_ApplyGameplayEffectToSelf(ge, 1.0, context)
    end)
    restoreDuration()
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
        logError("fire apply failed: " .. tostring(err))
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
    local restoreDuration = SetTemporaryDuration(magnitude, seconds, "timed GE")
    if not restoreDuration then return nil end
    local context = safe(function() return abilities:MakeEffectContext() end)
    local ok, result = false, nil
    if context then
        ok, result = pcall(function()
            return abilities:BP_ApplyGameplayEffectToSelf(ge, 1.0, context)
        end)
    end
    restoreDuration()
    if not ok then
        logError("effect apply failed: " .. tostring(context and result or "no effect context"))
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

local invulnGuardToken = 0
local hitreactHooked = false
local hitreactAttempts = 0
local FNameText, CurrentHitState
-- Match the native deflect hit reaction to the current player's counter or switch ability.
-- Retain it briefly for the subsequent ConsumeReceivedFrame callback.
function STABILITY.MarkDeflectSource(target, component, parameter)
    if not Settings.TriggerOnDeflect or not valid(target) then return end
    local source = Unwrap(parameter)
    if not valid(source) then return end
    local name = FullName(source)
    if not name:match("^BP_DeflectHitreactAttackSource_C ") then return end
    local sourcePawn, ability = name:match("^%S+%s+(.+)%.(GA_Hun_[%w_]+_C)_%d+%.BP_DeflectHitreactAttackSource_C_%d+$")
    if sourcePawn == nil then return end

    local pawn = GetPlayerPawn()
    if not valid(pawn) or FullName(pawn):match("^%S+%s+(.+)$") ~= sourcePawn then return end
    if ability ~= "GA_Hun_Long_Counter_C" and ability ~= "GA_Hun_ChiRen_SWT_C" then
        STABILITY.deflectSource = nil
        return
    end
    local playerKey = STABILITY.PlayerKey()
    if playerKey == nil then return end
    STABILITY.deflectSource = {
        at = os.clock(), playerKey = playerKey, target = target, component = component,
        switch = ability == "GA_Hun_ChiRen_SWT_C",
    }
end

local function SkipHitreact(name, context, ...)
    local self = Unwrap(context)
    local owner = safe(function() return self:GetOuter() end)
    local isPlayer = IsPlayerActor(owner)
    if name == "PlayHitreactToAvatar" and not isPlayer then
        STABILITY.MarkDeflectSource(owner, self, select(1, ...))
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
end

local function TryHitreactHook()
    if hitreactHooked then
        return
    end
    if not STABILITY.DiscoveryReady("hitreact") then return end
    local comps = safe(FindAllOf, "HitreactComponent")
    if not comps then
        return
    end
    for _, comp in ipairs(comps) do
        if valid(comp) then
            local owner = safe(function() return comp:GetOuter() end)
            if IsPlayerActor(owner) then
                local path = classPathOf(comp)
                if path then
                    hitreactAttempts = hitreactAttempts + 1
                    local anyOk = false
                    for _, fn in ipairs({ "PlayHitreact", "PlayHitreactToAvatar" }) do
                        local ok, err = STABILITY.TryRegisterHook(path .. ":" .. fn, function(context, ...)
                            return SkipHitreact(fn, context, ...)
                        end)
                        if ok then
                            anyOk = true
                            LogEvent("invuln: hooked player %s", fn)
                        else
                            LogEvent("invuln: hook %s failed (%s)", fn, tostring(err))
                        end
                    end
                    if anyOk then
                        hitreactHooked = true
                    elseif STABILITY.HookExhausted(path .. ":PlayHitreact")
                        and STABILITY.HookExhausted(path .. ":PlayHitreactToAvatar") then
                        hitreactHooked = true
                        logError("hitreact hooks unavailable; discovery stopped for this session")
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
        STABILITY.After(16, function()
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
    local owner = STABILITY.invulnOwner
    if owner and STABILITY.SamePlayer(owner.key) and valid(owner.asc) then
        local ok, err = pcall(function()
            owner.asc:RemoveActiveGameplayEffect(invulnHandle, 1)
        end)
        if not ok then logError("invuln removal failed: " .. tostring(err)) end
        LogEvent("invuln: removed ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err)))
    end
    invulnHandle = nil
    STABILITY.invulnOwner = nil
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
        logError("invuln unavailable: no invulnerability GE found")
        return
    end
    invulnToken = invulnToken + 1
    local token = invulnToken
    RemoveInvuln()
    local before = Settings.LogEvents and InvulnerableCount(abilities)
    local result = ApplyTimedGe(abilities, ge, seconds)
    if result == nil then
        return
    end
    invulnHandle = result
    STABILITY.invulnOwner = { asc = abilities, key = STABILITY.PlayerKey() }
    if Settings.LogEvents then
        LogEvent("invuln: applied %.1f s handle=%s tag %s -> %s", seconds, HandleText(result),
            tostring(before), tostring(InvulnerableCount(abilities)))
    end
    STABILITY.After(math.floor(seconds * 1000), function()
        if token ~= invulnToken then
            return
        end
        RemoveInvuln()
    end)
end

---------------------------------------------------------------------------------------------------------------------
-- Break on clash
---------------------------------------------------------------------------------------------------------------------

local lastBreakName = nil
local lastBreakAt = 0

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
    if Settings.LogEvents and not breakSourceLogged then
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

    -- Export the native hitreact source builder for the switch-GP tornado damage.
    STABILITY.makeBreakSource = MakeBreakSource

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
    local ownerKey = STABILITY.PlayerKey()
    local replays = 0
    local function step()
        STABILITY.After(BREAK_HOLD_REPEAT_MS, function()
            if token ~= breakToken or not STABILITY.SamePlayer(ownerKey)
                or not valid(target) or not valid(comp) then
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
    end
    step()
end

-- The interrupt charges up over several clashes and is refused inside the game's own unbashable
-- windows, so the source is retried twice before the meter is dropped.
local BREAK_DEDUPE_SECONDS = 0.8
local BREAK_RETRY_DELAYS_MS = { 150, 400 }

local function TryBreakClash(target, comp)
    if not Settings.BreakOnClash or not valid(target) then return end
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
    if not valid(comp) then
        LogEvent("break meter full: %s (%d/%d); no hitreact component", meterName, count,
            Settings.BreakThreshold)
        return
    end
    breakToken = breakToken + 1
    local token = breakToken
    breakStartedAt = now
    LogEvent("break meter full: %s (%d/%d); playing the native Break hitreact", meterName, count,
        Settings.BreakThreshold)
    local maintaining = false
    local ownerKey = STABILITY.PlayerKey()
    local function attempt(label)
        if token ~= breakToken or not STABILITY.SamePlayer(ownerKey) or not valid(target) then
            return false
        end
        if ApplyBreakSource(target, label) then
            if not maintaining then
                maintaining = true
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
        STABILITY.After(delay, function()
            attempt(string.format("retry +%d ms", delay))
        end)
    end
end

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
    combo = 0, increase = nil, logs = 0, broken = false, passiveMissLogs = 0,
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
    if not valid(TORNADO.increase) then
        TORNADO.broken = true
        logError("tornado easy: tier-up effect missing; easy cast disabled")
        return
    end
    if not valid(passive) then
        -- The ChiRen passive is inactive while another weapon (e.g. WhiteShadow) is equipped.
        -- That is transient: retry on the next clash once ChiRen is back, never latch broken here,
        -- otherwise a single clash during a weapon swap permanently disables easy cast.
        if TORNADO.passiveMissLogs < 3 then
            TORNADO.passiveMissLogs = TORNADO.passiveMissLogs + 1
            LogEvent("tornado easy: ChiRen passive inactive (weapon swapped); will retry next clash")
        end
        return
    end
    TORNADO.passiveMissLogs = 0
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
    active = false, endsAt = 0, worldSettings = nil, broken = false, logs = 0, speed = nil,
    rushing = false, originalSpeed = nil, worldId = nil,
}

function CLASH_SLOWMO.getWorldSettings()
    local controller = safe(UEHelpers.GetPlayerController)
    if not valid(controller) then return nil end
    local world = safe(function() return controller:GetWorld() end)
    if not valid(world) then return nil end
    local level = readField(world, "PersistentLevel")
    if not valid(level) then return nil end
    local ws = readField(level, "WorldSettings")
    return valid(ws) and ws or nil
end

function CLASH_SLOWMO.keyOf(ws)
    if not valid(ws) then return nil end
    local address = safe(function() return ws:GetAddress() end)
    local name = FullName(ws)
    if address == nil or name == "?" then return nil end
    return tostring(address) .. "|" .. name
end

function CLASH_SLOWMO.restore()
    CLASH_SLOWMO.active = false
    CLASH_SLOWMO.rushing = false
    -- Restore only the world captured at start, even if the controller now belongs to a new map.
    local ws = CLASH_SLOWMO.worldSettings
    local cur = valid(ws) and readNumber(ws, "DemoPlayTimeDilation") or nil
    local ours = CLASH_SLOWMO.speed or Settings.ClashSlowmoSpeed
    -- Only take back our own value; leave a factor the game or another mod set.
    if STABILITY.IsFiniteNumber(cur) and math.abs(cur - ours) < 0.001 then
        local original = CLASH_SLOWMO.originalSpeed
        if original ~= nil then
            local ok = pcall(function() ws.DemoPlayTimeDilation = original end)
            local after = readNumber(ws, "DemoPlayTimeDilation")
            if not ok or not STABILITY.IsFiniteNumber(after) or math.abs(after - original) > 0.001 then
                CLASH_SLOWMO.broken = true
                logError("clash slowmo: world factor restore rejected; optional slowmo disabled")
            end
        end
    end
    CLASH_SLOWMO.originalSpeed = nil
    CLASH_SLOWMO.worldSettings, CLASH_SLOWMO.worldId = nil, nil
end

function CLASH_SLOWMO.frameStep()
    if not CLASH_SLOWMO.active then return false end
    local ws = CLASH_SLOWMO.getWorldSettings()
    if CLASH_SLOWMO.keyOf(ws) ~= CLASH_SLOWMO.worldId or not valid(CLASH_SLOWMO.worldSettings) then
        CLASH_SLOWMO.restore()
        return false
    end
    local cur = readNumber(ws, "DemoPlayTimeDilation")
    local speed = CLASH_SLOWMO.speed or Settings.ClashSlowmoSpeed
    -- Another writer takes ownership immediately; never fight it every 16 ms.
    if not STABILITY.IsFiniteNumber(cur) or math.abs(cur - speed) > 0.001 then
        CLASH_SLOWMO.restore()
        return false
    end
    if os.clock() >= CLASH_SLOWMO.endsAt then
        -- Slow-motion is over: optionally hand over to a short "rush" so the hit reads as
        -- slow-then-fast instead of slow-then-normal, then restore.
        if not CLASH_SLOWMO.rushing and Settings.SlowmoRushSpeed > 1.0 and Settings.SlowmoRushSeconds > 0 then
            local ok = pcall(function() ws.DemoPlayTimeDilation = Settings.SlowmoRushSpeed end)
            local after = readNumber(ws, "DemoPlayTimeDilation")
            if STABILITY.IsFiniteNumber(after) and math.abs(after - Settings.SlowmoRushSpeed) < 0.001 then
                CLASH_SLOWMO.speed = Settings.SlowmoRushSpeed
            end
            if ok and CLASH_SLOWMO.speed == Settings.SlowmoRushSpeed then
                CLASH_SLOWMO.rushing = true
                CLASH_SLOWMO.endsAt = os.clock() + Settings.SlowmoRushSeconds
                return false
            end
        end
        CLASH_SLOWMO.restore()
        return false
    end
    return false
end

function CLASH_SLOWMO.start(enabled, speed, seconds)
    if not enabled or CLASH_SLOWMO.broken then return end
    speed = speed or Settings.ClashSlowmoSpeed
    seconds = seconds or Settings.ClashSlowmoSeconds
    local ws = CLASH_SLOWMO.getWorldSettings()
    if not valid(ws) then return end
    local worldId = CLASH_SLOWMO.keyOf(ws)
    if worldId == nil then return end
    local cur = readNumber(ws, "DemoPlayTimeDilation")
    if CLASH_SLOWMO.active and (worldId ~= CLASH_SLOWMO.worldId or not STABILITY.IsFiniteNumber(cur)
        or math.abs(cur - CLASH_SLOWMO.speed) > 0.001) then
        CLASH_SLOWMO.restore()
        if CLASH_SLOWMO.broken then return end
    end
    local original = CLASH_SLOWMO.active and CLASH_SLOWMO.originalSpeed or cur
    if not STABILITY.IsFiniteNumber(original) or original <= 0 then
        LogEvent("clash slowmo: current world factor unreadable; optional slowmo skipped")
        return
    end
    CLASH_SLOWMO.worldSettings, CLASH_SLOWMO.worldId = ws, worldId
    CLASH_SLOWMO.originalSpeed = original
    local previousSpeed = CLASH_SLOWMO.speed
    local wasActive = CLASH_SLOWMO.active
    CLASH_SLOWMO.speed = speed
    local ok = pcall(function() ws.DemoPlayTimeDilation = speed end)
    local after = readNumber(ws, "DemoPlayTimeDilation")
    if not ok or not STABILITY.IsFiniteNumber(after) or math.abs(after - speed) > 0.001 then
        if wasActive and STABILITY.IsFiniteNumber(after) and math.abs(after - previousSpeed) < 0.001 then
            CLASH_SLOWMO.speed = previousSpeed
        end
        CLASH_SLOWMO.restore()
        CLASH_SLOWMO.broken = true
        logError("clash slowmo: world factor write rejected")
        return
    end
    CLASH_SLOWMO.active = true
    CLASH_SLOWMO.rushing = false
    CLASH_SLOWMO.originalSpeed = original
    CLASH_SLOWMO.speed = speed
    CLASH_SLOWMO.endsAt = os.clock() + seconds
    if CLASH_SLOWMO.logs < 12 then
        CLASH_SLOWMO.logs = CLASH_SLOWMO.logs + 1
        LogEvent("clash slowmo: %.2f x %.2f s", speed, seconds)
    end
end

local function GrantCharges(source)
    local now = os.clock()
    local isSwitchGp = source.switch
    if now - lastClash < Settings.CooldownSeconds then return end
    lastClash = now
    charges = Settings.Charges
    LogEvent("clash: %d free heavy attacks%s", charges, isSwitchGp and " [switch GP]" or "")
    TryFire()
    TryInvulnerable()
    -- Both moves get the general clash rewards. The whirlwind streak and its
    -- easy-cast tier boost belong to the heavy-light counter.
    if not isSwitchGp then
        TORNADO.combo = math.min(TORNADO.combo + 1, Settings.TornadoClashMax)
        LogEvent("tornado combo: %d/%d", TORNADO.combo, Settings.TornadoClashMax)
    end
    TryBreakClash(source.target, source.component)
    if isSwitchGp then
        CLASH_SLOWMO.start(Settings.SwitchSlowmoEnabled, Settings.SwitchSlowmoSpeed, Settings.SwitchSlowmoSeconds)
        -- Match the execution's timing: the tornado erupts as the sweep follows through.
        if Settings.SwitchTornadoEnabled then
            local ownerKey = STABILITY.PlayerKey()
            STABILITY.After(math.floor(Settings.SwitchTornadoDelaySeconds * 1000), function()
                if not STABILITY.SamePlayer(ownerKey) then return end
                SpawnSwitchGpTornado()
            end)
        end
    else
        CLASH_SLOWMO.start(Settings.ClashSlowmoEnabled, Settings.ClashSlowmoSpeed, Settings.ClashSlowmoSeconds)
        TORNADO.topTier()
    end
end

-- On current builds the hit reaction precedes frame consumption by a few milliseconds.
-- Missing or expired evidence leaves the game's native deflect behavior alone.
local DEFLECT_SOURCE_SECONDS = 0.10

local function TryDeflectHook()
    if hookedDeflect or not Settings.TriggerOnDeflect then return end
    if not STABILITY.DiscoveryReady("deflect") then return end
    local components = safe(FindAllOf, "DeflectComponent")
    if not components or #components == 0 then return end
    local classPath = classPathOf(components[1])
    if not classPath then return end
    local ok, err = STABILITY.TryRegisterHook(classPath .. ":ConsumeReceivedFrame", function(context)
        local self = Unwrap(context)
        local owner = safe(function() return self:GetOuter() end)
        if not IsPlayerActor(owner) then return end
        local source = STABILITY.deflectSource
        STABILITY.deflectSource = nil
        if source == nil then
            if Settings.LogEvents and (STABILITY.unmatchedDeflectLogs or 0) < 12 then
                STABILITY.unmatchedDeflectLogs = (STABILITY.unmatchedDeflectLogs or 0) + 1
                LogEvent("deflect ignored: no matching clash or switch hit reaction")
            end
            return
        end
        local age = os.clock() - source.at
        if age < 0 or age > DEFLECT_SOURCE_SECONDS or not STABILITY.SamePlayer(source.playerKey)
            or not valid(source.target) then return end
        if source.switch and not (Settings.SwitchDeflectInject and Settings.SwitchDeflectFrames > 0)
            and not Settings.SwitchAttackBlock then return end
        GrantCharges(source)
    end)
    if ok then
        hookedDeflect = true
        LogKey("hooked ConsumeReceivedFrame")
    else
        logError("deflect hook: " .. tostring(err))
        if STABILITY.HookExhausted(classPath .. ":ConsumeReceivedFrame") then
            hookedDeflect = true
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Heavy attack cost
---------------------------------------------------------------------------------------------------------------------


-- The game ignores the ability's Shachi Cost fields, so a free/reduced heavy is made free by refunding
-- the cost after it is charged. The refund keys on the game's per-ability "Actual Shachi Consumed"
-- (snapshotted at the activation entry, since the ability UObject is reused across activations), NOT on
-- the raw bar dip: raw diff mis-attributes later hits and over-refunds when regen raises the baseline.
-- Each activation settles once (consumed * (1 - keepScale)), capped at the real Shachi_Max; a newer
-- activation does not cancel an older refund. SamePlayer guards map swap / death / load.

local function ScheduleShachiSettlement(consumed, keepScale)
    if not STABILITY.IsFiniteNumber(consumed) or consumed < 0 then return end
    if not STABILITY.IsFiniteNumber(keepScale) or keepScale < 0 or keepScale > 1 then return end
    local refund = consumed * (1 - keepScale)
    if refund <= 0 then return end
    local ownerKey = STABILITY.PlayerKey()
    if ownerKey == nil then return end
    -- Settle synchronously inside the activation callback: the native charge already landed before
    -- this callback (entry consumed is populated), so adding the refund here keeps the bar dip to
    -- roughly one frame instead of the previous 80ms. No delayed watcher or settlement retry.
    if not STABILITY.SamePlayer(ownerKey) then return end
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return end
    local set = safe(function() return pawn.AttributeSetBase end)
    if not valid(set) then return end
    local data = readField(set, "Shachi")
    local base = data ~= nil and safe(function() return data.BaseValue end) or nil
    local current = readNumber(set, "Shachi")
    local maxValue = readNumber(set, "Shachi_Max")
    if not STABILITY.IsFiniteNumber(current) or not STABILITY.IsFiniteNumber(maxValue) or maxValue <= 0 then
        return
    end
    -- Full bar: drop the refund entirely, do not bank it for a later hit; never shave a native
    -- temporary over-cap by writing back down to max.
    if current >= maxValue then return end
    -- BaseValue may already contain an uncommitted refund while CurrentValue is still catching up.
    -- Bound against both layers so repeated activations cannot stack pending Shachi above max.
    local baseValue = STABILITY.IsFiniteNumber(base) and base or current
    if baseValue >= maxValue then return end
    local add = math.min(refund, math.max(0, maxValue - current), math.max(0, maxValue - baseValue))
    if add <= 0 then return end
    -- Accepted in combat testing: native aggregation overwrites CurrentValue-only refunds.
    -- Add once to the persistent BaseValue, bounded against both current and pending values.
    local newBase = baseValue + add
    local ok = data ~= nil and pcall(function() data.BaseValue = newBase end)
    if not ok then logError("shachi settlement: BaseValue write failed") end
    LogEvent("shachi settle(base): consumed %.1f refund %.1f add %.1f base %.1f->%.1f cur %.1f max %.1f ok=%s",
        consumed, refund, add, baseValue, newBase, current, maxValue, tostring(ok))

end

---------------------------------------------------------------------------------------------------------------------
-- 风回云卷: bullet damage, fire state and cast bookkeeping
---------------------------------------------------------------------------------------------------------------------

local OnTornadoCast, RestoreTornadoBullets
STABILITY.tornadoCastInvuln = 0

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
                -- Record before the native write: verification itself can fail after mutation.
                entry.changed[name] = original
                value:set(original * factor)
                local now = value:get()
                if type(now) ~= "number" or math.abs(now - original * factor) > 0.01 then
                    LogEvent("tornado damage: %s %s write failed (%s -> %s)", entry.name, name,
                        tostring(original), tostring(now))
                    return
                end
                written = written + 1
                LogEvent("tornado damage: %s %s %.2f -> %.2f", entry.name, name, original, now)
            end)
        end)
        if not ok then LogEvent("tornado damage: %s scan failed (%s)", entry.name, tostring(err)) end
    end
    if written == 0 then
        LogEvent("tornado damage: no damage field was written")
        local attempted = false
        for _, entry in ipairs(entries) do
            if next(entry.changed) ~= nil then attempted = true end
        end
        if not attempted then return nil end
    end
    return { entries = entries, factor = factor, written = written }
end

RestoreTornadoBullets = function(reason)
    local patch = tornadoPatch
    if not patch then return true end
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
        else
            -- A destroyed asset cannot be restored; do not retain its wrapper forever.
            entry.changed = {}
        end
        for _ in pairs(entry.changed) do pending = pending + 1 end
    end
    if pending == 0 then
        tornadoPatch = nil
        tornadoPatchToken = tornadoPatchToken + 1
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
    if not STABILITY.IsFiniteNumber(seconds) or seconds <= 0 then return false end
    local handle, objects, pawn, abilities = ActiveFire()
    if not handle or not objects or not valid(pawn) or not valid(abilities) then
        LogEvent("tornado burn: active fire handle unavailable")
        return false
    end
    local lib = objects.gameplay
    local remaining = safe(function() return lib:GetActiveGameplayEffectRemainingDuration(pawn, handle) end)
    if not STABILITY.IsFiniteNumber(remaining) or remaining <= 0 then
        LogEvent("tornado burn: existing duration unreadable (%s)", tostring(remaining))
        return false
    end
    if remaining >= seconds - 0.2 then
        LogEvent("tornado burn: already burning %.1f s, no extension", remaining)
        return true
    end
    local total = safe(function() return lib:GetActiveGameplayEffectTotalDuration(handle) end)
    if not STABILITY.IsFiniteNumber(total) or total < remaining - 0.2 then
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
    if writeOk and STABILITY.IsFiniteNumber(now) and now > 0 and math.abs(now - seconds) > 0.25 then
        -- The first write can land a frame late; one corrective write closes the gap.
        writeOk, writeErr = pcall(function() utils:SetActiveGEDuration(abilities, handle, requested + seconds - now) end)
        now = safe(function() return lib:GetActiveGameplayEffectRemainingDuration(pawn, handle) end)
    end
    if not writeOk or not STABILITY.IsFiniteNumber(now) or math.abs(now - seconds) > 0.3 then
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
    STABILITY.tornadoCastAt = os.clock()
    STABILITY.tornadoCastAbility = valid(self) and self:GetAddress() or nil
    STABILITY.tornadoCastInvuln = Settings.TornadoInvulnSeconds
    LogEvent("tornado cast: streak=%d tier=%d multiplier=x%.2f free=%s%s", streak, tier, factor,
        tostring(freeAttack), reused and " followup" or "")
    TORNADO.combo = 0

    if Settings.TornadoInvulnSeconds > 0 then
        LogEvent("tornado invuln: %.1f s", Settings.TornadoInvulnSeconds)
        TryInvulnerable(Settings.TornadoInvulnSeconds)
    end

    local canPatch = not tornadoPatch or RestoreTornadoBullets("next-cast")
    if not canPatch then logError("tornado damage: pending restore; skipped new multiplier") end
    local patch = canPatch and factor ~= 1 and PatchTornadoBullets(factor) or nil
    if patch then
        tornadoPatch = patch
        tornadoPatchToken = tornadoPatchToken + 1
        local token = tornadoPatchToken
        STABILITY.After(math.floor(Settings.TornadoDamageSeconds * 1000), function()
            if token == tornadoPatchToken and tornadoPatch == patch then
                if STABILITY.tornadoCastAt then
                    LogKey("tornado end: not seen after %.1f s; restoring by timeout",
                        os.clock() - STABILITY.tornadoCastAt)
                    STABILITY.tornadoCastAt = nil
                    STABILITY.tornadoCastAbility = nil
                end
                RestoreTornadoBullets("timeout")
            end
        end)
    end

    ApplyTornadoBurn(Settings.TornadoBurnSeconds)
end

    -- Export the bullet-damage helpers for the switch-GP tornado damage; they are block-locals here.
    STABILITY.tornadoBullets = BSUP_BULLETS
    STABILITY.tornadoBulletRoot = BSUP_BULLET_ROOT
    STABILITY.eachBulletDamage = EachBulletDamage

end

local costScaleLogged = false
local heavyActivateLogs = 0

local function HeavyActivate(name, self, classPath)
    if not valid(self) then return end
        -- Snapshot this activation's consumed cost at the earliest callback moment: the charge has
        -- already landed here, and the ability UObject is reused across activations (a later read could
        -- belong to the next hit). The number copy decouples the refund from instance reuse.
        local consumedSnapshot = readNumber(self, "Actual Shachi Consumed")
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
            -- C derives from BP_CombatArt_Base, not BP_HeavyAttack_Base: it has no heavy-cost
            -- fields. Keep its invulnerability, but leave its cost untouched until a separate
            -- attribution source is verified. Do not consume a free-heavy charge for it.
            if not STABILITY.combatArtCostNoted then
                STABILITY.combatArtCostNoted = true
                LogKey("shachi combat-art C: heavy refund not applicable; native cost unchanged")
            end
            return
        end
        local original = origCosts[classPath]
        if not original then
            original = {
                cost = readNumber(self, "Shachi Cost"),
                min = readNumber(self, "Shachi Cost Min"),
            }
            origCosts[classPath] = original
        end
        if original.cost == nil then
            logError("heavy cost disabled: reflected Shachi Cost missing on " .. classPath)
            return
        end
        local freeAttack = charges > 0
        if charges > 0 then
            self["Shachi Cost"] = 0.0
            if original.min ~= nil then self["Shachi Cost Min"] = 0.0 end
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
        -- The game ignores the Shachi Cost write, so a free heavy is only really free if the charged
        -- shachi is refunded too: free keeps nothing (scale 0), reduced keeps HeavyCostScale. Refund the
        -- snapshotted consumed cost (attributable to this hit), not the raw bar dip.
        if freeAttack then
            ScheduleShachiSettlement(consumedSnapshot, 0)
        elseif Settings.HeavyCostScale < 1 then
            ScheduleShachiSettlement(consumedSnapshot, Settings.HeavyCostScale)
        end
end

local function HookHeavy(name)
    if hookedHeavy[name] then return end
    if not STABILITY.DiscoveryReady("heavy:" .. name) then return end
    -- B/BBB keep their event graph on a parent class, so a missing K2_ActivateAbility on the child is
    -- expected and resolved by the parent fallback below; only a failed fallback is a real error.
    local isParentFallback = name == "GA_Hun_ChiRen_B_C" or name == "GA_Hun_ChiRen_BBB_C"
    local objects = safe(FindAllOf, name)
    if not objects or #objects == 0 then return end
    local classPath = classPathOf(objects[1])
    if not classPath then return end
    local anyOk = false
    local ok, err = STABILITY.TryRegisterHook(classPath .. ":K2_ActivateAbility", function(context)
        HeavyActivate(name, Unwrap(context), classPath)
    end)
    if ok then
        anyOk = true
        LogKey("hooked heavy %s", name)
    else
        if isParentFallback then
            LogEvent("heavy hook %s: %s (event graph on parent; falling back)", name, tostring(err))
        else
            logError("heavy hook " .. name .. ": " .. tostring(err))
        end
        if isParentFallback then
            local classObj = safe(function() return objects[1]:GetClass() end)
            local parent = valid(classObj) and readField(classObj, "SuperStruct") or nil
            if valid(parent) then
                local parentPath = safe(function()
                    return parent:GetFullName():gsub("^%S+%s+", "")
                end)
                if parentPath then
                    local pOk, pErr = STABILITY.TryRegisterHook(parentPath .. ":K2_ActivateAbility",
                        function(context)
                            local self = Unwrap(context)
                            local actual = valid(self) and safe(function()
                                return self:GetClass():GetFName():ToString()
                            end) or nil
                            if actual == name then
                                HeavyActivate(name, self, classPath)
                            end
                        end)
                    if pOk then anyOk = true end
                    LogEvent("heavy hook %s parent=%s hook ok=%s%s", name, parentPath,
                        tostring(pOk), pOk and "" or (" err=" .. tostring(pErr)))
                    if not pOk then
                        -- BP_B_Base_C / BP_BBB_Base_C are empty; the event graph is one level up.
                        local grand = readField(parent, "SuperStruct")
                        if valid(grand) then
                            local grandPath = safe(function()
                                return grand:GetFullName():gsub("^%S+%s+", "")
                            end)
                            if grandPath then
                                local gOk, gErr = STABILITY.TryRegisterHook(
                                    grandPath .. ":K2_ActivateAbility", function(context)
                                        local self = Unwrap(context)
                                        local actual = valid(self) and safe(function()
                                            return self:GetClass():GetFName():ToString()
                                        end) or nil
                                        if actual == name then
                                            HeavyActivate(name, self, classPath)
                                        end
                                    end)
                                if gOk then anyOk = true end
                                LogEvent("heavy hook %s grandparent=%s hook ok=%s%s", name, grandPath,
                                    tostring(gOk), gOk and "" or (" err=" .. tostring(gErr)))
                            end
                        end
                    end
                end
            else
                LogEvent("heavy hook %s has no SuperStruct", name)
            end
        end
    end
    if anyOk then
        hookedHeavy[name] = true
        if not ok then
            LogKey("hooked heavy %s (via parent)", name)
        end
    else
        if STABILITY.HookExhausted(classPath .. ":K2_ActivateAbility") then
            hookedHeavy[name] = true
            if isParentFallback then
                logError("heavy hook " .. name .. ": parent fallback also failed: " .. tostring(err))
            end
        end
    end
    if name == "GA_Hun_ChiRen_BSup_C" and not hookedHeavy[name .. "_end"] then
        local okEnd, errEnd = STABILITY.TryRegisterHook(classPath .. ":K2_OnEndAbility", function(context)
            local ability = Unwrap(context)
            local address = valid(ability) and ability:GetAddress() or nil
            if STABILITY.tornadoCastAbility ~= nil and address ~= STABILITY.tornadoCastAbility then return end
            if STABILITY.tornadoCastAt and (STABILITY.tornadoCastAbility == nil or address == STABILITY.tornadoCastAbility) then
                LogEvent("tornado end: %.2f s (invuln asked %.1f s)", os.clock() - STABILITY.tornadoCastAt,
                    STABILITY.tornadoCastInvuln)
                STABILITY.tornadoCastAt = nil
                STABILITY.tornadoCastAbility = nil
            end
            local restored, restoreErr = pcall(RestoreTornadoBullets, "cast-end")
            if not restored then logError("tornado restore: " .. tostring(restoreErr)) end
        end)
        if okEnd or STABILITY.HookExhausted(classPath .. ":K2_OnEndAbility") then
            hookedHeavy[name .. "_end"] = true
        end
        LogEvent("tornado damage: end hook ok=%s%s", tostring(okEnd),
            okEnd and "" or (" err=" .. tostring(errEnd)))
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
    broken = false, logs = 0, frameClass = nil, serial = 0,
}

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
    -- A fast swap-away-and-back can skip the sampler's frozen edge entirely (it runs on a 1 s tick),
    -- leaving frozen nil while the tier has already reset to 0. Freeze the pre-swap snapshot here,
    -- at the moment of swapping back, so the restore still has the real tier to refill.
    if st.snap and st.snap.tier > 0 and (st.frozen == nil or st.frozen.tier < st.snap.tier) then
        st.frozen = { tier = st.snap.tier, fire = st.snap.fire, at = st.snap.at }
    end
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
        -- During a world swap the cached weapon asset can stay valid while its GameplayTags container
        -- turns into a TrivialObject; skip silently rather than log a transient ForEach error.
        local tags = nil
        if equipTags ~= nil then
            local okTags, container = pcall(function() return equipTags.GameplayTags end)
            if okTags then tags = container end
        end
        if valid(tags) then
            local found, active = false, false
            safe(function()
                tags:ForEach(function(_, ref)
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
        elseif st.snap then
            -- Tier fell to 0 (a whirlwind spent it): sync the snapshot down, otherwise a later swap
            -- freezes the stale high tier and refills the meter from nothing on the way back.
            -- Skip this inside the swap-back window: the 0 there is the swap reset, not a whirlwind
            -- spend, and zeroing the snapshot would erase the tier the restore is about to refill.
            if st.backAt == 0 or now - st.backAt > 3.0 then
                st.snap.tier = 0
                if fire ~= nil then st.snap.fire = fire end
                st.snap.at = now
            end
        end
    elseif equipped == false and st.snap and st.snap.tier > 0
        and (st.frozen == nil or st.frozen.tier < st.snap.tier) then
        -- Copy, not alias: the equipped branch above syncs snap.tier in place, which would
        -- otherwise zero the frozen value on the way back before it gets restored. Not gated on
        -- wasEquipped: a fast swap can skip the true->false edge, so freeze whenever ChiRen is away
        -- and the snapshot still holds a real tier.
        st.frozen = { tier = st.snap.tier, fire = st.snap.fire, at = st.snap.at }
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
    -- Keep a live snapshot of the just-restored state instead of clearing it. A fast triple-swap
    -- (ChiRen -> BaiYing -> ChiRen -> BaiYing inside the ~0.5 s hard cd) can swap away again before
    -- the 1 s sampler rebuilds snap; a nil snap would leave the next swap-back with nothing to
    -- restore, which is exactly the "buff icon lit then vanished" case.
    st.snap = { tier = before, fire = KeepFire(asc) or 0, at = now }
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
    SWITCH_DEFLECT.serial = SWITCH_DEFLECT.serial + 1
    local frame = safe(StaticConstructObject, SWITCH_DEFLECT.frameClass, timeline,
        FName("GAA_DeflectFrame_C_ChiRenSW_" .. tostring(SWITCH_DEFLECT.serial), EFindName.FNAME_Add))
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

-- Vanilla whirlwind damage for one layer: PhysicalDamage + ElementDamage of the first loadable
-- bullet asset. Read once, then cached.
function ReadSwitchTornadoBaseDamage()
    -- The bullet value (0.2) is a coefficient, not flat damage: the game multiplies it by the
    -- player's Attack attribute. Cache the coefficient once; read Attack every call (gear changes it).
    local coefficient = STABILITY.tornadoCoefficient
    if coefficient == nil then
        coefficient = 0
        local bullets = STABILITY.tornadoBullets
        local bulletRoot = STABILITY.tornadoBulletRoot
        local eachBulletDamage = STABILITY.eachBulletDamage
        if bullets and bulletRoot and eachBulletDamage then
            for _, name in ipairs(bullets) do
                local path = bulletRoot .. name .. "." .. name
                local asset = ResolveObject(path)
                if valid(asset) then
                    local sum = 0
                    local ok = pcall(function()
                        eachBulletDamage(asset, function(_, value)
                            local v = value:get()
                            if type(v) == "number" and v > 0 then sum = sum + v end
                        end)
                    end)
                    if ok and sum > 0 then
                        coefficient = sum
                        break
                    end
                end
            end
        end
        STABILITY.tornadoCoefficient = coefficient
    end
    local attack = 0
    local pawn = GetPlayerPawn()
    if valid(pawn) then
        local set = readField(pawn, "AttributeSetBase")
        if valid(set) then
            local v = readNumber(set, "Attack")
            if STABILITY.IsFiniteNumber(v) and v > 0 then attack = v end
        end
    end
    if coefficient <= 0 or attack <= 0 then
        LogEvent("switch gp tornado damage: coefficient=%.3f attack=%.1f", coefficient, attack)
        return 0
    end
    return attack * coefficient
end

-- The game's generic ignite DoT (Inflictions directory, same family as the poison ticks). Applied to
-- enemies caught in the first tornado tick so the whirlwind leaves a burning state, not just the
-- direct health write. The player's effect context is used so the burn is credited to the player.
function ResolveIgniteGe()
    if valid(STABILITY.igniteGe) then return STABILITY.igniteGe end
    local path = "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Ignite.GE_Ignite_C"
    local loaded = safe(LoadAsset, path)
    if valid(loaded) then STABILITY.igniteGe = loaded; return STABILITY.igniteGe end
    local found = safe(StaticFindObject, path)
    if valid(found) then STABILITY.igniteGe = found end
    return STABILITY.igniteGe
end

function ResolveIgniteDotGe()
    if valid(STABILITY.igniteDotGe) then return STABILITY.igniteDotGe end
    local path = "/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Ignite_Dot.GE_Ignite_Dot_C"
    local loaded = safe(LoadAsset, path)
    if valid(loaded) then STABILITY.igniteDotGe = loaded; return STABILITY.igniteDotGe end
    local found = safe(StaticFindObject, path)
    if valid(found) then STABILITY.igniteDotGe = found end
    return STABILITY.igniteDotGe
end

-- Native ignite is two layers: GE_Ignite (the burning state tag) and GE_Ignite_Dot (the damage-over-time
-- tick). Owned body-fire follows the returned timed state GE handle.
-- Restore each temporary duration override before visual work; visual failure never blocks the DoT.
function ApplyIgniteToEnemy(enemy, seconds)
    local pawn = GetPlayerPawn()
    local asc = valid(pawn) and readField(pawn, "AbilitySystemComponent") or nil
    local easc = readField(enemy, "AbilitySystemComponent")
    if not valid(asc) or not valid(easc) then
        LogKey("tornado ignite: no ASC")
        return
    end
    local lib = safe(StaticFindObject, "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not valid(lib) then return end
    local eloc = safe(function() return enemy:K2_GetActorLocation() end)
    local applied, enriched = 0, 0
    for layer = 1, 2 do
        local ge
        if layer == 1 then ge = ResolveIgniteGe() else ge = ResolveIgniteDotGe() end
        if valid(ge) then
            local cdo = FindCDO(ge)
            local policy = valid(cdo) and readField(cdo, "DurationPolicy") or nil
            local magnitude = valid(cdo) and readField(cdo, "DurationMagnitude") or nil
            local restore = magnitude and SetTemporaryDuration(magnitude, seconds, "tornado ignite")
            -- A timed burn must not silently fall back to the asset's default duration. If this layer has
            -- a duration (HasDuration=2) but the override could not be written/verified, skip it. Instant
            -- layers (policy=0, e.g. the DoT) carry no duration and apply normally with restore==nil.
            if policy == 2 and restore == nil then
                LogKey("tornado ignite: duration override unavailable; skipping timed layer")
            else
                local ok, effectHandle = pcall(function()
                    local spec = lib:MakeSpecHandleByClass(ge, pawn, pawn, 1.0)
                    local ctx = lib:GetEffectContext(spec)
                    if eloc ~= nil then
                        lib:EffectContextSetOrigin(ctx, eloc)
                        pcall(function()
                            lib:EffectContextAddHitResult(ctx, {
                                Location = eloc, ImpactPoint = eloc,
                                Normal = { X = 0, Y = 0, Z = 1 }, bBlockingHit = true,
                            }, false)
                        end)
                    end
                    return easc:BP_ApplyGameplayEffectSpecToTarget(spec, easc)
                end)
                if ok then enriched = enriched + 1 end
                if not ok then
                    -- Fall back to the plain self-apply so a broken spec path never regresses the DoT.
                    local ctx0 = safe(function() return asc:MakeEffectContext() end)
                    if ctx0 then ok, effectHandle = pcall(function() return easc:BP_ApplyGameplayEffectToSelf(ge, 1.0, ctx0) end) end
                end
                if restore then restore() end
                if ok then
                    applied = applied + 1
                    if layer == 1 and STABILITY.burnVisual then
                        STABILITY.RunBounded("enemy burn visual", STABILITY.burnVisual.apply, enemy, effectHandle, seconds)
                    end
                end
            end
        end
    end
    if applied > 0 then
        LogEvent("tornado ignite: applied %.1fs (%d layers, enriched=%d)", seconds, applied, enriched)
    else
        LogKey("tornado ignite: failed (no GE applied)")
    end
end


-- Moves the tornado component toward the nearest enemy for its 2 s lifetime. The damage scan already
-- follows the component's world position, so the damage zone travels with it. The component moves
-- every 50 ms for smoothness, but the enemy scan (a heavy FindAllOf) only refreshes every 250 ms;
-- between refreshes it keeps the last direction. Once it has tracked an enemy, losing the target
-- keeps that last tracking direction; only before any enemy is seen does it use the spawn yaw.
-- Within SwitchTornadoStopDistance of an enemy it holds still (dist = 0) instead of overshooting and
-- oscillating around the target; it resumes tracking if the enemy moves away.
function MoveSwitchTornado(comp, yaw, speed)
    local fx, fy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local stepMs, steps = 50, 40
    local dist = speed * stepMs / 1000
    local pawn = GetPlayerPawn()
    local playerName = valid(pawn) and FullName(pawn) or ""
    local moveMode = 0
    local function doMove(target)
        if moveMode == 1 then return pcall(function() comp:K2_SetWorldLocation(target, false, {}, false) end) end
        if moveMode == 2 then return pcall(function() comp:K2_SetWorldLocation(target, false, nil, false) end) end
        if moveMode == 3 then return pcall(function() comp:K2_SetWorldLocation(target) end) end
        local ok, err = pcall(function() comp:K2_SetWorldLocation(target, false, {}, false) end)
        if ok then moveMode = 1; return ok, err end
        ok, err = pcall(function() comp:K2_SetWorldLocation(target, false, nil, false) end)
        if ok then moveMode = 2; return ok, err end
        ok, err = pcall(function() comp:K2_SetWorldLocation(target) end)
        if ok then moveMode = 3; return ok, err end
        return ok, err
    end
    local function nearestDir(loc)
        local comps = safe(FindAllOf, "HitreactComponent")
        local bestDx, bestDy, bestSq = 0, 0, math.huge
        for _, c in ipairs(comps or {}) do
            if valid(c) then
                local enemy = safe(function() return c:GetOuter() end)
                if valid(enemy) then
                    local name = FullName(enemy)
                    if name ~= playerName and not name:find("Hun", 1, true) then
                        local eloc = safe(function() return enemy:K2_GetActorLocation() end)
                        if eloc ~= nil then
                            local dx, dy = eloc.X - loc.X, eloc.Y - loc.Y
                            local sq = dx * dx + dy * dy
                            if sq < bestSq and sq > 1 then
                                bestSq, bestDx, bestDy = sq, dx, dy
                            end
                        end
                    end
                end
            end
        end
        if bestSq < math.huge then
            local d = math.sqrt(bestSq)
            return bestDx / d, bestDy / d, d
        end
        return nil
    end
    local function step(i)
        if i > steps or not valid(comp) then return end
        local loc = safe(function() return comp:K2_GetComponentLocation() end)
        if loc ~= nil then
            if i == 1 or (i % 5) == 0 then
                local nx, ny, nd = nearestDir(loc)
                if nx ~= nil then
                    fx, fy = nx, ny
                    local stop = Settings.SwitchTornadoStopDistance
                    dist = (stop > 0 and nd < stop) and 0 or (speed * stepMs / 1000)
                else
                    dist = speed * stepMs / 1000
                end
            end
            local okM, errM = true, nil
            if dist > 0 then
                local target = { X = loc.X + fx * dist, Y = loc.Y + fy * dist, Z = loc.Z }
                okM, errM = doMove(target)
            end
            if i == 1 then
                if dist == 0 then
                    LogEvent("switch gp firetornado: hold (enemy within %.0f cm)", Settings.SwitchTornadoStopDistance)
                elseif okM then
                    LogEvent("switch gp firetornado: move ok mode=%d speed=%.0f cm/s homing", moveMode, speed)
                else
                    LogKey("switch gp firetornado: move FAILED err=%s", tostring(errM))
                    return
                end
            end
        end
        STABILITY.After(stepMs, function() step(i + 1) end)
    end
    step(1)
end


-- A raw attribute write never fires the boss bar's attribute-change delegate, so HP drops while the
-- bar freezes. Drive the bar the way the native HUD does: ForSeq_UpdateHealth(ratio) on the
-- WB_BossHPBar_C bound to this enemy, then read hpbar.CurPercent back to confirm it took. The bar
-- list is a heavy FindAllOf, so cache it and refresh at most once a second across the tornado ticks.
function RefreshEnemyBossBar(enemy, curHP)
    if not valid(enemy) or not STABILITY.IsFiniteNumber(curHP) then return end
    local now = os.clock()
    if STABILITY.bossBarCache == nil or now - (STABILITY.bossBarAt or 0) > 1.0 then
        STABILITY.bossBarAt = now
        STABILITY.bossBarCache = safe(FindAllOf, "WB_BossHPBar_C") or {}
    end
    local eset = readField(enemy, "AttributeSetBase")
    if not valid(eset) then return end
    local maxHP = readNumber(eset, "Health_Max")
    if not STABILITY.IsFiniteNumber(maxHP) or maxHP <= 0 then return end
    local ratio = math.max(0, math.min(1, curHP / maxHP))
    local ekey = safe(function() return enemy:GetAddress() end)
    if ekey == nil then return end
    for _, bar in ipairs(STABILITY.bossBarCache) do
        if valid(bar) then
            local ch = readField(bar, "Character")
            local ckey = valid(ch) and safe(function() return ch:GetAddress() end) or nil
            if ckey == ekey then
                local ok, err = pcall(function() bar:ForSeq_UpdateHealth(ratio) end)
                local hpbar = readField(bar, "hpbar")
                local actual = valid(hpbar) and readNumber(hpbar, "CurPercent") or nil
                local verified = ok and STABILITY.IsFiniteNumber(actual)
                    and math.abs(actual - ratio) < 0.002
                if not ok then logError("bossbar refresh failed: " .. tostring(err)) end
                if (STABILITY.bossBarLogs or 0) < 12 then
                    STABILITY.bossBarLogs = (STABILITY.bossBarLogs or 0) + 1
                    LogEvent("bossbar refresh: hp=%.0f/%.0f ratio=%.3f actual=%s ok=%s verified=%s%s",
                        curHP, maxHP, ratio,
                        STABILITY.IsFiniteNumber(actual) and string.format("%.3f", actual) or "nil",
                        tostring(ok), tostring(verified), ok and "" or (" err=" .. tostring(err)))
                end
                return
            end
        end
    end
end

-- One tornado damage tick: rescans the area (player and enemies move between ticks), lowers health
-- on every target in range and plays the native hit reaction. Health is written on both BaseValue
-- and CurrentValue: the attribute aggregator recomputes CurrentValue from BaseValue.
function SwitchTornadoDamageTick(damage, tickIndex, isLast, tornadoComp)
    -- Optional test multiplier; the key is absent from the release config, so this defaults to 1.
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return end
    -- World locations, not RootComponent.RelativeLocation (which is parent-relative and can be 0).
    local origin = safe(function() return pawn:K2_GetActorLocation() end)
    if origin == nil then return end
    -- Center the scan on the tornado component's world position when readable, so the damage zone
    -- sits where the whirlwind is instead of on the player (who keeps moving after the GP).
    local center = origin
    if tornadoComp ~= nil then
        local cloc = safe(function() return tornadoComp:K2_GetComponentLocation() end)
        if cloc ~= nil and (cloc.X ~= 0 or cloc.Y ~= 0 or cloc.Z ~= 0) then center = cloc end
    end
    local rotation = safe(function() return pawn:K2_GetActorRotation() end)
    local yaw = rotation and rotation.Yaw or 0
    local cosLimit = math.cos(math.rad(Settings.SwitchTornadoAngle * 0.5))
    local radiusSq = Settings.SwitchTornadoRadius * Settings.SwitchTornadoRadius
    local forwardX, forwardY = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local playerName = FullName(pawn)
    local hits, applied = 0, 0
    -- Only the first tick plays the native hit reaction (animation + hit sound); the native
    -- whirlwind damages in reps without interrupting the enemy on every rep.
    local reactSrc
    if tickIndex == 1 and STABILITY.makeBreakSource then
        reactSrc = STABILITY.makeBreakSource(pawn)
    end
    local comps = safe(FindAllOf, "HitreactComponent")
    for _, comp in ipairs(comps or {}) do
        if valid(comp) then
            local enemy = safe(function() return comp:GetOuter() end)
            if valid(enemy) then
                local name = FullName(enemy)
                if name ~= playerName and not name:find("Hun", 1, true) then
                    local eloc = safe(function() return enemy:K2_GetActorLocation() end)
                    if eloc ~= nil then
                        local dx, dy = eloc.X - center.X, eloc.Y - center.Y
                        local distSq = dx * dx + dy * dy
                        if distSq <= radiusSq then
                            local cos = 1.0
                            local dist = math.sqrt(distSq)
                            if dist > 1 then cos = (dx * forwardX + dy * forwardY) / dist end
                            if cos >= cosLimit then
                                hits = hits + 1
                                pcall(function()
                                    local eset = readField(enemy, "AttributeSetBase")
                                    if not valid(eset) then return end
                                    local hdata = readField(eset, "Health")
                                    if hdata == nil then return end
                                    local hp = readNumber(eset, "Health")
                                    if not STABILITY.IsFiniteNumber(hp) or hp <= 0 then return end
                                    if tickIndex == 1 then
                                        LogEvent("switch gp tornado target: %s hp=%.0f dist=%.0f", name, hp, dist)
                                    end
                                    local baseVal = safe(function() return hdata.BaseValue end)
                                    if not STABILITY.IsFiniteNumber(baseVal) then baseVal = hp end
                                    -- Cap at 1 HP, never 0: writing 0 (or force-killing) skips the boss's
                                    -- native death/phase event and leaves it stuck at 0 HP, unkillable even
                                    -- by normal attacks. The game's own damage pipeline finishes the kill.
                                    pcall(function() hdata.BaseValue = math.max(1, baseVal - damage) end)
                                    pcall(function() hdata.CurrentValue = math.max(1, hp - damage) end)
                                    local after = readNumber(eset, "Health")
                                    if STABILITY.IsFiniteNumber(after) and after < hp - 1 then
                                        applied = applied + 1
                                        RefreshEnemyBossBar(enemy, after)
                                    end
                                end)
                                if reactSrc ~= nil then
                                    pcall(function() comp:PlayHitreactToAvatar(reactSrc) end)
                                end
                                if Settings.SwitchTornadoBurnSeconds > 0 then
                                    local every = math.max(1, math.floor(Settings.SwitchTornadoBurnEvery))
                                    if tickIndex == 1 or isLast or (tickIndex % every) == 0 then
                                        ApplyIgniteToEnemy(enemy, Settings.SwitchTornadoBurnSeconds)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    LogEvent("switch gp tornado tick %d: hits=%d applied=%d center=(%.0f,%.0f)", tickIndex, hits, applied, center.X, center.Y)

end

-- Splits the vanilla one-layer whirlwind damage into several ticks over the tornado's lifetime, so
-- the hit rhythm matches the native BSup whirlwind (8 reps in ~0.88 s) instead of one lump sum.
function ApplySwitchGpTornadoDamage(tornadoComp)
    if Settings.SwitchTornadoDamageScale <= 0 then return end
    -- Base = measured vanilla one-layer damage (log: BSup x4 = 4399 -> about 1100 per layer at
    -- Attack 100). It grows linearly with the player's current Attack so weapon/level upgrades scale
    -- it like the native whirlwind. Base 0 falls back to Attack x bullet coefficient.
    local base = Settings.SwitchTornadoDamageBase
    local attack = 0
    local pawn = GetPlayerPawn()
    if valid(pawn) then
        local set = readField(pawn, "AttributeSetBase")
        if valid(set) then
            local v = readNumber(set, "Attack")
            if STABILITY.IsFiniteNumber(v) and v > 0 then attack = v end
        end
    end
    if base <= 0 then
        base = ReadSwitchTornadoBaseDamage()
    elseif attack > 0 and Settings.SwitchTornadoCalibratedAttack > 0 then
        base = base * attack / Settings.SwitchTornadoCalibratedAttack
    end
    if base <= 0 then
        LogKey("switch gp tornado damage: base unavailable")
        return
    end
    local total = base * Settings.SwitchTornadoDamageScale
    local ticks = math.max(1, math.floor(Settings.SwitchTornadoTicks))
    local perTick = total / ticks
    local intervalMs = math.max(16, math.floor(Settings.SwitchTornadoTickSeconds * 1000 / ticks))
    LogEvent("switch gp tornado damage: base=%.1f attack=%.0f total=%.0f ticks=%d interval=%dms",
        base, attack, total, ticks, intervalMs)
    for i = 1, ticks do
        local idx, last = i, (i == ticks)
        if i == 1 then
            SwitchTornadoDamageTick(perTick, idx, last, tornadoComp)
        else
            STABILITY.After((i - 1) * intervalMs, function()
                SwitchTornadoDamageTick(perTick, idx, last, tornadoComp)
            end)
        end
    end
end


-- Wwise playback: PBZ battle audio goes through AkAudioEvent, not SoundWave. PostEvent has several
-- overloads; try the event-object one first, then the event-name one, and log whichever binds.
function PlayWwiseEvent(path, actor)
    local ev = safe(StaticFindObject, path)
    if not valid(ev) then
        safe(LoadAsset, path)
        ev = safe(StaticFindObject, path)
    end
    if not valid(ev) then
        LogKey("wwise play: event unavailable")
        return
    end
    local st = safe(StaticFindObject, "/Script/AkAudio.Default__AkGameplayStatics")
    if not valid(st) then
        LogKey("wwise play: AkGameplayStatics unavailable")
        return
    end
    local ok5, err5 = pcall(function() st:PostEvent(ev, actor, 0, nil, 0) end)
    if ok5 then
        LogEvent("wwise play: posted (5-arg)")
        return
    end
    LogKey("wwise play: 5-arg failed err=%s", tostring(err5))
end

-- The execution finisher's fire tornado (HeiShang long-blade VFX). Spawned the moment a switch GP
-- succeeds so the switch parry ends with the same fire whirlwind the execution uses.
local COUNTER_TORNADO_PATH =
    "/PBZVFXPack/VFX/BattleFX/Weapon/HeiShang/NS_LongBlade_Firetornado_401.NS_LongBlade_Firetornado_401"
function SpawnSwitchGpTornado()
    local pawn = GetPlayerPawn()
    if not valid(pawn) then return end
    local path = COUNTER_TORNADO_PATH
    local system = STABILITY.counterTornado
    if not valid(system) then
        system = safe(StaticFindObject, path)
        if not valid(system) then
            safe(LoadAsset, path)
            system = safe(StaticFindObject, path)
        end
        STABILITY.counterTornado = system
    end
    if not valid(system) then
        LogKey("switch gp firetornado: system unavailable")
        return
    end
    local lib = safe(StaticFindObject, "/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not valid(lib) then
        LogKey("switch gp firetornado: NiagaraFunctionLibrary unavailable")
        return
    end
    local location = safe(function() return pawn:K2_GetActorLocation() end)
    local rotation = safe(function() return pawn:K2_GetActorRotation() end)
    if location == nil then
        LogKey("switch gp firetornado: no pawn location")
        return
    end
    -- The execution tornado starts at ground level in front of the player, not at blade height / on
    -- the body. Yaw 0 faces +X, so forward = (cos, sin).
    local yaw = rotation and rotation.Yaw or 0
    local distance = Settings.SwitchTornadoDistance
    local ground = {
        X = location.X + math.cos(math.rad(yaw)) * distance,
        Y = location.Y + math.sin(math.rad(yaw)) * distance,
        Z = location.Z - Settings.SwitchTornadoDrop,
    }
    -- Full 9-argument signature: world context, system, location, rotation, scale, auto destroy,
    -- auto activate, pooling method (0 = None), pre-cull check.
    local ok, comp = pcall(function()
        return lib:SpawnSystemAtLocation(pawn, system, ground, rotation or { X = 0, Y = 0, Z = 0 },
            { X = 1, Y = 1, Z = 1 }, true, true, 0, true)
    end)
    if ok and comp ~= nil then
        LogEvent("switch gp firetornado: spawned")
        PlayWwiseEvent("/Game/Wwise/Events/SFX/Combat/Special/Hero_Special/Hun/Common/Wave_Stab_BaDao/ChiRen/ChiRen/SFX_Combat_Hun_ChiRen_Wave_Fire.SFX_Combat_Hun_ChiRen_Wave_Fire", pawn)
        local dmgOk, dmgErr = xpcall(function() ApplySwitchGpTornadoDamage(comp) end, debug.traceback)
        if not dmgOk then logError("tornado damage: " .. tostring(dmgErr)) end
        if Settings.SwitchTornadoSpeed > 0 then
            MoveSwitchTornado(comp, yaw, Settings.SwitchTornadoSpeed)
        end
        -- Looping system: auto-destroy never fires. Deactivate stops emission; the component itself
        -- needs the owner's blueprint destroy route (DestroyComponent is not exposed on this build).
        STABILITY.After(2000, function()
            -- No valid(comp) gate here: IsValid is unreliable on this component type, and skipping
            -- the whole cleanup leaves a looping tornado behind. Every step is individually guarded.
            pcall(function() comp:Deactivate() end)
            pcall(function() comp:SetActive(false) end)
            local okOwner, owner = pcall(function() return comp:GetOwner() end)
            if okOwner and owner ~= nil then
                pcall(function() owner:K2_DestroyComponent(comp) end)
            end
        end)
    else
        LogKey("switch gp firetornado: spawn failed (%s)", tostring(ok and "nil component" or comp))
    end
end

local function TuneClashWindow(context)
    TuneSwitchAttack(context)
    SWITCH_DEFLECT.inject(context)
    KeepBack(context)
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
    if Settings.ClashWindowFrames <= 0 and not Settings.SwitchAttackBlock and not Settings.SwitchDeflectInject
        and not Settings.SwitchKeepStacks then return end
    if not STABILITY.DiscoveryReady("ability-base") then return end
    local ok, err = STABILITY.TryRegisterHook(CLASH_ABILITY_BASE, TuneClashWindow)
    if not ok then
        logError("clash window hook: " .. tostring(err))
        if STABILITY.HookExhausted(CLASH_ABILITY_BASE) then clashWindowHooked = true end
        return
    end
    clashWindowHooked = true
    LogKey("clash window: hook ok (%d frames at %d fps; vanilla %.6f s)",
        Settings.ClashWindowFrames, CLASH_FRAME_RATE, CLASH_VANILLA_SECONDS)
end

---------------------------------------------------------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------------------------------------------------------

local function Tick()
    if not GetPlayerPawn() then return end
    TryHitreactHook()
    TryDeflectHook()
    for _, name in ipairs(HEAVY_CLASSES) do
        HookHeavy(name)
    end
    TuneDeflectWindow()
    TryClashWindowHook()
end


function STABILITY.RunBounded(name, callback, ...)
    local state = STABILITY.loopFailures[name] or { failures = 0, nextAt = 0 }
    if os.clock() < state.nextAt then return end
    local ok, err = pcall(callback, ...)
    if ok then
        state.failures, state.nextAt = 0, 0
    else
        state.failures = state.failures + 1
        state.nextAt = os.clock() + math.min(2 ^ math.min(state.failures, 6), 60)
        logError(name .. ": " .. tostring(err))
    end
    STABILITY.loopFailures[name] = state
end


function STABILITY.ObservePlayer()
    local key = STABILITY.PlayerKey()
    -- A transient nil (controller lookup briefly failing) must not wipe combat state. Only a
    -- confirmed new pawn clears it; while nil, pause this tick and keep the previous state.
    if key == nil then return false end
    if key ~= STABILITY.currentPlayerKey then
        if STABILITY.currentPlayerKey ~= nil and CLASH_SLOWMO.active then CLASH_SLOWMO.restore() end
        if STABILITY.burnVisual then
            STABILITY.RunBounded("enemy burn visual reset", STABILITY.burnVisual.reset)
        end
        if STABILITY.tornadoHud then
            STABILITY.RunBounded("tornado HUD reset", STABILITY.tornadoHud.reset)
        end
        STABILITY.currentPlayerKey = key
        invulnToken = invulnToken + 1
        invulnGuardToken = invulnGuardToken + 1
        breakToken = breakToken + 1
        charges, lastClash = 0, 0
        fireAppliedAt, fireUntil, fireAskedSeconds, fireReapplyAt, lastBurning = nil, nil, nil, nil, nil
        invulnHandle, STABILITY.invulnOwner = nil, nil
        breakMeter = {}
        TORNADO.combo, TORNADO.followup = 0, nil
        STABILITY.deflectSource = nil
        SWITCH_KEEP.snap, SWITCH_KEEP.frozen, SWITCH_KEEP.wasEquipped = nil, nil, nil
        SWITCH_KEEP.lastTier, SWITCH_KEEP.backAt = nil, 0
        LogKey("player changed; transient state cleared")
    end
    return true
end

local function TickSafe()
    if STABILITY.ObservePlayer() then
        STABILITY.RunBounded("discovery", Tick)
    end
    return false
end

local function SampleSafe()
    -- Safety net: if the slow-motion frame loop ever stops restoring, take the factor back here.
    -- This uses the captured world, so a missing pawn during travel must not bypass cleanup.
    if CLASH_SLOWMO.active and os.clock() > CLASH_SLOWMO.endsAt + 0.3 then
        local slowOk, slowErr = pcall(CLASH_SLOWMO.restore)
        if not slowOk then logError(slowErr) end
    end
    if not STABILITY.ObservePlayer() then
        -- Travel/loading: reset the baseline so the gap is not reported as a hitch.
        STABILITY.lastSampleAt = os.clock()
        return false
    end
    if Settings.LogEvents then
        local now = os.clock()
        if STABILITY.lastSampleAt and now - STABILITY.lastSampleAt > 0.8 then
            LogEvent("hitch: sampler late %.0f ms", (now - STABILITY.lastSampleAt) * 1000)
        end
        STABILITY.lastSampleAt = now
    end
    if Settings.FireEnabled then STABILITY.RunBounded("burning", CheckBurning) end
    if Settings.SwitchKeepStacks then STABILITY.RunBounded("switch keep", KeepTick) end
    if STABILITY.tornadoHud then STABILITY.RunBounded("tornado HUD", STABILITY.tornadoHud.tick) end
    return false
end

log(VERSION .. " loaded")

if Settings.HighlightTornadoReady then
    local ok, hud = pcall(function()
        local tierThree = { TagName = FName("CharacterState.AbilityState.Long.Buff.Lv3", EFindName.FNAME_Add) }
        local equipped = { TagName = FName(CHIREN_EQUIP_TAG, EFindName.FNAME_Add) }
        return require("chiren_tornado_hud")({
            valid = valid, fullName = FullName, read = readField, find = FindAllOf,
            finite = STABILITY.IsFiniteNumber, trace = LogEvent, error = logError,
            ready = function()
                local castAt = STABILITY.tornadoCastAt
                if castAt and os.clock() - castAt < 3.0 then return false end
                local _, asc = PlayerAbilities()
                if not valid(asc) then return false end
                local tierCount = safe(function() return asc:GetGameplayTagCount(tierThree) end)
                if type(tierCount) ~= "number" or tierCount <= 0 then return false end
                local equipCount = safe(function() return asc:GetGameplayTagCount(equipped) end)
                return type(equipCount) == "number" and equipCount > 0
            end,
        })
    end)
    if ok and type(hud) == "table" then
        STABILITY.tornadoHud = hud
        LogKey("tornado HUD: ready highlight enabled")
    else
        logError("tornado HUD unavailable: " .. tostring(hud))
    end
end

if Settings.EnemyBurnVisual then
    local ok, factory = pcall(require, "chiren_burn_visual")
    if ok and type(factory) == "function" then
        local initialized, module = pcall(factory, {
            valid=valid, readField=readField, readNumber=readNumber, finite=STABILITY.IsFiniteNumber,
            playerKey=STABILITY.PlayerKey, samePlayer=STABILITY.SamePlayer, after=STABILITY.After,
            trace=LogEvent, error=logError, fullName=FullName,
        })
        if initialized and type(module) == "table" then STABILITY.burnVisual = module
        else logError("burn visual unavailable: " .. tostring(module)) end
    else logError("burn visual module missing; damage unchanged") end
end

function STABILITY.StartLoop(delay, callback)
    local queued = false
    local failures, retryAt = 0, 0
    local function noteFailure(kind, err)
        failures = failures + 1
        retryAt = os.clock() + math.min(2 ^ math.min(failures, 6), 60)
        logError(kind .. ": " .. tostring(err))
    end
    local function run()
        queued = false
        if os.clock() < retryAt then return false end
        local ok, err = pcall(callback)
        if ok then
            failures, retryAt = 0, 0
        else
            noteFailure("timer callback", err)
        end
        return false
    end
    local ok, err
    if type(LoopInGameThreadWithDelay) == "function" then
        ok, err = pcall(LoopInGameThreadWithDelay, delay, run)
    else
        ok, err = pcall(LoopAsync, delay, function()
            -- A slow/loading game thread gets at most one pending job per loop.
            if queued or os.clock() < retryAt then return false end
            queued = true
            local sent, sendErr = pcall(ExecuteInGameThread, run)
            if not sent then
                queued = false
                noteFailure("game-thread dispatch", sendErr)
            end
            return false
        end)
    end
    if not ok then logError("timer registration failed: " .. tostring(err)) end
end

-- Discovery only finds classes and registers hooks; once hooked, combat runs event-driven. A slower
-- sweep halves the periodic FindAllOf cost on fresh saves without delaying any registered hook.
STABILITY.StartLoop(3000, TickSafe)
STABILITY.StartLoop(300, SampleSafe)
if Settings.ClashSlowmoEnabled or Settings.SwitchSlowmoEnabled then
    STABILITY.StartLoop(16, CLASH_SLOWMO.frameStep)
end
