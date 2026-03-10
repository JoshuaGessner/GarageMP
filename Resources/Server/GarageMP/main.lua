local GARAGEMP_PREFIX = "[GarageMP] "
local DATA_DIR = "Resources/Server/GarageMP/data"
local CONFIG_PATH = DATA_DIR .. "/config.json"
local AUTOSAVE_EVENT = "GarageMP_AutoSave"
local RETRY_EVENT = "GarageMP_RetryTick"

local DEFAULT_CONFIG = {
    admins = {},
    persistList = {},
    settings = {
        autoSaveIntervalMs = 300000,
        maxVehiclesPerPlayer = 5,
        serverMaxCarsPerPlayer = 0,
        commandPrefix = "/garagemp",
        syncMode = "proxy",
        excludeGuestsAsHosts = true,
        spawnMaxRetries = 3,
        retryBaseDelayMs = 1500,
        removeMaxRetries = 2,
        joinReadyDelaySec = 8,
        ownerDispatchCooldownSec = 3,
        maxSyncQueuePerOwner = 64,
        maxRetryQueueSize = 1024,
        maxPendingRequestsPerOwner = 24,
        spawnRequestTimeoutSec = 25,
        removeRequestTimeoutSec = 20,
        stateCompactionIntervalSec = 60,
        enableCircuitBreaker = true,
        circuitBreakerCooldownSec = 10,
    },
}

local config = {}
local persistListSet = {}
local adminSet = {}
local savedVehicles = {} -- beammpID -> array of vehicles
local playerToBeammpID = {} -- pid -> beammpID
local proxyAssignments = {} -- ownerBeammpID -> array {hostPid, hostVid, slot}
local proxyIndex = {} -- "pid:vid" -> ownerBeammpID
local pendingRestore = {} -- beammpID -> true
local pendingRequests = {} -- requestId -> request state
local retryQueue = {} -- requestId -> {dueAt, request}
local pendingRemoveRequests = {} -- requestId -> remove request state
local removeRetryQueue = {} -- requestId -> {dueAt, request}
local offlineQueue = {} -- ownerBeammpID -> true
local syncQueue = {} -- ownerBeammpID -> array {slot, vehicle}
local pendingReservations = {} -- hostPid -> reserved spawn count
local dirtyOwners = {} -- beammpID -> true
local ownerState = {} -- ownerBeammpID -> state string
local ownerNextDispatchAt = {} -- ownerBeammpID -> epoch sec
local retryDedupe = {} -- retrySignature -> requestId
local playerJoinReadyAt = {} -- pid -> epoch sec when safe for client events
local storageWritable = true
local lastStorageProbeAt = 0
local lastStateCompactionAt = 0
local circuitBreakerUntil = 0
local configDirty = false
local requestCounter = 0
local parseAckPayload
local getRequestItemBySlot
local tryDrainOfflineQueue
local findOnlinePidByBeammpID
local maxSyncQueuePerOwner
local openCircuitBreaker
local isProxyMode
local normalizeSyncMode
local applySyncModeTransition
local ensureDataDir

local function log(...)
    print(GARAGEMP_PREFIX, ...)
end

local function normalizePid(pid)
    if type(pid) == "number" then
        return pid
    end
    if type(pid) == "string" then
        return tonumber(pid)
    end
    return nil
end

local function keyPidVid(pid, vid)
    return tostring(pid) .. ":" .. tostring(vid)
end

local function toSet(array)
    local result = {}
    if type(array) ~= "table" then
        return result
    end
    for _, value in ipairs(array) do
        if value ~= nil then
            result[tostring(value)] = true
        end
    end
    return result
end

local function setToArray(tbl)
    local result = {}
    for key, enabled in pairs(tbl) do
        if enabled then
            table.insert(result, tostring(key))
        end
    end
    table.sort(result)
    return result
end

normalizeSyncMode = function(mode)
    local m = string.lower(tostring(mode or "proxy"))
    if m == "proxy" or m == "file" then
        return m
    end
    return nil
end

isProxyMode = function()
    local mode = normalizeSyncMode(config.settings and config.settings.syncMode)
    if not mode then
        return true
    end
    return mode == "proxy"
end

local function currentSyncMode()
    return normalizeSyncMode(config.settings and config.settings.syncMode) or "proxy"
end

