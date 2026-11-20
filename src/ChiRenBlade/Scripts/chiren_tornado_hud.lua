return function(api)
    local texturePath = "Texture2D /Game/PBZContent/UI/FrontEnd/BuffTexture/T_BuffUI_100.T_BuffUI_100"
    local tinted = {}
    local wasReady, disabled = false, false
    local scansLeft = 0

    local function isTarget(image)
        if not api.valid(image) then return false end
        local texture = api.read(api.read(image, "Brush"), "ResourceObject")
        return api.valid(texture) and api.fullName(texture) == texturePath
    end

    local function readColor(image)
        local color = api.read(image, "ColorAndOpacity")
        local r, g, b, a = api.read(color, "R"), api.read(color, "G"), api.read(color, "B"), api.read(color, "A")
        if api.finite(r) and api.finite(g) and api.finite(b) and api.finite(a) then
            return { R = r, G = g, B = b, A = a }
        end
    end

    local function sameColor(left, right)
        return left ~= nil and math.abs(left.R - right.R) < 0.001 and math.abs(left.G - right.G) < 0.001
            and math.abs(left.B - right.B) < 0.001 and math.abs(left.A - right.A) < 0.001
    end

    local function setColor(image, color)
        local ok = pcall(function() image:SetColorAndOpacity(color) end)
        return ok and sameColor(readColor(image), color)
    end

    local function restore(key, entry)
        if not api.valid(entry.image) then
            tinted[key] = nil
            return
        end
        local current = readColor(entry.image)
        if current and not sameColor(current, entry.applied) then
            tinted[key] = nil
        elseif current and setColor(entry.image, entry.original) then
            tinted[key] = nil
            api.trace("tornado HUD: restored %s", key)
        else
            entry.restoreAttempts = (entry.restoreAttempts or 0) + 1
            if entry.restoreAttempts < 3 then return end
            tinted[key] = nil
            disabled = true
            api.error("tornado HUD: icon color restore failed, highlight disabled")
        end
    end

    local function scan()
        local widgets = api.find("W_BuffIcon_C")
        if type(widgets) ~= "table" then return end
        for index = 1, math.min(#widgets, 48) do
            local widget = widgets[index]
            local name = api.valid(widget) and api.fullName(widget) or ""
            if name:find("W_FrontEndHUDLayout_C_", 1, true) and name:find(".W_BuffBar.", 1, true) then
                local image = api.read(widget, "Icon")
                if isTarget(image) and tinted[name] == nil then
                    local original = readColor(image)
                    if original == nil then
                        disabled = true
                        api.error("tornado HUD: icon color unreadable, highlight disabled")
                        return
                    end
                    local applied = {
                        R = original.R * 0.75,
                        G = original.G * 0.025,
                        B = original.B * 0.05,
                        A = original.A,
                    }
                    tinted[name] = { image = image, original = original, applied = applied }
                    if not setColor(image, applied) then
                        restore(name, tinted[name])
                        if not disabled then
                            disabled = true
                            api.error("tornado HUD: icon color write rejected, highlight disabled")
                        end
                        return
                    end
                    api.trace("tornado HUD: tinted %s", name)
                end
            end
        end
    end

    local function reset()
        wasReady, scansLeft = false, 0
        for key, entry in pairs(tinted) do restore(key, entry) end
    end

    local function tick()
        if disabled then
            reset()
            return
        end
        if not api.ready() then
            if wasReady or next(tinted) ~= nil then reset() end
            return
        end
        if not wasReady then
            wasReady = true
            scansLeft = 3
        end
        for key, entry in pairs(tinted) do
            if entry.restoreAttempts or not isTarget(entry.image) then restore(key, entry) end
        end
        if scansLeft > 0 and not disabled then
            scansLeft = scansLeft - 1
            scan()
        end
        if disabled then reset() end
    end

    return { tick = tick, reset = reset }
end
