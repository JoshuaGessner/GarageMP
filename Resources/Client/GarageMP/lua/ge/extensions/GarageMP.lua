local M = {}

local logTag = "GarageMP"
local seenRequests = {}

local function safeJsonDecode(raw)
    local ok, parsed = pcall(function()
        return jsonDecode(raw)
    end)
    if ok then
        return parsed
    end
    return nil
end

local function safeJsonEncode(tbl)
    local ok, encoded = pcall(function()
        return jsonEncode(tbl)
    end)
    if ok then
        return encoded
    end
    return "{}"
end

local function applyTransform(veh, vehicle)
    if not veh or not vehicle then
        return
    end

    if vehicle.pos then
        local p = vehicle.pos
        local pos = vec3(p[1] or 0, p[2] or 0, p[3] or 0)
        if veh.setPositionNoPhysicsReset then
            veh:setPositionNoPhysicsReset(pos)
        elseif veh.setPosition then
            veh:setPosition(pos)
        end
    end

    if vehicle.rot and veh.setRotation then
        local r = vehicle.rot
        local quatStr = string.format("%s %s %s %s", tostring(r[1] or 0), tostring(r[2] or 0), tostring(r[3] or 0), tostring(r[4] or 1))
        veh:setRotation(quatStr)
    end
end

local function spawnOne(item)
    local vehicle = item.vehicle or {}
    local model = vehicle.jbm or "pickup"

    local options = {
        config = vehicle.vcf,
    }

    local ok, spawnedOrErr = pcall(function()
        return core_vehicles.spawnNewVehicle(model, options)
    end)

    if not ok or not spawnedOrErr then
        return false, nil, tostring(spawnedOrErr or "spawn failed")
    end

    local spawned = spawnedOrErr
    applyTransform(spawned, vehicle)

    local hostVid = nil
    if spawned and spawned.getID then
        hostVid = spawned:getID()
    end

    return true, hostVid, ""
end

local function onSpawnBatch(rawData)
    local payload = safeJsonDecode(rawData)
    if type(payload) ~= "table" then
        log("E", logTag, "Invalid GarageMP_SpawnBatch payload")
        return
    end

    local requestId = tostring(payload.requestId or "")
    if requestId == "" then
        return
    end

    if seenRequests[requestId] then
        local ack = {
            requestId = requestId,
            duplicate = true,
            results = {},
        }
        TriggerServerEvent("GarageMP_SpawnComplete", safeJsonEncode(ack))
        return
    end

    seenRequests[requestId] = true

    local results = {}
    local items = payload.items or {}
    for _, item in ipairs(items) do
        local success, hostVid, err = spawnOne(item)
        table.insert(results, {
            slot = item.slot,
            success = success,
            hostVid = hostVid,
            error = err,
        })
    end

    local ack = {
        requestId = requestId,
        kind = payload.kind,
        ownerBeammpID = payload.ownerBeammpID,
        results = results,
    }
    TriggerServerEvent("GarageMP_SpawnComplete", safeJsonEncode(ack))
end

local function removeByVid(vid)
    if not vid then
        return false, "missing vehicle id"
    end

    local okCore, coreResult = pcall(function()
        if core_vehicles and core_vehicles.removeVehicle then
            core_vehicles.removeVehicle(vid)
            return true
        end
        return false
    end)
    if okCore and coreResult == true then
        return true, ""
    end

    local okObj, objResult = pcall(function()
        if be and be.getObjectByID then
            local obj = be:getObjectByID(vid)
            if obj and obj.delete then
                obj:delete()
                return true
            end
        end
        return false
    end)
    if okObj and objResult == true then
        return true, ""
    end

    return false, "failed to remove proxy vehicle"
end

local function onRemoveProxyBatch(rawData)
    local payload = safeJsonDecode(rawData)
    if type(payload) ~= "table" then
        log("E", logTag, "Invalid GarageMP_RemoveProxyBatch payload")
        return
    end

    local requestId = tostring(payload.requestId or "")
    if requestId == "" then
        return
    end

    local results = {}
    local items = payload.items or {}
    for _, item in ipairs(items) do
        local success, err = removeByVid(item.hostVid)
        table.insert(results, {
            slot = item.slot,
            hostVid = item.hostVid,
            success = success,
            error = err,
        })
    end

    local ack = {
        requestId = requestId,
        ownerBeammpID = payload.ownerBeammpID,
        results = results,
    }
    TriggerServerEvent("GarageMP_RemoveProxyComplete", safeJsonEncode(ack))
end

local function onExtensionLoaded()
    log("I", logTag, "GarageMP client extension loaded")
    AddEventHandler("GarageMP_SpawnBatch", onSpawnBatch)
    AddEventHandler("GarageMP_RemoveProxyBatch", onRemoveProxyBatch)
end

M.onExtensionLoaded = onExtensionLoaded

return M
