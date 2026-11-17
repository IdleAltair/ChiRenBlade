-- Owned body-fire lifecycle; the native adapter supplies all UObject operations.
-- No damage writes, GE edits, asset scans, or persistent idle watcher.
return function(api)
    local states, count, epoch, queued, disabled = {}, 0, 0, false, false
    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) ~= math.huge
    end
    local function query(enemy, handle)
        local ok, left = pcall(api.remaining, enemy, handle)
        if ok and finite(left) and left > 0 and not (left > 60) then return left end
    end
    local function report(message)
        api.error("burn lifecycle: " .. tostring(message))
    end
    local function remove(key, reason)
        local state = states[key]
        if not state then return end
        states[key] = nil
        count = count - 1
        if state.component ~= nil then
            local ok, result = pcall(api.destroy, state.enemy, state.component)
            if not ok or result ~= true then
                disabled = true
                report("owned component cleanup unconfirmed: " .. tostring(result))
            end
        end
        api.trace("burn visual: removed (%s), targets=%d", reason, count)
    end
    local function clear(reason)
        epoch = epoch + 1
        queued = false
        local keys = {}
        for key in pairs(states) do keys[#keys + 1] = key end
        for _, key in ipairs(keys) do remove(key, reason) end
    end
    local schedule
    schedule = function()
        if queued or count == 0 then return true end
        queued = true
        local generation = epoch
        local ok, handle = pcall(api.after, 500, function()
            if generation ~= epoch then return end
            queued = false
            local keys = {}
            for key in pairs(states) do keys[#keys + 1] = key end
            for _, key in ipairs(keys) do
                local state = states[key]
                if state then
                    local good, keep = pcall(function()
                        return api.samePlayer(state.player)
                            and api.alive(state.enemy, state.component)
                            and query(state.enemy, state.handle) ~= nil
                    end)
                    if not good or not keep then remove(key, "effect ended/target unavailable") end
                end
            end
            local needsWatcher = false
            for _, state in pairs(states) do
                if state.handle ~= nil then needsWatcher = true break end
            end
            if needsWatcher then schedule() end
        end)
        if not ok or not finite(handle) or handle % 1 ~= 0 then
            disabled = true
            clear("scheduler failure")
            report("integer-ms cleanup scheduling failed; activation disabled")
            return false
        end
        return true
    end
    local function scheduleTimed(key, state, seconds)
        state.timerToken = (state.timerToken or 0) + 1
        local token, generation = state.timerToken, epoch
        local ok, handle = pcall(api.after, math.floor(seconds * 1000 + 0.5), function()
            if generation ~= epoch or states[key] ~= state or state.timerToken ~= token then return end
            local good = pcall(function()
                return api.samePlayer(state.player) and api.alive(state.enemy, state.component)
            end)
            if good then remove(key, "timed burn expired") else remove(key, "timed target unavailable") end
        end)
        if not ok or not finite(handle) or handle % 1 ~= 0 then
            disabled = true
            clear("timed scheduler failure")
            report("integer-ms timed cleanup scheduling failed; activation disabled")
            return false
        end
        return true
    end
    return {
        reset = function() clear("player/world reset") end,
        apply = function(enemy, handle)
            if disabled then return false end
            local left = query(enemy, handle)
            if not left then
                api.trace("burn visual: no readable active timed ignite; skipped")
                return false
            end
            local key, player = api.key(enemy), api.playerKey()
            if key == nil or player == nil then return false end
            local state = states[key]
            if state then
                state.handle = handle
                api.trace("burn visual: refreshed, remaining=%.2fs", left)
                return true
            end
            if count >= 8 then return false end
            state = { enemy = enemy, handle = handle, player = player }
            states[key] = state
            count = count + 1
            local ok, err = pcall(function()
                -- create() must leave the private component inactive and report partial allocation.
                local component, why = api.create(enemy)
                state.component = component
                if component == nil or why ~= nil then error(why or "creation failed") end
                if not schedule() then error("cleanup was not queued") end
                if api.activate(component) ~= true then error("activation unconfirmed") end
            end)
            if not ok then
                disabled = true
                remove(key, "setup failure")
                report(err)
                return false
            end
            api.trace("burn visual: attached, remaining=%.2fs, targets=%d", left, count)
            return true
        end,
        applyTimed = function(enemy, seconds)
            if disabled or not finite(seconds) or seconds <= 0 or seconds > 60 then return false end
            local key, player = api.key(enemy), api.playerKey()
            if key == nil or player == nil then return false end
            local state = states[key]
            if state then
                state.handle = nil
                state.player = player
                if not scheduleTimed(key, state, seconds) then return false end
                api.trace("burn visual: refreshed fixed duration=%.2fs", seconds)
                return true
            end
            if count >= 8 then return false end
            state = { enemy = enemy, handle = nil, player = player }
            states[key] = state
            count = count + 1
            local ok, err = pcall(function()
                local component, why = api.create(enemy)
                state.component = component
                if component == nil or why ~= nil then error(why or "creation failed") end
                if not scheduleTimed(key, state, seconds) then error("cleanup was not queued") end
                if api.activate(component) ~= true then error("activation unconfirmed") end
            end)
            if not ok then
                disabled = true
                remove(key, "timed setup failure")
                report(err)
                return false
            end
            api.trace("burn visual: attached fixed duration=%.2fs, targets=%d", seconds, count)
            return true
        end,
    }
end