local function clearProxyDispatchStateForOwner(ownerBeammpID)
    ownerBeammpID = tostring(ownerBeammpID)
    syncQueue[ownerBeammpID] = nil
    offlineQueue[ownerBeammpID] = nil
    pendingRestore[ownerBeammpID] = nil

    local retryIds = {}
    for requestId, envelope in pairs(retryQueue) do
        local req = envelope and envelope.request or nil
        if req and tostring(req.ownerBeammpID) == ownerBeammpID and tostring(req.kind) == "proxy" then
            table.insert(retryIds, requestId)
        end
    end
    for _, requestId in ipairs(retryIds) do
        local req = retryQueue[requestId] and retryQueue[requestId].request or nil
        if req then
            local signature = retrySignature(req)
            if signature and retryDedupe[signature] == requestId then
                retryDedupe[signature] = nil
            end
        end
        retryQueue[requestId] = nil
    end

    local pendingIds = {}
    for requestId, req in pairs(pendingRequests) do
        if tostring(req.ownerBeammpID) == ownerBeammpID and tostring(req.kind) == "proxy" then
            table.insert(pendingIds, requestId)
        end
    end
    for _, requestId in ipairs(pendingIds) do
        local req = pendingRequests[requestId]
        if req then
            releaseSlots(req.hostPid, req.reservedSlots or #(req.items or {}))
        end
        pendingRequests[requestId] = nil
    end

    removeProxyVehiclesForOwner(ownerBeammpID)
    clearOwnerProxyAssignments(ownerBeammpID)
    setOwnerState(ownerBeammpID, "file-only")
end

local function enqueueOfflinePersistOwnersForProxy()
    for ownerBeammpID, enabled in pairs(persistListSet) do
        if enabled then
            local ownerPid = findOnlinePidByBeammpID(ownerBeammpID)
            if not ownerPid then
                queueOwnerForLater(ownerBeammpID)
            end
        end
    end
end

applySyncModeTransition = function(nextMode)
    local mode = normalizeSyncMode(nextMode)
    if not mode then
        return false, "invalid mode"
    end
    local prevMode = currentSyncMode()
    if prevMode == mode then
        return true, "no-op"
    end

    if mode == "file" then
        for ownerBeammpID, _ in pairs(persistListSet) do
            clearProxyDispatchStateForOwner(ownerBeammpID)
        end
        local retryIds = {}
        for requestId, envelope in pairs(retryQueue) do
            local req = envelope and envelope.request or nil
            if req and tostring(req.kind) == "proxy" then
                table.insert(retryIds, requestId)
            end
        end
        for _, requestId in ipairs(retryIds) do
            local req = retryQueue[requestId] and retryQueue[requestId].request or nil
            if req then
                local signature = retrySignature(req)
                if signature and retryDedupe[signature] == requestId then
                    retryDedupe[signature] = nil
                end
            end
            retryQueue[requestId] = nil
        end
    elseif mode == "proxy" then
        enqueueOfflinePersistOwnersForProxy()
        tryDrainOfflineQueue()
    end

    return true, "changed"
end

local function ownerQueueCount(ownerBeammpID)
    local q = syncQueue[tostring(ownerBeammpID)]
    if type(q) ~= "table" then
        return 0
    end
    return #q
end

local function basePerPlayerCap()
    local cap = tonumber(config.settings.maxVehiclesPerPlayer) or 5
    if cap < 1 then
        cap = 1
    end
    return math.floor(cap)
end

local function effectivePerPlayerCap()
    local cap = basePerPlayerCap()
    local serverCap = tonumber(config.settings.serverMaxCarsPerPlayer) or 0
    if serverCap >= 1 then
        serverCap = math.floor(serverCap)
        if serverCap < cap then
            cap = serverCap
        end
    end
    return cap
end

local function trimOwnerVehicles(ownerBeammpID, reason)
    ownerBeammpID = tostring(ownerBeammpID)
    local list = savedVehicles[ownerBeammpID]
    if type(list) ~= "table" then
        savedVehicles[ownerBeammpID] = {}
        return false
    end

    local cap = effectivePerPlayerCap()
    if #list <= cap then
        return false
    end

    local trimmed = {}
    for i = 1, cap do
        table.insert(trimmed, list[i])
    end
    savedVehicles[ownerBeammpID] = trimmed
    dirtyOwners[ownerBeammpID] = true
    log("Trimmed owner", ownerBeammpID, "from", #list, "to", #trimmed, "vehicles", "reason", tostring(reason or "cap"))
    return true
end

local function countPlayerVehicles(pid)
    local rawVehicles = MP.GetPlayerVehicles(pid)
    if type(rawVehicles) ~= "table" then
        return 0
    end
    local count = 0
    for _, _ in pairs(rawVehicles) do
        count = count + 1
    end
    return count
end

local function hasVehicle(pid, vid)
    local rawVehicles = MP.GetPlayerVehicles(pid)
    if type(rawVehicles) ~= "table" then
        return false
    end
    local needle = tostring(vid)
    for existingVid, _ in pairs(rawVehicles) do
        if tostring(existingVid) == needle then
            return true
        end
    end
    return false
end

local function reserveSlots(pid, amount)
    pid = normalizePid(pid)
    local n = tonumber(amount) or 0
    if not pid or n <= 0 then
        return
    end
    pendingReservations[pid] = (pendingReservations[pid] or 0) + n
end

local function releaseSlots(pid, amount)
    pid = normalizePid(pid)
    local n = tonumber(amount) or 0
    if not pid or n <= 0 then
        return
    end
    local remaining = (pendingReservations[pid] or 0) - n
    if remaining <= 0 then
        pendingReservations[pid] = nil
    else
        pendingReservations[pid] = remaining
    end
end

local function availableSlotsForPid(pid)
    local cap = effectivePerPlayerCap()
    local live = countPlayerVehicles(pid)
    local reserved = pendingReservations[pid] or 0
    local available = cap - live - reserved
    if available < 0 then
        available = 0
    end
    return available
end

local function queueSyncItems(ownerBeammpID, items)
    ownerBeammpID = tostring(ownerBeammpID)
    if type(items) ~= "table" or #items == 0 then
        return
    end

    local existing = syncQueue[ownerBeammpID] or {}
    local bySlot = {}
    for _, item in ipairs(existing) do
        bySlot[tostring(item.slot)] = item
    end
    for _, item in ipairs(items) do
        if item and item.vehicle ~= nil then
            bySlot[tostring(item.slot)] = {
                slot = item.slot,
                vehicle = item.vehicle,
            }
        end
    end

    local merged = {}
    for _, item in pairs(bySlot) do
        table.insert(merged, item)
    end
    table.sort(merged, function(a, b)
        local sa = tonumber(a.slot)
        local sb = tonumber(b.slot)
        if sa and sb then
            return sa < sb
        end
        return tostring(a.slot) < tostring(b.slot)
    end)
    local cap = maxSyncQueuePerOwner()
    if #merged > cap then
        local trimmed = {}
        for i = 1, cap do
            table.insert(trimmed, merged[i])
        end
        merged = trimmed
        openCircuitBreaker("sync queue cap reached for owner " .. ownerBeammpID)
    end
    syncQueue[ownerBeammpID] = merged
    offlineQueue[ownerBeammpID] = true
end

local function replaceSyncQueue(ownerBeammpID, items)
    ownerBeammpID = tostring(ownerBeammpID)
    local nextQueue = {}
    if type(items) == "table" then
        for _, item in ipairs(items) do
            if item and item.vehicle ~= nil then
                table.insert(nextQueue, {
                    slot = item.slot,
                    vehicle = item.vehicle,
                })
            end
        end
    end
    table.sort(nextQueue, function(a, b)
        local sa = tonumber(a.slot)
        local sb = tonumber(b.slot)
        if sa and sb then
            return sa < sb
        end
        return tostring(a.slot) < tostring(b.slot)
    end)
    if #nextQueue == 0 then
        syncQueue[ownerBeammpID] = nil
        offlineQueue[ownerBeammpID] = nil
    else
        syncQueue[ownerBeammpID] = nextQueue
        offlineQueue[ownerBeammpID] = true
    end
end

local function readText(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local contents = f:read("*a")
    f:close()
    return contents
end

local function writeTextAtomic(path, text)
    local tmp = path .. ".tmp"
    local backup = path .. ".bak"
    local f = io.open(tmp, "w")
    if not f then
        return false, "failed to open temp file for writing"
    end
    local wOk, wErr = f:write(text)
    if not wOk then
        f:close()
        if FS.Exists(tmp) then FS.Remove(tmp) end
        return false, "write failed: " .. tostring(wErr)
    end
    local flOk, flErr = f:flush()
    if not flOk then
        f:close()
        if FS.Exists(tmp) then FS.Remove(tmp) end
        return false, "flush failed: " .. tostring(flErr)
    end
    f:close()

    local hadExisting = FS.Exists(path)
    if hadExisting then
        if FS.Exists(backup) then
            FS.Remove(backup)
        end
        local bakOk, bakErr = FS.Rename(path, backup)
        if not bakOk then
            return false, "failed creating backup file: " .. tostring(bakErr)
        end
    end

    local mvOk, mvErr = FS.Rename(tmp, path)
    if not mvOk then
        if hadExisting and FS.Exists(backup) then
            FS.Rename(backup, path)
        end
        return false, "failed renaming temp file: " .. tostring(mvErr)
    end
    if hadExisting and FS.Exists(backup) then
        FS.Remove(backup)
    end
    return true, ""
end

local function probeStorageWritable()
    if not FS.Exists(DATA_DIR) then
        return false, "data dir missing"
    end
    local probePath = DATA_DIR .. "/.garagemp_write_probe"
    local ok, err = writeTextAtomic(probePath, tostring(os.time()))
    if not ok then
        return false, err
    end
    if FS.Exists(probePath) then
        FS.Remove(probePath)
    end
    return true, ""
end

local function refreshStorageWritable(force)
    local now = os.time()
    -- Always force re-probe when storage is currently not writable
    if not force and storageWritable and (now - lastStorageProbeAt) < 60 then
        return storageWritable
    end
    lastStorageProbeAt = now
    ensureDataDir()
    local ok, err = probeStorageWritable()
    storageWritable = ok
    if not ok then
        log("Storage is not writable:", tostring(err))
    end
    return storageWritable
end

ensureDataDir = function()
    local ok, err = FS.CreateDirectory(DATA_DIR)
    if not ok then
        log("Failed to create data dir:", err)
        return false
    end
    return true
end

local function findJsonStart(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local idx = raw:find("{", 1, true)
    if not idx then
        return nil
    end
    return raw:sub(idx)
end

local function extractVehicleJson(rawVehicleData)
    local jsonPart = findJsonStart(rawVehicleData)
    if not jsonPart then
        return nil
    end
    return Util.JsonDecode(jsonPart)
end

local function loadConfig()
    config = Util.JsonDecode(Util.JsonEncode(DEFAULT_CONFIG)) or DEFAULT_CONFIG
    if not FS.Exists(CONFIG_PATH) then
        persistListSet = toSet(config.persistList)
        adminSet = toSet(config.admins)
        return
    end

    local raw = readText(CONFIG_PATH)
    if not raw then
        log("Could not read config.json, using defaults")
        persistListSet = toSet(config.persistList)
        adminSet = toSet(config.admins)
        return
    end

    local decoded = Util.JsonDecode(raw)
    if type(decoded) ~= "table" then
        log("Config decode failed, using defaults")
        persistListSet = toSet(config.persistList)
        adminSet = toSet(config.admins)
        return
    end

    if type(decoded.settings) ~= "table" then
        decoded.settings = {}
    end

    for k, v in pairs(DEFAULT_CONFIG.settings) do
        if decoded.settings[k] == nil then
            decoded.settings[k] = v
        end
    end
    local normalizedMode = normalizeSyncMode(decoded.settings.syncMode)
    if not normalizedMode then
        decoded.settings.syncMode = "proxy"
    else
        decoded.settings.syncMode = normalizedMode
    end
    if type(decoded.admins) ~= "table" then
        decoded.admins = {}
    end
    if type(decoded.persistList) ~= "table" then
        decoded.persistList = {}
    end

    config = decoded
    persistListSet = toSet(config.persistList)
    adminSet = toSet(config.admins)
end

local function saveConfig()
    if not storageWritable then
        return false
    end
    config.admins = setToArray(adminSet)
    config.persistList = setToArray(persistListSet)
    local encoded = Util.JsonEncode(config)
    local ok, err = writeTextAtomic(CONFIG_PATH, encoded)
    if not ok then
        log("Failed to save config:", err)
        if string.find(tostring(err), "open temp file", 1, true) then
            storageWritable = false
            openCircuitBreaker("storage not writable")
        end
    else
        configDirty = false
    end
    return ok
end

local function vehiclesPath(beammpID)
    return DATA_DIR .. "/vehicles_" .. tostring(beammpID) .. ".json"
end

local function savePlayerVehicles(beammpID)
    if not storageWritable then
        return false
    end
    local payload = {
        beammpID = tostring(beammpID),
        lastUpdated = os.time(),
        vehicles = savedVehicles[tostring(beammpID)] or {},
    }
    local ok, err = writeTextAtomic(vehiclesPath(beammpID), Util.JsonEncode(payload))
    if not ok then
        log("Failed saving vehicles for", beammpID, err)
        if string.find(tostring(err), "open temp file", 1, true) then
            storageWritable = false
            openCircuitBreaker("storage not writable")
        end
    else
        dirtyOwners[tostring(beammpID)] = nil
    end
    return ok
end

local function markOwnerDirty(beammpID)
    if beammpID ~= nil then
        dirtyOwners[tostring(beammpID)] = true
    end
end

local function markConfigDirty()
    configDirty = true
end

local function loadPlayerVehicles(beammpID)
    local path = vehiclesPath(beammpID)
    if not FS.Exists(path) then
        savedVehicles[tostring(beammpID)] = savedVehicles[tostring(beammpID)] or {}
        return
    end
    local raw = readText(path)
    if not raw then
        return
    end
    local decoded = Util.JsonDecode(raw)
    if type(decoded) ~= "table" or type(decoded.vehicles) ~= "table" then
        log("Vehicle data corrupted for", beammpID, "- using empty list")
        local backup = path .. ".corrupt_" .. tostring(os.time())
        FS.Copy(path, backup)
        savedVehicles[tostring(beammpID)] = {}
        savePlayerVehicles(beammpID)
        return
    end
    savedVehicles[tostring(beammpID)] = decoded.vehicles
    trimOwnerVehicles(beammpID, "load")
    dirtyOwners[tostring(beammpID)] = nil
end

local function loadAllPlayerVehicles()
    if not FS.Exists(DATA_DIR) then
        return
    end
    local files = FS.ListFiles(DATA_DIR)
    for _, name in pairs(files) do
        local id = string.match(name, "^vehicles_(.+)%.json$")
        if id then
            loadPlayerVehicles(id)
        end
    end
end

local function isPersistEnabled(beammpID)
    return persistListSet[tostring(beammpID)] == true
end

local function getBeammpID(pid)
    pid = normalizePid(pid)
    if not pid then
        return nil
    end
    if playerToBeammpID[pid] then
        return playerToBeammpID[pid]
    end
    local ids = MP.GetPlayerIdentifiers(pid)
    if type(ids) == "table" and ids.beammp then
        playerToBeammpID[pid] = tostring(ids.beammp)
        return playerToBeammpID[pid]
    end
    return nil
end

local function isAdmin(pid)
    local bid = getBeammpID(pid)
    if not bid then
        return false
    end
    return adminSet[bid] == true
end

local function findPlayerByName(name)
    local needle = string.lower(tostring(name or ""))
    if needle == "" then
        return nil
    end
    local players = MP.GetPlayers()
    for pid, pname in pairs(players) do
        if string.lower(pname) == needle then
            return normalizePid(pid), pname
        end
    end
    return nil
end

local function upsertVehicle(ownerBeammpID, vehicle)
    ownerBeammpID = tostring(ownerBeammpID)
    savedVehicles[ownerBeammpID] = savedVehicles[ownerBeammpID] or {}
    local list = savedVehicles[ownerBeammpID]
    local key = tostring((vehicle.meta and vehicle.meta.ownerVid) or "")
    for idx, existing in ipairs(list) do
        local existingKey = tostring((existing.meta and existing.meta.ownerVid) or "")
        if key ~= "" and existingKey == key then
            list[idx] = vehicle
            trimOwnerVehicles(ownerBeammpID, "upsert-update")
            markOwnerDirty(ownerBeammpID)
            return
        end
    end
    table.insert(list, vehicle)
    trimOwnerVehicles(ownerBeammpID, "upsert-insert")
    markOwnerDirty(ownerBeammpID)
end

local function removeVehicleByOwnerVid(ownerBeammpID, ownerVid)
    ownerBeammpID = tostring(ownerBeammpID)
    local list = savedVehicles[ownerBeammpID]
    if type(list) ~= "table" then
        return
    end
    local out = {}
    for _, v in ipairs(list) do
        local existingVid = (v.meta and v.meta.ownerVid) or nil
        if tostring(existingVid) ~= tostring(ownerVid) then
            table.insert(out, v)
        end
    end
    savedVehicles[ownerBeammpID] = out
    markOwnerDirty(ownerBeammpID)
end

local function snapshotOwnerVehicles(pid, ownerBeammpID)
    ownerBeammpID = tostring(ownerBeammpID)
    local existing = savedVehicles[ownerBeammpID]
    if type(existing) ~= "table" or #existing == 0 then
        -- Nothing saved in memory; persist as-is (don't overwrite with empty)
        replaceSyncQueue(ownerBeammpID, {})
        savePlayerVehicles(ownerBeammpID)
        return
    end

    -- Refresh positions for vehicles we already have, but never replace the list
    local rawVehicles = MP.GetPlayerVehicles(pid)
    if type(rawVehicles) == "table" then
        local byVid = {}
        for vid, rawData in pairs(rawVehicles) do
            byVid[tostring(normalizePid(vid) or vid)] = rawData
        end

        for _, v in ipairs(existing) do
            local ownerVid = v.meta and v.meta.ownerVid
            if ownerVid then
                local vidKey = tostring(ownerVid)
                -- Try to refresh position from live data
                local posRaw, err = MP.GetPositionRaw(pid, normalizePid(ownerVid) or ownerVid)
                if type(posRaw) == "table" and err == "" then
                    v.pos = posRaw.pos or v.pos
                    v.rot = posRaw.rot or v.rot
                end
                -- Update config if still available
                if byVid[vidKey] then
                    local decoded = extractVehicleJson(byVid[vidKey])
                    if decoded then
                        v.jbm = decoded.jbm or v.jbm
                        v.vcf = decoded.vcf or v.vcf
                    end
                end
                if v.meta then
                    v.meta.ownerPidAtSnapshot = pid
                    v.meta.timestamp = os.time()
                end
            end
        end
    end

    replaceSyncQueue(ownerBeammpID, {})
    markOwnerDirty(ownerBeammpID)
    savePlayerVehicles(ownerBeammpID)
end

local function getConnectedEligibleHosts(excludePid)
    local hosts = {}
    local players = MP.GetPlayers()
    for pid, _ in pairs(players) do
        pid = normalizePid(pid)
        if pid and pid ~= excludePid then
            if not config.settings.excludeGuestsAsHosts or not MP.IsPlayerGuest(pid) then
                table.insert(hosts, pid)
            end
        end
    end
    return hosts
end

local function hostLoad(pid)
    local count = 0
    for _, assignments in pairs(proxyAssignments) do
        for _, a in ipairs(assignments) do
            if a.hostPid == pid then
                count = count + 1
            end
        end
    end
    return count
end

local function sortHostsByAvailability(hosts)
    table.sort(hosts, function(a, b)
        local aa = availableSlotsForPid(a)
        local ab = availableSlotsForPid(b)
        if aa == ab then
            local la = hostLoad(a)
            local lb = hostLoad(b)
            if la == lb then
                return a < b
            end
            return la < lb
        end
        return aa > ab
    end)
end

local function nextRequestId()
    requestCounter = requestCounter + 1
    return tostring(os.time()) .. "-" .. tostring(requestCounter)
end

local function nowSec()
    return os.time()
end

local function joinReadyDelaySec()
    local n = tonumber(config.settings.joinReadyDelaySec) or 8
    if n < 0 then
        n = 0
    end
    return math.floor(n)
end

local function ownerDispatchCooldownSec()
    local n = tonumber(config.settings.ownerDispatchCooldownSec) or 3
    if n < 0 then
        n = 0
    end
    return math.floor(n)
end

maxSyncQueuePerOwner = function()
    local n = tonumber(config.settings.maxSyncQueuePerOwner) or 64
    if n < 1 then
        n = 1
    end
    return math.floor(n)
end

local function maxRetryQueueSize()
    local n = tonumber(config.settings.maxRetryQueueSize) or 1024
    if n < 16 then
        n = 16
    end
    return math.floor(n)
end

local function maxPendingRequestsPerOwner()
    local n = tonumber(config.settings.maxPendingRequestsPerOwner) or 24
    if n < 1 then
        n = 1
    end
    return math.floor(n)
end

local function spawnRequestTimeoutSec()
    local n = tonumber(config.settings.spawnRequestTimeoutSec) or 25
    if n < 5 then
        n = 5
    end
    return math.floor(n)
end

local function removeRequestTimeoutSec()
    local n = tonumber(config.settings.removeRequestTimeoutSec) or 20
    if n < 5 then
        n = 5
    end
    return math.floor(n)
end

local function stateCompactionIntervalSec()
    local n = tonumber(config.settings.stateCompactionIntervalSec) or 60
    if n < 10 then
        n = 10
    end
    return math.floor(n)
end

local function circuitBreakerEnabled()
    return config.settings.enableCircuitBreaker ~= false
end

local function circuitBreakerCooldownSec()
    local n = tonumber(config.settings.circuitBreakerCooldownSec) or 10
    if n < 1 then
        n = 1
    end
    return math.floor(n)
end

local function setOwnerState(ownerBeammpID, state)
    ownerState[tostring(ownerBeammpID)] = tostring(state)
end

local function isCircuitBreakerOpen()
    return circuitBreakerEnabled() and nowSec() < circuitBreakerUntil
end

openCircuitBreaker = function(reason)
    if not circuitBreakerEnabled() then
        return
    end
    circuitBreakerUntil = nowSec() + circuitBreakerCooldownSec()
    log("Circuit breaker open until", tostring(circuitBreakerUntil), "reason", tostring(reason or "safety"))
end

local function retrySignature(request)
    if type(request) ~= "table" then
        return nil
    end
    local parts = {
        tostring(request.kind or ""),
        tostring(request.ownerBeammpID or ""),
        tostring(request.hostPid or ""),
    }
    for _, item in ipairs(request.items or {}) do
        table.insert(parts, tostring(item.slot or ""))
    end
    return table.concat(parts, "|")
end

local function ownerPendingRequestCount(ownerBeammpID)
    ownerBeammpID = tostring(ownerBeammpID)
    local n = 0
    for _, req in pairs(pendingRequests) do
        if tostring(req.ownerBeammpID) == ownerBeammpID then
            n = n + 1
        end
    end
    return n
end

local function ownerHasInFlight(ownerBeammpID)
    ownerBeammpID = tostring(ownerBeammpID)
    for _, req in pairs(pendingRequests) do
        if tostring(req.ownerBeammpID) == ownerBeammpID then
            return true
        end
    end
    for _, envelope in pairs(retryQueue) do
        local req = envelope and envelope.request or nil
        if req and tostring(req.ownerBeammpID) == ownerBeammpID then
            return true
        end
    end
    return false
end

local function isPlayerReady(pid)
    pid = normalizePid(pid)
    if not pid then
        return false
    end
    if not MP.IsPlayerConnected(pid) then
        return false
    end
    local readyAt = playerJoinReadyAt[pid]
    if not readyAt then
        return false -- client hasn't sent ready event yet
    end
    return nowSec() >= readyAt
end

local function retryBaseDelaySec()
    local baseMs = tonumber(config.settings.retryBaseDelayMs) or 1500
    local sec = math.floor(baseMs / 1000)
    if sec < 1 then
        sec = 1
    end
    return sec
end

local function maxSpawnRetries()
    local n = tonumber(config.settings.spawnMaxRetries) or 3
    if n < 0 then
        n = 0
    end
    return n
end

local function maxRemoveRetries()
    local n = tonumber(config.settings.removeMaxRetries) or 2
    if n < 0 then
        n = 0
    end
    return n
end

local function retryDelaySec(retryNumber)
    local base = retryBaseDelaySec()
    local exp = retryNumber - 1
    if exp < 0 then
        exp = 0
    end
    return base * (2 ^ exp)
end

local function clearOwnerProxyAssignments(ownerBeammpID)
    local assignments = proxyAssignments[tostring(ownerBeammpID)]
    if type(assignments) ~= "table" then
        proxyAssignments[tostring(ownerBeammpID)] = {}
        return
    end
    for _, a in ipairs(assignments) do
        proxyIndex[keyPidVid(a.hostPid, a.hostVid)] = nil
    end
    proxyAssignments[tostring(ownerBeammpID)] = {}
end

local function sendProxyRemoveForOwner(ownerBeammpID)
    local assignments = proxyAssignments[tostring(ownerBeammpID)] or {}
    if #assignments == 0 then
        return
    end

    local byHost = {}
    for _, a in ipairs(assignments) do
        byHost[a.hostPid] = byHost[a.hostPid] or {}
        table.insert(byHost[a.hostPid], {
            hostVid = a.hostVid,
            slot = a.slot,
        })
    end

    for hostPid, items in pairs(byHost) do
        local requestId = nextRequestId()
        local req = {
            requestId = requestId,
            ownerBeammpID = tostring(ownerBeammpID),
            hostPid = hostPid,
            items = items,
            ts = nowSec(),
            sentAt = nowSec(),
            retries = 0,
        }
        pendingRemoveRequests[requestId] = req
        local ok, err = MP.TriggerClientEventJson(hostPid, "GarageMP_RemoveProxyBatch", {
            requestId = requestId,
            ownerBeammpID = tostring(ownerBeammpID),
            items = items,
        })
        if not ok then
            log("Failed to send explicit remove batch to host", hostPid, err)
            pendingRemoveRequests[requestId] = nil
            if req.retries < maxRemoveRetries() then
                local nextReq = {
                    requestId = nextRequestId(),
                    ownerBeammpID = req.ownerBeammpID,
                    hostPid = req.hostPid,
                    items = req.items,
                    ts = nowSec(),
                    retries = req.retries + 1,
                }
                removeRetryQueue[nextReq.requestId] = {
                    dueAt = nowSec() + retryDelaySec(nextReq.retries),
                    request = nextReq,
                }
                log("Scheduled remove retry", nextReq.requestId, "owner", nextReq.ownerBeammpID, "attempt", nextReq.retries)
            end
        else
            log("Dispatched explicit remove batch", requestId, "owner", tostring(ownerBeammpID), "host", hostPid, "items", #items)
        end
    end
end

local function removeProxyVehiclesForOwner(ownerBeammpID)
    sendProxyRemoveForOwner(ownerBeammpID)
    local assignments = proxyAssignments[tostring(ownerBeammpID)] or {}
    for _, a in ipairs(assignments) do
        MP.RemoveVehicle(a.hostPid, a.hostVid)
        proxyIndex[keyPidVid(a.hostPid, a.hostVid)] = nil
    end
    proxyAssignments[tostring(ownerBeammpID)] = {}
end

local function clearOwnerRuntimeState(ownerBeammpID, options)
    ownerBeammpID = tostring(ownerBeammpID)
    options = options or {}

    if options.removeProxies ~= false then
        removeProxyVehiclesForOwner(ownerBeammpID)
    else
        clearOwnerProxyAssignments(ownerBeammpID)
    end

    syncQueue[ownerBeammpID] = nil
    offlineQueue[ownerBeammpID] = nil
    pendingRestore[ownerBeammpID] = nil

    local pendingIds = {}
    for requestId, req in pairs(pendingRequests) do
        if tostring(req.ownerBeammpID) == ownerBeammpID then
            table.insert(pendingIds, requestId)
        end
    end
    for _, requestId in ipairs(pendingIds) do
        local req = pendingRequests[requestId]
        if req then
            releaseSlots(req.hostPid, req.reservedSlots or #(req.items or {}))
        end
        pendingRequests[requestId] = nil
    end

    local retryIds = {}
    for requestId, envelope in pairs(retryQueue) do
        local req = envelope and envelope.request or nil
        if req and tostring(req.ownerBeammpID) == ownerBeammpID then
            table.insert(retryIds, requestId)
        end
    end
    for _, requestId in ipairs(retryIds) do
        local req = retryQueue[requestId] and retryQueue[requestId].request or nil
        if req then
            local signature = retrySignature(req)
            if signature and retryDedupe[signature] == requestId then
                retryDedupe[signature] = nil
            end
        end
        retryQueue[requestId] = nil
    end

    local pendingRemoveIds = {}
    for requestId, req in pairs(pendingRemoveRequests) do
        if tostring(req.ownerBeammpID) == ownerBeammpID then
            table.insert(pendingRemoveIds, requestId)
        end
    end
    for _, requestId in ipairs(pendingRemoveIds) do
        pendingRemoveRequests[requestId] = nil
    end

    local removeRetryIds = {}
    for requestId, envelope in pairs(removeRetryQueue) do
        local req = envelope and envelope.request or nil
        if req and tostring(req.ownerBeammpID) == ownerBeammpID then
            table.insert(removeRetryIds, requestId)
        end
    end
    for _, requestId in ipairs(removeRetryIds) do
        removeRetryQueue[requestId] = nil
    end

    ownerState[ownerBeammpID] = nil
    ownerNextDispatchAt[ownerBeammpID] = nil

    if options.clearSaved then
        savedVehicles[ownerBeammpID] = nil
        dirtyOwners[ownerBeammpID] = nil
    end
end

local function compactRuntimeState(now)
    now = tonumber(now) or nowSec()
    local interval = stateCompactionIntervalSec()
    if (now - lastStateCompactionAt) < interval then
        return
    end
    lastStateCompactionAt = now

    for ownerBeammpID, assignments in pairs(proxyAssignments) do
        if type(assignments) ~= "table" or #assignments == 0 then
            proxyAssignments[ownerBeammpID] = nil
        end
    end

    for ownerBeammpID, _ in pairs(ownerState) do
        if not persistListSet[ownerBeammpID]
            and not offlineQueue[ownerBeammpID]
            and not pendingRestore[ownerBeammpID]
            and ownerQueueCount(ownerBeammpID) == 0
            and not ownerHasInFlight(ownerBeammpID) then
            ownerState[ownerBeammpID] = nil
        end
    end

    for ownerBeammpID, nextAllowed in pairs(ownerNextDispatchAt) do
        local nextTs = tonumber(nextAllowed) or 0
        if (now - nextTs) > interval
            and not offlineQueue[ownerBeammpID]
            and not pendingRestore[ownerBeammpID]
            and ownerQueueCount(ownerBeammpID) == 0 then
            ownerNextDispatchAt[ownerBeammpID] = nil
        end
    end

    for pid, _ in pairs(playerJoinReadyAt) do
        if not MP.IsPlayerConnected(pid) then
            playerJoinReadyAt[pid] = nil
        end
    end

    for pid, _ in pairs(playerToBeammpID) do
        if not MP.IsPlayerConnected(pid) then
            playerToBeammpID[pid] = nil
        end
    end

    for pid, reserved in pairs(pendingReservations) do
        if (tonumber(reserved) or 0) <= 0 or not MP.IsPlayerConnected(pid) then
            pendingReservations[pid] = nil
        end
    end
end

local function onRemoveProxyComplete(senderPid, rawData)
    local ack = parseAckPayload(rawData)
    if not ack then
        return
    end
    local requestId = tostring(ack.requestId or "")
    if requestId == "" then
        return
    end
    if pendingRemoveRequests[requestId] then
        pendingRemoveRequests[requestId] = nil
    end
end

local function queueOwnerForLater(ownerBeammpID)
    offlineQueue[tostring(ownerBeammpID)] = true
end

local function scheduleRetry(request, reason)
    if type(request) ~= "table" then
        return
    end
    local retries = tonumber(request.retries) or 0
    local readinessRetries = tonumber(request.readinessRetries) or 0
    local reasonText = string.lower(tostring(reason or ""))
    local isReadinessReason = string.find(reasonText, "not ready", 1, true) ~= nil or string.find(reasonText, "hasn't joined", 1, true) ~= nil
    if isReadinessReason and readinessRetries >= 15 then
        log("Readiness retry limit reached for", request.kind, "owner", tostring(request.ownerBeammpID), "reason:", tostring(reason))
        if request.kind == "restore" then
            pendingRestore[tostring(request.ownerBeammpID)] = nil
        else
            queueSyncItems(request.ownerBeammpID, request.items)
            queueOwnerForLater(request.ownerBeammpID)
        end
        return
    end
    if (not isReadinessReason) and retries >= maxSpawnRetries() then
        log("Retry limit reached for", request.kind, "owner", tostring(request.ownerBeammpID), "reason:", tostring(reason))
        if request.kind == "restore" then
            pendingRestore[tostring(request.ownerBeammpID)] = nil
        else
            queueSyncItems(request.ownerBeammpID, request.items)
            queueOwnerForLater(request.ownerBeammpID)
        end
        return
    end

    local nextReq = {
        requestId = nextRequestId(),
        kind = request.kind,
        ownerBeammpID = tostring(request.ownerBeammpID),
        hostPid = request.hostPid,
        items = request.items,
        retries = isReadinessReason and retries or (retries + 1),
        readinessRetries = isReadinessReason and (readinessRetries + 1) or readinessRetries,
        ts = nowSec(),
    }

    local pendingCount = 0
    for _, _ in pairs(retryQueue) do
        pendingCount = pendingCount + 1
    end
    if pendingCount >= maxRetryQueueSize() then
        openCircuitBreaker("retry queue cap reached")
        queueSyncItems(nextReq.ownerBeammpID, nextReq.items)
        queueOwnerForLater(nextReq.ownerBeammpID)
        return
    end

    local signature = retrySignature(nextReq)
    if signature and retryDedupe[signature] then
        return
    end

    retryQueue[nextReq.requestId] = {
        dueAt = nowSec() + (isReadinessReason and math.max(retryBaseDelaySec(), joinReadyDelaySec()) or retryDelaySec(nextReq.retries)),
        request = nextReq,
    }
    if signature then
        retryDedupe[signature] = nextReq.requestId
    end
    log("Scheduled spawn retry", nextReq.requestId, "kind", nextReq.kind, "owner", nextReq.ownerBeammpID, "attempt", nextReq.retries, "reason", tostring(reason))
end

local function sendSpawnBatch(request)
    local totalItems = #(request.items or {})
    if totalItems == 0 then
        return false
    end

    local ownerBeammpID = tostring(request.ownerBeammpID)
    if request.kind == "proxy" and not isProxyMode() then
        queueSyncItems(ownerBeammpID, request.items)
        queueOwnerForLater(ownerBeammpID)
        return false
    end
    if isCircuitBreakerOpen() then
        if request.kind == "proxy" then
            queueSyncItems(ownerBeammpID, request.items)
            queueOwnerForLater(ownerBeammpID)
        end
        return false
    end

    local nextAllowed = ownerNextDispatchAt[ownerBeammpID] or 0
    if nowSec() < nextAllowed then
        if request.kind == "proxy" then
            queueSyncItems(ownerBeammpID, request.items)
            queueOwnerForLater(ownerBeammpID)
        end
        return false
    end

    if ownerPendingRequestCount(ownerBeammpID) >= maxPendingRequestsPerOwner() then
        openCircuitBreaker("pending request cap for owner " .. ownerBeammpID)
        if request.kind == "proxy" then
            queueSyncItems(ownerBeammpID, request.items)
            queueOwnerForLater(ownerBeammpID)
        end
        return false
    end

    if not isPlayerReady(request.hostPid) then
        scheduleRetry(request, "target player not ready")
        return false
    end

    local available = availableSlotsForPid(request.hostPid)
    if available <= 0 then
        if request.kind == "proxy" then
            queueSyncItems(request.ownerBeammpID, request.items)
            ownerNextDispatchAt[ownerBeammpID] = nowSec() + ownerDispatchCooldownSec()
            log("No host capacity for proxy dispatch; queued", totalItems, "owner", tostring(request.ownerBeammpID), "host", tostring(request.hostPid))
            return false
        end
        pendingRestore[tostring(request.ownerBeammpID)] = nil
        log("No owner capacity for restore dispatch; deferred to saved state owner", tostring(request.ownerBeammpID), "pid", tostring(request.hostPid))
        return false
    end

    if available < totalItems then
        local allowed = {}
        local overflow = {}
        for idx, item in ipairs(request.items) do
            if idx <= available then
                table.insert(allowed, item)
            else
                table.insert(overflow, item)
            end
        end
        request.items = allowed
        totalItems = #allowed
        if request.kind == "proxy" and #overflow > 0 then
            queueSyncItems(request.ownerBeammpID, overflow)
        elseif request.kind == "restore" and #overflow > 0 then
            log("Restore overflow kept on file for owner", tostring(request.ownerBeammpID), "count", #overflow)
        end
    end

    if totalItems == 0 then
        return false
    end

    reserveSlots(request.hostPid, totalItems)
    request.reservedSlots = totalItems
    request.sentAt = nowSec()
    pendingRequests[request.requestId] = request
    setOwnerState(ownerBeammpID, request.kind == "restore" and "restoring" or "proxying")
    ownerNextDispatchAt[ownerBeammpID] = nowSec() + ownerDispatchCooldownSec()
    local payload = {
        requestId = request.requestId,
        kind = request.kind,
        ownerBeammpID = tostring(request.ownerBeammpID),
        items = request.items,
    }
    local ok, err = MP.TriggerClientEventJson(request.hostPid, "GarageMP_SpawnBatch", payload)
    if not ok then
        releaseSlots(request.hostPid, request.reservedSlots or 0)
        pendingRequests[request.requestId] = nil
        log("Failed to send spawn batch to", request.hostPid, err)
        scheduleRetry(request, err)
        return false
    end
    log("Dispatched spawn batch", request.requestId, "kind", request.kind, "owner", request.ownerBeammpID, "host", request.hostPid, "items", #request.items)
    return true
end

local function onRetryTick()
    local now = nowSec()

    local staleSpawnIds = {}
    local spawnTimeout = spawnRequestTimeoutSec()
    for requestId, req in pairs(pendingRequests) do
        local sentAt = tonumber(req.sentAt or req.ts) or now
        if (now - sentAt) >= spawnTimeout then
            table.insert(staleSpawnIds, requestId)
        end
    end
    for _, requestId in ipairs(staleSpawnIds) do
        local req = pendingRequests[requestId]
        pendingRequests[requestId] = nil
        if req then
            releaseSlots(req.hostPid, req.reservedSlots or #(req.items or {}))
            scheduleRetry(req, "spawn ack timeout")
            log("Expired stale spawn request", tostring(requestId), "owner", tostring(req.ownerBeammpID), "kind", tostring(req.kind))
        end
    end

    local staleRemoveIds = {}
    local removeTimeout = removeRequestTimeoutSec()
    for requestId, req in pairs(pendingRemoveRequests) do
        local sentAt = tonumber(req.sentAt or req.ts) or now
        if (now - sentAt) >= removeTimeout then
            table.insert(staleRemoveIds, requestId)
        end
    end
    for _, requestId in ipairs(staleRemoveIds) do
        local req = pendingRemoveRequests[requestId]
        pendingRemoveRequests[requestId] = nil
        if req and req.retries < maxRemoveRetries() then
            local nextReq = {
                requestId = nextRequestId(),
                ownerBeammpID = req.ownerBeammpID,
                hostPid = req.hostPid,
                items = req.items,
                ts = now,
                retries = req.retries + 1,
            }
            removeRetryQueue[nextReq.requestId] = {
                dueAt = now + retryDelaySec(nextReq.retries),
                request = nextReq,
            }
            log("Expired stale remove request", tostring(requestId), "owner", tostring(req.ownerBeammpID), "retry", tostring(nextReq.requestId))
        end
    end

    local dueIds = {}
    for requestId, envelope in pairs(retryQueue) do
        if envelope.dueAt <= now then
            table.insert(dueIds, requestId)
        end
    end

    for _, requestId in ipairs(dueIds) do
        local envelope = retryQueue[requestId]
        retryQueue[requestId] = nil
        if envelope and envelope.request then
            local req = envelope.request
            if req.kind == "proxy" and not isProxyMode() then
                local signature = retrySignature(req)
                if signature and retryDedupe[signature] == requestId then
                    retryDedupe[signature] = nil
                end
                queueSyncItems(req.ownerBeammpID, req.items)
                queueOwnerForLater(req.ownerBeammpID)
                goto continue_retry
            end
            local signature = retrySignature(req)
            if signature and retryDedupe[signature] == requestId then
                retryDedupe[signature] = nil
            end
            if MP.IsPlayerConnected(req.hostPid) then
                if isPlayerReady(req.hostPid) then
                    if not sendSpawnBatch(req) and req.kind == "proxy" then
                        queueOwnerForLater(req.ownerBeammpID)
                    end
                else
                    scheduleRetry(req, "target player not ready")
                end
            else
                if req.kind == "restore" then
                    pendingRestore[tostring(req.ownerBeammpID)] = nil
                    queueOwnerForLater(req.ownerBeammpID)
                else
                    queueOwnerForLater(req.ownerBeammpID)
                end
            end
        end
        ::continue_retry::
    end

    local dueRemoveIds = {}
    for requestId, envelope in pairs(removeRetryQueue) do
        if envelope.dueAt <= now then
            table.insert(dueRemoveIds, requestId)
        end
    end

    for _, requestId in ipairs(dueRemoveIds) do
        local envelope = removeRetryQueue[requestId]
        removeRetryQueue[requestId] = nil
        if envelope and envelope.request then
            local req = envelope.request
            local ok, err = MP.TriggerClientEventJson(req.hostPid, "GarageMP_RemoveProxyBatch", {
                requestId = req.requestId,
                ownerBeammpID = req.ownerBeammpID,
                items = req.items,
            })
            if ok then
                req.sentAt = nowSec()
                pendingRemoveRequests[req.requestId] = req
                log("Dispatched remove retry", req.requestId, "owner", req.ownerBeammpID, "host", req.hostPid)
            else
                if req.retries < maxRemoveRetries() then
                    local nextReq = {
                        requestId = nextRequestId(),
                        ownerBeammpID = req.ownerBeammpID,
                        hostPid = req.hostPid,
                        items = req.items,
                        ts = nowSec(),
                        retries = req.retries + 1,
                    }
                    removeRetryQueue[nextReq.requestId] = {
                        dueAt = nowSec() + retryDelaySec(nextReq.retries),
                        request = nextReq,
                    }
                    log("Rescheduled remove retry", nextReq.requestId, "owner", nextReq.ownerBeammpID, "attempt", nextReq.retries, "err", tostring(err))
                else
                    log("Remove retry exhausted for owner", tostring(req.ownerBeammpID), "host", tostring(req.hostPid), "err", tostring(err))
                end
            end
        end
    end

    tryDrainOfflineQueue()
    compactRuntimeState(now)
end

local function spawnOwnerOnHosts(ownerBeammpID, excludePid, options)
    ownerBeammpID = tostring(ownerBeammpID)
    if not isProxyMode() then
        setOwnerState(ownerBeammpID, "file-only")
        return
    end
    options = options or {}
    local rebuild = options.rebuild ~= false

    if ownerHasInFlight(ownerBeammpID) and not options.force then
        return
    end

    local ownerPidOnline = findOnlinePidByBeammpID(ownerBeammpID)
    if ownerPidOnline and not options.allowOwnerOnline then
        queueOwnerForLater(ownerBeammpID)
        return
    end

    local sourceItems = {}
    if rebuild then
        trimOwnerVehicles(ownerBeammpID, "proxy-rebuild")
        local vehicles = savedVehicles[ownerBeammpID] or {}
        for i, vehicle in ipairs(vehicles) do
            table.insert(sourceItems, {
                slot = i,
                vehicle = vehicle,
            })
        end
        clearOwnerProxyAssignments(ownerBeammpID)
    else
        local queued = syncQueue[ownerBeammpID] or {}
        for _, item in ipairs(queued) do
            table.insert(sourceItems, {
                slot = item.slot,
                vehicle = item.vehicle,
            })
        end
    end

    if #sourceItems == 0 then
        replaceSyncQueue(ownerBeammpID, {})
        return
    end

    local hosts = getConnectedEligibleHosts(excludePid)
    if #hosts == 0 then
        replaceSyncQueue(ownerBeammpID, sourceItems)
        queueOwnerForLater(ownerBeammpID)
        return
    end

    sortHostsByAvailability(hosts)
    local hostSlots = {}
    for _, hostPid in ipairs(hosts) do
        hostSlots[hostPid] = availableSlotsForPid(hostPid)
    end

    local totalAvailableSlots = 0
    for _, hostPid in ipairs(hosts) do
        totalAvailableSlots = totalAvailableSlots + (hostSlots[hostPid] or 0)
    end

    if totalAvailableSlots <= 0 then
        replaceSyncQueue(ownerBeammpID, sourceItems)
        queueOwnerForLater(ownerBeammpID)
        setOwnerState(ownerBeammpID, "file-fallback")
        ownerNextDispatchAt[ownerBeammpID] = nowSec() + math.max(ownerDispatchCooldownSec(), joinReadyDelaySec())
        log("No host capacity for owner", ownerBeammpID, "keeping file-backed state with queued proxies", #sourceItems)
        return
    end

    local batches = {}
    local remaining = {}
    local hostIndex = 1
    local hostCount = #hosts

    for _, item in ipairs(sourceItems) do
        local assigned = false
        local attempts = 0
        while attempts < hostCount do
            local hostPid = hosts[hostIndex]
            if hostSlots[hostPid] and hostSlots[hostPid] > 0 then
                batches[hostPid] = batches[hostPid] or {}
                table.insert(batches[hostPid], item)
                hostSlots[hostPid] = hostSlots[hostPid] - 1
                assigned = true
                hostIndex = (hostIndex % hostCount) + 1
                break
            end
            hostIndex = (hostIndex % hostCount) + 1
            attempts = attempts + 1
        end
        if not assigned then
            table.insert(remaining, item)
        end
    end

    replaceSyncQueue(ownerBeammpID, remaining)

    local dispatched = 0
    for hostPid, items in pairs(batches) do
        local request = {
            requestId = nextRequestId(),
            kind = "proxy",
            ownerBeammpID = ownerBeammpID,
            hostPid = hostPid,
            items = items,
            retries = 0,
            ts = nowSec(),
        }
        if sendSpawnBatch(request) then
            dispatched = dispatched + #items
        else
            queueSyncItems(ownerBeammpID, items)
        end
    end

    if ownerQueueCount(ownerBeammpID) > 0 then
        queueOwnerForLater(ownerBeammpID)
    else
        offlineQueue[ownerBeammpID] = nil
    end

    log("Assigned owner", ownerBeammpID, "proxied", dispatched, "queued", ownerQueueCount(ownerBeammpID), "hosts", #hosts)
end

findOnlinePidByBeammpID = function(beammpID)
    for pid, bid in pairs(playerToBeammpID) do
        if tostring(bid) == tostring(beammpID) and MP.IsPlayerConnected(pid) then
            return pid
        end
    end
    return nil
end

local function restoreOwnerVehicles(pid, ownerBeammpID)
    local startedAt = nowSec()
    ownerBeammpID = tostring(ownerBeammpID)
    trimOwnerVehicles(ownerBeammpID, "restore")
    local vehicles = savedVehicles[ownerBeammpID] or {}
    removeProxyVehiclesForOwner(ownerBeammpID)

    if #vehicles == 0 then
        pendingRestore[ownerBeammpID] = nil
        return
    end

    pendingRestore[ownerBeammpID] = true
    local items = {}
    local available = availableSlotsForPid(pid)
    if available <= 0 then
        pendingRestore[ownerBeammpID] = nil
        log("Restore skipped due to zero available owner slots", ownerBeammpID, "pid", tostring(pid))
        return
    end

    for i, vehicle in ipairs(vehicles) do
        if #items >= available then
            break
        end
        table.insert(items, { slot = i, vehicle = vehicle })
    end

    local request = {
        requestId = nextRequestId(),
        kind = "restore",
        ownerBeammpID = tostring(ownerBeammpID),
        hostPid = pid,
        items = items,
        retries = 0,
        ts = nowSec(),
    }

    local ok = sendSpawnBatch(request)
    if not ok then
        log("Restore request queued for retry for owner", tostring(ownerBeammpID))
    else
        log("Restore dispatch for owner", tostring(ownerBeammpID), "to pid", pid, "vehicles", #items, "elapsedSec", nowSec() - startedAt)
    end
end

tryDrainOfflineQueue = function()
    if not isProxyMode() then
        return
    end
    for ownerBeammpID, queued in pairs(offlineQueue) do
        if queued then
            if ownerHasInFlight(ownerBeammpID) then
                goto continue
            end
            local nextAllowed = ownerNextDispatchAt[tostring(ownerBeammpID)] or 0
            if nowSec() < nextAllowed then
                goto continue
            end
            if pendingRestore[tostring(ownerBeammpID)] then
                goto continue
            end
            local ownerPid = findOnlinePidByBeammpID(ownerBeammpID)
            if ownerPid then
                offlineQueue[ownerBeammpID] = nil
                restoreOwnerVehicles(ownerPid, ownerBeammpID)
            else
                local hosts = getConnectedEligibleHosts(-1)
                if #hosts > 0 then
                    local hasQueue = ownerQueueCount(ownerBeammpID) > 0
                    spawnOwnerOnHosts(ownerBeammpID, -1, { rebuild = not hasQueue })
                end
            end
        end
        ::continue::
    end
end

local function saveAll()
    if configDirty then
        saveConfig()
    end
    for ownerBeammpID, _ in pairs(savedVehicles) do
        if dirtyOwners[tostring(ownerBeammpID)] then
            savePlayerVehicles(ownerBeammpID)
        end
    end
end

local function saveAllForced()
    saveConfig()
    for ownerBeammpID, _ in pairs(savedVehicles) do
        savePlayerVehicles(ownerBeammpID)
    end
end

parseAckPayload = function(raw)
    local t = Util.JsonDecode(raw)
    if type(t) ~= "table" then
        return nil
    end
    return t
end

getRequestItemBySlot = function(items, slot)
    local slotStr = tostring(slot)
    for _, item in ipairs(items or {}) do
        if tostring(item.slot) == slotStr then
            return item
        end
    end
    return nil
end

local function onSpawnComplete(senderPid, rawData)
    senderPid = normalizePid(senderPid)
    local ack = parseAckPayload(rawData)
    if not ack then
        return
    end
    local req = pendingRequests[tostring(ack.requestId)]
    if not req then
        return
    end
    releaseSlots(req.hostPid, req.reservedSlots or #(req.items or {}))

    local ownerBeammpID = tostring(req.ownerBeammpID)
    if req.kind == "proxy" then
        proxyAssignments[ownerBeammpID] = proxyAssignments[ownerBeammpID] or {}
    end

    local failedItems = {}
    local validatedSuccessBySlot = {}
    if type(ack.results) == "table" then
        for _, item in ipairs(ack.results) do
            local success = item.success == true
            local hostVid = normalizePid(item.hostVid) or item.hostVid
            if not success then
                log("Spawn item failed", "slot", tostring(item.slot), "hostVid", tostring(hostVid), "error", tostring(item.error or "unknown"))
            end
            validatedSuccessBySlot[tostring(item.slot)] = success
            if success and req.kind == "proxy" then
                local slot = normalizePid(item.slot) or item.slot
                table.insert(proxyAssignments[ownerBeammpID], {
                    hostPid = senderPid,
                    hostVid = hostVid,
                    slot = slot,
                })
                proxyIndex[keyPidVid(senderPid, hostVid)] = ownerBeammpID
            elseif not success then
                local original = getRequestItemBySlot(req.items, item.slot)
                table.insert(failedItems, {
                    slot = item.slot,
                    vehicle = original and original.vehicle or nil,
                })
            end
        end
    end

    if #failedItems > 0 then
        local retryItems = {}
        for _, retryItem in ipairs(failedItems) do
            if retryItem.vehicle then
                table.insert(retryItems, retryItem)
            end
        end
        if #retryItems > 0 then
            if req.kind == "proxy" then
                queueSyncItems(ownerBeammpID, retryItems)
                scheduleRetry({
                    kind = req.kind,
                    ownerBeammpID = ownerBeammpID,
                    hostPid = req.hostPid,
                    items = retryItems,
                    retries = req.retries,
                }, "spawn ack had failed items")
                log("Spawn ack had", #retryItems, "failed proxy item(s), queued + retry scheduled for owner", ownerBeammpID)
            else
                scheduleRetry({
                    kind = req.kind,
                    ownerBeammpID = ownerBeammpID,
                    hostPid = req.hostPid,
                    items = retryItems,
                    retries = req.retries,
                }, "spawn ack had failed restore items")
                log("Spawn ack had", #retryItems, "failed restore item(s), retry scheduled for owner", ownerBeammpID)
            end
        end
    end

    if req.kind == "restore" then
        if type(ack.results) == "table" then
            local list = savedVehicles[ownerBeammpID] or {}
            for _, item in ipairs(ack.results) do
                if validatedSuccessBySlot[tostring(item.slot)] == true then
                    local original = getRequestItemBySlot(req.items, item.slot)
                    local slot = tonumber(original and original.slot or item.slot)
                    if slot and list[slot] and list[slot].meta then
                        list[slot].meta.ownerVid = normalizePid(item.hostVid) or item.hostVid
                        list[slot].meta.timestamp = os.time()
                    end
                end
            end
            markOwnerDirty(ownerBeammpID)
        end
        pendingRestore[ownerBeammpID] = nil
        setOwnerState(ownerBeammpID, "online")
    end
    if req.kind == "proxy" then
        if ownerQueueCount(ownerBeammpID) > 0 then
            queueOwnerForLater(ownerBeammpID)
            setOwnerState(ownerBeammpID, "proxying")
        else
            offlineQueue[ownerBeammpID] = nil
            setOwnerState(ownerBeammpID, "idle")
        end
    end
    pendingRequests[tostring(ack.requestId)] = nil
end

local function onAutoSave()
    onRetryTick()
    if not storageWritable then
        refreshStorageWritable(false)
    end
    saveAll()
end

local function onInit()
    log("Starting GarageMP")
    ensureDataDir()
    refreshStorageWritable(true)
    loadConfig()
    loadAllPlayerVehicles()
    MP.RegisterEvent(AUTOSAVE_EVENT, "GarageMP_onAutoSave")
    MP.CreateEventTimer(AUTOSAVE_EVENT, tonumber(config.settings.autoSaveIntervalMs) or 300000)
    MP.CreateEventTimer(RETRY_EVENT, 1000)
    log("Initialized with", tostring(#setToArray(persistListSet)), "persisted owners", "storageWritable", tostring(storageWritable))
end

local function onShutdown()
    saveAllForced()
end

local function onPlayerJoin(pid)
    pid = normalizePid(pid)
    if not pid then
        return
    end
    local bid = getBeammpID(pid)
    if not bid then
        return
    end

    -- Don't set readyAt here — wait for client "ready" event
    setOwnerState(bid, "joining")
    ownerNextDispatchAt[tostring(bid)] = nowSec() + 1
end

local function onClientReady(senderPid, rawData)
    senderPid = normalizePid(senderPid)
    if not senderPid then
        return
    end
    -- Client extension has loaded and is ready to receive events
    if playerJoinReadyAt[senderPid] then
        return -- already marked ready, ignore duplicate
    end
    playerJoinReadyAt[senderPid] = nowSec()
    log("Client ready received", "pid", senderPid)

    local bid = getBeammpID(senderPid)
    if bid and isPersistEnabled(bid) then
        restoreOwnerVehicles(senderPid, bid)
    end

    tryDrainOfflineQueue()
end

local function onPlayerDisconnect(pid)
    pid = normalizePid(pid)
    if not pid then
        return
    end

    pendingReservations[pid] = nil
    playerJoinReadyAt[pid] = nil
    local droppedRequestIds = {}
    for requestId, req in pairs(pendingRequests) do
        if req.hostPid == pid then
            table.insert(droppedRequestIds, requestId)
        end
    end
    for _, requestId in ipairs(droppedRequestIds) do
        local req = pendingRequests[requestId]
        pendingRequests[requestId] = nil
        if req then
            releaseSlots(req.hostPid, req.reservedSlots or #(req.items or {}))
            scheduleRetry(req, "host disconnected before spawn ack")
        end
    end

    local droppedRemovePending = {}
    for requestId, req in pairs(pendingRemoveRequests) do
        if req.hostPid == pid then
            table.insert(droppedRemovePending, requestId)
        end
    end
    for _, requestId in ipairs(droppedRemovePending) do
        pendingRemoveRequests[requestId] = nil
    end

    local droppedRemoveRetry = {}
    for requestId, envelope in pairs(removeRetryQueue) do
        local req = envelope and envelope.request or nil
        if req and req.hostPid == pid then
            table.insert(droppedRemoveRetry, requestId)
        end
    end
    for _, requestId in ipairs(droppedRemoveRetry) do
        removeRetryQueue[requestId] = nil
    end

    local bid = playerToBeammpID[pid] or getBeammpID(pid)
    if bid and isPersistEnabled(bid) then
        setOwnerState(bid, "offline")
        snapshotOwnerVehicles(pid, bid)
        if isProxyMode() then
            spawnOwnerOnHosts(bid, pid)
        else
            clearProxyDispatchStateForOwner(bid)
        end
    end

    local affectedOwners = {}
    for ownerBeammpID, assignments in pairs(proxyAssignments) do
        for _, a in ipairs(assignments) do
            if a.hostPid == pid then
                affectedOwners[ownerBeammpID] = true
                break
            end
        end
    end

    for ownerBeammpID, _ in pairs(affectedOwners) do
        clearOwnerProxyAssignments(ownerBeammpID)
        local ownerPid = findOnlinePidByBeammpID(ownerBeammpID)
        if ownerPid then
            restoreOwnerVehicles(ownerPid, ownerBeammpID)
        elseif isProxyMode() then
            spawnOwnerOnHosts(ownerBeammpID, pid)
        else
            setOwnerState(ownerBeammpID, "file-only")
        end
    end

    playerToBeammpID[pid] = nil
end

local function updateFromVehicleData(pid, vid, rawData)
    local bid = getBeammpID(pid)
    if not bid or not isPersistEnabled(bid) then
        return
    end
    if pendingRestore[tostring(bid)] then
        return
    end

    local decoded = extractVehicleJson(rawData)
    if not decoded then
        return
    end

    local vehicle = {
        jbm = decoded.jbm,
        vcf = decoded.vcf,
        pos = decoded.pos,
        rot = decoded.rot,
        meta = {
            ownerVid = normalizePid(vid) or vid,
            ownerPidAtSnapshot = pid,
            timestamp = os.time(),
        },
    }
    upsertVehicle(bid, vehicle)
end

local function onVehicleSpawn(pid, vid, data)
    updateFromVehicleData(pid, vid, data)
end

local function onVehicleEdited(pid, vid, data)
    local proxyOwner = proxyIndex[keyPidVid(pid, vid)]
    if proxyOwner then
        return 1
    end
    updateFromVehicleData(pid, vid, data)
    return 0
end

local function onVehicleDeleted(pid, vid)
    local proxyOwner = proxyIndex[keyPidVid(pid, vid)]
    if proxyOwner then
        proxyIndex[keyPidVid(pid, vid)] = nil
        if ownerQueueCount(proxyOwner) > 0 then
            spawnOwnerOnHosts(proxyOwner, -1, { rebuild = false })
        end
        return
    end

    local bid = getBeammpID(pid)
    if bid and isPersistEnabled(bid) then
        removeVehicleByOwnerVid(bid, vid)
    end

    tryDrainOfflineQueue()
end

local function onVehicleReset(pid, vid, data)
    local bid = getBeammpID(pid)
    if not bid or not isPersistEnabled(bid) then
        return
    end

    local decoded = Util.JsonDecode(data)
    if type(decoded) ~= "table" then
        return
    end

    local list = savedVehicles[tostring(bid)] or {}
    for _, v in ipairs(list) do
        local ownerVid = v.meta and v.meta.ownerVid
        if tostring(ownerVid) == tostring(vid) then
            v.pos = decoded.pos or v.pos
            v.rot = decoded.rot or v.rot
            v.meta.timestamp = os.time()
            markOwnerDirty(bid)
            break
        end
    end
end

local function sendHelp(pid)
    MP.SendChatMessage(pid, "GarageMP commands: /garagemp help|status|limits|add|remove|list|save|clear|addadmin|removeadmin|info|proxyclear|syncmode|setup")
end

local function resolveCommand(message)
    if type(message) ~= "string" then
        return nil
    end
    local lower = string.lower(message)
    local cp = string.lower(tostring(config.settings.commandPrefix or "/garagemp"))
    if string.sub(lower, 1, #cp) == cp then
        return string.sub(message, #cp + 1)
    end
    return nil
end

local function splitArgs(s)
    local args = {}
    for token in string.gmatch(s, "%S+") do
        table.insert(args, token)
    end
    return args
end

local function onChatMessage(pid, name, message)
    local tail = resolveCommand(message)
    if not tail then
        return 0
    end

    local args = splitArgs(tail)
    local cmd = string.lower(args[1] or "help")

    if cmd == "help" then
        sendHelp(pid)
        return 1
    elseif cmd == "status" then
        local bid = getBeammpID(pid)
        local enabled = bid and isPersistEnabled(bid)
        local count = 0
        if bid and type(savedVehicles[bid]) == "table" then
            count = #savedVehicles[bid]
        end
        MP.SendChatMessage(pid, "GarageMP status: enabled=" .. tostring(enabled) .. ", savedVehicles=" .. tostring(count))
        return 1
    elseif cmd == "limits" then
        local cap = basePerPlayerCap()
        local serverCap = tonumber(config.settings.serverMaxCarsPerPlayer) or 0
        local effective = effectivePerPlayerCap()
        MP.SendChatMessage(pid, "GarageMP limits: modCap=" .. tostring(cap) .. ", serverCap=" .. tostring(serverCap) .. ", effectiveCap=" .. tostring(effective))
        return 1
    elseif cmd == "setup" then
        if next(adminSet) ~= nil then
            MP.SendChatMessage(pid, "GarageMP setup already completed")
            return 1
        end
        local bid = getBeammpID(pid)
        if not bid then
            MP.SendChatMessage(pid, "Could not resolve your BeamMP ID")
            return 1
        end
        adminSet[bid] = true
        saveConfig()
        MP.SendChatMessage(pid, "GarageMP setup complete: you are admin")
        return 1
    end

    if not isAdmin(pid) then
        MP.SendChatMessage(pid, "GarageMP: admin permissions required")
        return 1
    end

    if cmd == "list" then
        local list = setToArray(persistListSet)
        MP.SendChatMessage(pid, "GarageMP persist list count: " .. tostring(#list))
        return 1
    elseif cmd == "save" then
        saveAll()
        MP.SendChatMessage(pid, "GarageMP: data saved")
        return 1
    elseif cmd == "info" then
        local ownerCount = 0
        for _, enabled in pairs(persistListSet) do
            if enabled then
                ownerCount = ownerCount + 1
            end
        end
        local activeProxy = 0
        for _, assignments in pairs(proxyAssignments) do
            activeProxy = activeProxy + #assignments
        end
        local queued = 0
        for _, q in pairs(offlineQueue) do
            if q then
                queued = queued + 1
            end
        end
        local queuedVehicles = 0
        for _, items in pairs(syncQueue) do
            queuedVehicles = queuedVehicles + #items
        end
        local pendingCount = 0
        for _, _ in pairs(pendingRequests) do
            pendingCount = pendingCount + 1
        end
        local retryCount = 0
        for _, _ in pairs(retryQueue) do
            retryCount = retryCount + 1
        end
        local pendingRemoveCount = 0
        for _, _ in pairs(pendingRemoveRequests) do
            pendingRemoveCount = pendingRemoveCount + 1
        end
        local removeRetryCount = 0
        for _, _ in pairs(removeRetryQueue) do
            removeRetryCount = removeRetryCount + 1
        end
        local reservedSlots = 0
        for _, n in pairs(pendingReservations) do
            reservedSlots = reservedSlots + (tonumber(n) or 0)
        end
        MP.SendChatMessage(pid, "GarageMP info: mode=" .. currentSyncMode() .. ", owners=" .. ownerCount .. ", proxies=" .. activeProxy .. ", queuedOwners=" .. queued .. ", queuedVehicles=" .. queuedVehicles .. ", pending=" .. pendingCount .. ", retries=" .. retryCount .. ", pendingRemoves=" .. pendingRemoveCount .. ", removeRetries=" .. removeRetryCount .. ", reserved=" .. reservedSlots .. ", breaker=" .. tostring(isCircuitBreakerOpen()) .. ", cap=" .. tostring(effectivePerPlayerCap()))
        return 1
    elseif cmd == "syncmode" then
        local requested = string.lower(tostring(args[2] or "status"))
        if requested == "status" then
            MP.SendChatMessage(pid, "GarageMP sync mode: " .. currentSyncMode())
            return 1
        end
        local mode = normalizeSyncMode(requested)
        if not mode then
            MP.SendChatMessage(pid, "GarageMP: invalid mode. Use proxy|file|status")
            return 1
        end
        local previous = currentSyncMode()
        config.settings.syncMode = mode
        markConfigDirty()
        local changed, reason = applySyncModeTransition(mode)
        if not changed then
            config.settings.syncMode = previous
            MP.SendChatMessage(pid, "GarageMP: failed to apply mode: " .. tostring(reason))
            return 1
        end
        local saved = saveConfig()
        if reason == "no-op" then
            MP.SendChatMessage(pid, "GarageMP sync mode already " .. mode)
        elseif not saved then
            MP.SendChatMessage(pid, "GarageMP sync mode changed to " .. mode .. " (warning: failed to persist config)")
        else
            MP.SendChatMessage(pid, "GarageMP sync mode changed to " .. mode)
        end
        log("Admin command syncmode by", tostring(name), "mode", tostring(mode), "previous", tostring(previous))
        return 1
    elseif cmd == "add" or cmd == "remove" or cmd == "clear" or cmd == "addadmin" or cmd == "removeadmin" or cmd == "proxyclear" then
        local targetName = args[2]
        if not targetName then
            MP.SendChatMessage(pid, "GarageMP: missing player name")
            return 1
        end
        local targetPid, resolvedName = findPlayerByName(targetName)
        local targetBid = nil
        if targetPid then
            targetBid = getBeammpID(targetPid)
            if not targetBid then
                MP.SendChatMessage(pid, "GarageMP: could not resolve BeamMP ID")
                return 1
            end
        elseif cmd == "proxyclear" then
            targetBid = tostring(targetName)
            resolvedName = tostring(targetName)
        else
            MP.SendChatMessage(pid, "GarageMP: player not found online")
            return 1
        end

        if cmd == "add" then
            persistListSet[targetBid] = true
            markConfigDirty()
            saveConfig()
            MP.SendChatMessage(pid, "GarageMP: persistence enabled for " .. resolvedName)
        elseif cmd == "remove" then
            persistListSet[targetBid] = nil
            clearOwnerRuntimeState(targetBid, { removeProxies = true, clearSaved = false })
            markConfigDirty()
            saveConfig()
            MP.SendChatMessage(pid, "GarageMP: persistence disabled for " .. resolvedName)
        elseif cmd == "clear" then
            savedVehicles[targetBid] = {}
            removeProxyVehiclesForOwner(targetBid)
            markOwnerDirty(targetBid)
            savePlayerVehicles(targetBid)
            MP.SendChatMessage(pid, "GarageMP: cleared saved vehicles for " .. resolvedName)
        elseif cmd == "addadmin" then
            adminSet[targetBid] = true
            markConfigDirty()
            saveConfig()
            MP.SendChatMessage(pid, "GarageMP: admin granted to " .. resolvedName)
        elseif cmd == "removeadmin" then
            adminSet[targetBid] = nil
            markConfigDirty()
            saveConfig()
            MP.SendChatMessage(pid, "GarageMP: admin removed from " .. resolvedName)
        elseif cmd == "proxyclear" then
            removeProxyVehiclesForOwner(targetBid)
            MP.SendChatMessage(pid, "GarageMP: explicit proxy removal triggered for " .. resolvedName)
        end
        log("Admin command", cmd, "by", tostring(name), "target", tostring(resolvedName))
        return 1
    end

    sendHelp(pid)
    return 1
end

local function guarded(handlerName, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        log("Handler error in", handlerName, result)
        return 0
    end
    return result
end

function GarageMP_onInit()
    return guarded("onInit", onInit)
end

function GarageMP_onShutdown()
    return guarded("onShutdown", onShutdown)
end

function GarageMP_onPlayerJoin(pid)
    return guarded("onPlayerJoin", onPlayerJoin, pid)
end

function GarageMP_onPlayerDisconnect(pid)
    return guarded("onPlayerDisconnect", onPlayerDisconnect, pid)
end

function GarageMP_onVehicleSpawn(pid, vid, data)
    return guarded("onVehicleSpawn", onVehicleSpawn, pid, vid, data)
end

function GarageMP_onVehicleEdited(pid, vid, data)
    return guarded("onVehicleEdited", onVehicleEdited, pid, vid, data)
end

function GarageMP_onVehicleDeleted(pid, vid)
    return guarded("onVehicleDeleted", onVehicleDeleted, pid, vid)
end

function GarageMP_onVehicleReset(pid, vid, data)
    return guarded("onVehicleReset", onVehicleReset, pid, vid, data)
end

function GarageMP_onChatMessage(pid, name, message)
    return guarded("onChatMessage", onChatMessage, pid, name, message)
end

function GarageMP_onSpawnComplete(senderPid, rawData)
    return guarded("GarageMP_SpawnComplete", onSpawnComplete, senderPid, rawData)
end

function GarageMP_onRemoveProxyComplete(senderPid, rawData)
    return guarded("GarageMP_RemoveProxyComplete", onRemoveProxyComplete, senderPid, rawData)
end

function GarageMP_onClientReady(senderPid, rawData)
    return guarded("GarageMP_ClientReady", onClientReady, senderPid, rawData)
end

function GarageMP_onRetryTick()
    return guarded("GarageMP_RetryTick", onRetryTick)
end

function GarageMP_onAutoSave()
    return guarded("GarageMP_AutoSave", onAutoSave)
end

MP.RegisterEvent("onInit", "GarageMP_onInit")
MP.RegisterEvent("onShutdown", "GarageMP_onShutdown")
MP.RegisterEvent("onPlayerJoin", "GarageMP_onPlayerJoin")
MP.RegisterEvent("onPlayerDisconnect", "GarageMP_onPlayerDisconnect")
MP.RegisterEvent("onVehicleSpawn", "GarageMP_onVehicleSpawn")
MP.RegisterEvent("onVehicleEdited", "GarageMP_onVehicleEdited")
MP.RegisterEvent("onVehicleDeleted", "GarageMP_onVehicleDeleted")
MP.RegisterEvent("onVehicleReset", "GarageMP_onVehicleReset")
MP.RegisterEvent("onChatMessage", "GarageMP_onChatMessage")
MP.RegisterEvent("GarageMP_SpawnComplete", "GarageMP_onSpawnComplete")
MP.RegisterEvent("GarageMP_RemoveProxyComplete", "GarageMP_onRemoveProxyComplete")
MP.RegisterEvent("GarageMP_ClientReady", "GarageMP_onClientReady")
MP.RegisterEvent(RETRY_EVENT, "GarageMP_onRetryTick")
