-- Native adapter for the owned enemy body-fire lifecycle. No native pool components are modified.
return function(api)
    local initialized, compatible, asset, class, lib = false, false, nil, nil, nil
    local queryNotes = 0
    local function quiet(fn, ...)
        local ok, value = pcall(fn, ...)
        if ok then return value end
    end
    local function matches(path, layout)
        local fn = quiet(StaticFindObject, path)
        if not api.valid(fn) then return false end
        local fields, bad = {}, false
        local ok = pcall(function()
            fn:ForEachProperty(function(p)
                local readable, value = pcall(function()
                    return p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString()
                end)
                if readable then fields[#fields+1] = value else bad = true end
            end)
        end)
        return ok and not bad and table.concat(fields, ",") == layout
    end
    local function init()
        if initialized then return compatible end
        initialized = true
        if type(ExecuteInGameThreadWithDelay) ~= "function" then
            api.error("burn visual disabled: confirmed game-thread scheduler unavailable")
            return false
        end
        for _, entry in ipairs({
            {"/Script/Engine.Actor:AddComponentByClass","Class:ClassProperty,bManualAttachment:BoolProperty,RelativeTransform:StructProperty,bDeferredFinish:BoolProperty,ReturnValue:ObjectProperty"},
            {"/Script/Engine.Actor:FinishAddComponent","Component:ObjectProperty,bManualAttachment:BoolProperty,RelativeTransform:StructProperty"},
            {"/Script/Engine.ActorComponent:SetAutoActivate","bNewAutoActivate:BoolProperty"},
            {"/Script/Engine.ActorComponent:SetActive","bNewActive:BoolProperty,bReset:BoolProperty"},
            {"/Script/Engine.ActorComponent:K2_DestroyComponent","Object:ObjectProperty"},
            {"/Script/Engine.SceneComponent:K2_AttachToComponent","Parent:ObjectProperty,SocketName:NameProperty,LocationRule:EnumProperty,RotationRule:EnumProperty,ScaleRule:EnumProperty,bWeldSimulatedBodies:BoolProperty,ReturnValue:BoolProperty"},
            {"/Script/Niagara.NiagaraComponent:SetAsset","InAsset:ObjectProperty,bResetExistingOverrideParameters:BoolProperty"}
        }) do
            if not matches(entry[1], entry[2]) then
                api.error("burn visual disabled: signature mismatch " .. entry[1])
                return false
            end
        end
        class = quiet(StaticFindObject, "/Script/Niagara.NiagaraComponent")
        lib = quiet(StaticFindObject, "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        compatible = api.valid(class) and api.valid(lib)
        return compatible
    end
    local function create(enemy)
        local component
        local ok, err = pcall(function()
            local mesh = api.readField(enemy, "Mesh")
            if not api.valid(mesh) then error("target mesh unavailable") end
            if not api.valid(asset) then
                local path = "/PBZVFXPack/VFX/BattleFX/Common/NS_Debuff_001_Burning.NS_Debuff_001_Burning"
                asset = quiet(StaticFindObject, path)
                if not api.valid(asset) then quiet(LoadAsset, path); asset = quiet(StaticFindObject, path) end
            end
            if not api.valid(asset) or not api.valid(class) then error("burning system/class unavailable") end
            local t = {Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
            component = enemy:AddComponentByClass(class, true, t, true)
            if not api.valid(component) then error("private component creation failed") end
            component:SetAutoActivate(false)
            if api.readField(component,"bAutoActivate") ~= false or api.valid(api.readField(component,"Asset")) then
                error("unexpected activation/asset before setup")
            end
            enemy:FinishAddComponent(component, true, t)
            if component:IsActive() ~= false then error("active before setup") end
            local attached = component:K2_AttachToComponent(mesh, FName("pelvis", EFindName.FNAME_Add), 2,2,2,false)
            local parent = component:GetAttachParent()
            if attached ~= true or not api.valid(parent) or parent:GetAddress() ~= mesh:GetAddress()
                or component:GetAttachSocketName():ToString() ~= "pelvis" then error("attachment readback mismatch") end
            component:SetAsset(asset, true)
            local actual = api.readField(component, "Asset")
            if not api.valid(actual) or actual:GetAddress() ~= asset:GetAddress() then error("asset readback mismatch") end
        end)
        -- Preserve partial allocation for the lifecycle manager's failure cleanup.
        return component, not ok and tostring(err) or nil
    end
    local manager = require("chiren_burn_lifecycle")({
        key = function(enemy)
            if not api.valid(enemy) then return nil end
            return tostring(enemy:GetAddress()) .. "|" .. api.fullName(enemy)
        end,
        playerKey = api.playerKey, samePlayer = api.samePlayer, after = api.after,
        trace = api.trace, error = api.error,
        remaining = function(enemy, handle)
            if not api.valid(enemy) or not api.valid(lib) then return nil end
            local left = lib:GetActiveGameplayEffectRemainingDuration(enemy, handle)
            if queryNotes < 6 then
                queryNotes = queryNotes + 1
                api.trace("burn visual: GE handle=%s remaining=%s", tostring(handle.Handle), tostring(left))
            end
            return left
        end,
        create = create,
        activate = function(component)
            component:SetActive(true, false)
            return component:IsActive() == true
        end,
        alive = function(enemy, component)
            if not api.valid(enemy) or not api.valid(component) then return false end
            local attrs = api.readField(enemy, "AttributeSetBase")
            local hp = api.valid(attrs) and api.readNumber(attrs, "Health") or nil
            return api.finite(hp) and hp > 0
        end,
        destroy = function(enemy, component)
            if not api.valid(component) then return true end
            if not api.valid(enemy) then return false end
            -- A stop request may drain asynchronously; cleanup must not depend on IsActive becoming false.
            quiet(function() component:SetActive(false, false) end)
            component:K2_DestroyComponent(enemy)
            return true
        end,
    })
    return {
        reset = function()
            manager.reset()
            asset = nil -- Reload this cache lazily after a confirmed player/world change.
        end,
        apply = function(enemy, returnedHandle, fallbackSeconds)
            if not api.valid(enemy) then return false end
            local value = returnedHandle ~= nil and quiet(function() return returnedHandle.Handle end) or nil
            if api.finite(value) and value >= 0 and value % 1 == 0 then
                if not init() then return false end
                -- Copy the integer rather than retaining a transient UE4SS struct view.
                return manager.apply(enemy, {Handle=value})
            end
            if not api.finite(fallbackSeconds) or fallbackSeconds <= 0 or fallbackSeconds > 60 then return false end
            if not init() then return false end
            api.trace("burn visual: no GE handle; using fixed %.2fs fallback", fallbackSeconds)
            return manager.applyTimed(enemy, fallbackSeconds)
        end,
    }
end
