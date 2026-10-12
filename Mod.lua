-- Mod Menu v3.5 (Rayfield Gen 2)
-- Full conversion of mod-menu v2.4-fixed2: every feature carried over,
-- only the GUI layer changed - custom frames/categories replaced by a
-- Rayfield window (same library as the seed farm). Feature logic is the
-- v2.4 code verbatim wherever possible.
print("[ModMenu] v3.5 (Rayfield) loading...")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local Config = {
    Movement = {
        NoClip = false,
        WalkSpeed = 50,
        PhysicsSpeed = 34,
    },
    ESP = {
        Players = false,
        PlayerBases = false,
    },
    Hitbox = {
        Enabled = false,
        Size = 10,
    },
    Combat = {
        AttackCooldown = 0.05,
    },
    AutoCollect = {
        TickRate = 0.4,
    },
    UI = {
        ThemeIndex = 1,
    },
}

local featureToggles = {} -- Rayfield handles, filled by the GUI section (for Stop Everything)

local toggles = {
    speedBoost = false,
    infiniteJump = false,
    autoBatToggled = false,
    instantProximity = false,
    multiPrompt = false,
    speedBypassCFrame = false,
    antiAFK = false,
    autoCollect = false,
}

local State = {
    noClipParts = {},
    playerESPObjects = {},
    playerConnections = {},
    originalHoldDurations = {},
    savedPositions = { [1] = nil, [2] = nil, [3] = nil },
    selectedSlots = {},
    lastAttackTime = 0,
    currentTarget = "[Closest Player]",
    loops = {},
    connections = {},
}

local MONEY_TARGETS = {
    ["collectpart"] = true, ["cash"] = true, ["money"] = true, ["gold"] = true,
    ["coin"] = true, ["coins"] = true, ["diamond"] = true, ["diamonds"] = true,
    ["gem"] = true, ["gems"] = true, ["ruby"] = true, ["rubies"] = true,
    ["dollar"] = true, ["dollars"] = true, ["bill"] = true, ["bills"] = true,
    ["point"] = true, ["points"] = true, ["token"] = true, ["tokens"] = true,
    ["bag"] = true, ["briefcase"] = true, ["currency"] = true, ["loot"] = true,
    ["drop"] = true, ["crystal"] = true, ["crystals"] = true,
}

local physicsAttachment = nil
local physicsVelocityConstraint = nil

local function safeDisconnect(connection)
    if connection then
        pcall(function()
            if connection.Disconnect then
                connection:Disconnect()
            end
        end)
    end
end

local function safeDestroy(instance)
    if instance and instance.Destroy then
        pcall(function()
            instance:Destroy()
        end)
    end
end

-- Clean up a previous execution's loops/connections before starting fresh
local _envStore = (type(getgenv) == "function" and getgenv()) or _G
if _envStore.__ModMenuCleanup then
    pcall(_envStore.__ModMenuCleanup)
    _envStore.__ModMenuCleanup = nil
end

-- Settings that survive re-executes (slider values, teleport slots)
local function persistSetting(key, value)
    _envStore.__ModMenuSettings = _envStore.__ModMenuSettings or {}
    _envStore.__ModMenuSettings[key] = value
end

local function getPersistedSetting(key, fallback)
    if key == nil then return fallback end
    local s = _envStore.__ModMenuSettings
    if s and s[key] ~= nil then return s[key] end
    return fallback
end

-- restore saved teleport slots from the last run
do
    local slots = getPersistedSetting("teleportSlots", nil)
    if slots then
        for i = 1, 3 do
            if slots[i] then State.savedPositions[i] = slots[i] end
        end
    end
end

local function GetCharacter()
    return player and player.Character
end

local function GetRoot(character)
    if not character then return nil end
    return character:FindFirstChild("HumanoidRootPart")
end

local function GetHumanoid(character)
    if not character then return nil end
    return character:FindFirstChildOfClass("Humanoid")
end

local function applyNoClipPass()
    local character = GetCharacter()
    if not character then return end
    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("BasePart") then
            if State.noClipParts[object] == nil then
                State.noClipParts[object] = object.CanCollide
            end
            object.CanCollide = false
        end
    end
end

local function SetNoClip(enabled)
    Config.Movement.NoClip = enabled
    if enabled then
        applyNoClipPass() -- instant: no waiting for the first physics step
    else
        for part, originalState in pairs(State.noClipParts) do
            if part and part.Parent then
                part.CanCollide = originalState
            end
        end
        table.clear(State.noClipParts)
    end
end

local function SetupPhysicsObjects(root)
    if not root then return end

    if not physicsAttachment or physicsAttachment.Parent ~= root then
        if physicsAttachment then safeDestroy(physicsAttachment) end
        physicsAttachment = Instance.new("Attachment")
        physicsAttachment.Name = "SafeMoveAttachment"
        physicsAttachment.Parent = root
    end

    if not physicsVelocityConstraint or physicsVelocityConstraint.Parent ~= root then
        if physicsVelocityConstraint then safeDestroy(physicsVelocityConstraint) end
        physicsVelocityConstraint = Instance.new("LinearVelocity")
        physicsVelocityConstraint.Name = "SafeMoveVelocity"
        physicsVelocityConstraint.Attachment0 = physicsAttachment
        physicsVelocityConstraint.MaxForce = 0
        physicsVelocityConstraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        physicsVelocityConstraint.VectorVelocity = Vector3.new(0, 0, 0)
        physicsVelocityConstraint.Parent = root
    end
end

--============================================================================
-- MOVEMENT logic
--============================================================================
local speedValueWalk = getPersistedSetting("WalkSpeed", 50)
Config.Movement.PhysicsSpeed = getPersistedSetting("PhysicsSpeed", 34)

local function resetWalkSpeed()
    local hum = GetHumanoid(GetCharacter())
    if hum then
        hum.WalkSpeed = toggles.speedBoost and speedValueWalk or 16
    end
end

-- constant loop: while Speed Boost is on, the run speed is re-applied
-- every frame, so the game (state changes, tools, scripts) can never
-- reset WalkSpeed back down in between one-shot sets
State.connections.speedLoop = RunService.Heartbeat:Connect(function()
    if not toggles.speedBoost then return end
    local hum = GetHumanoid(GetCharacter())
    if hum and hum.WalkSpeed ~= speedValueWalk then
        hum.WalkSpeed = speedValueWalk
    end
end)

State.connections.infiniteJump = UserInputService.JumpRequest:Connect(function()
    if toggles.infiniteJump then
        local character = GetCharacter()
        local humanoid = GetHumanoid(character)
        if humanoid then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end)

local function setSpeedBypass(on)
    toggles.speedBypassCFrame = on
    if on then
        local root = GetRoot(GetCharacter())
        SetupPhysicsObjects(root)

        if State.connections.speedCFrame then
            State.connections.speedCFrame:Disconnect()
            State.connections.speedCFrame = nil
        end

        State.connections.speedCFrame = RunService.Heartbeat:Connect(function()
            -- the aimbot owns the shared LinearVelocity while active; don't fight it
            if toggles.autoBatToggled then return end

            local character = GetCharacter()
            local activeRoot = GetRoot(character)
            local humanoid = GetHumanoid(character)

            if activeRoot and humanoid and humanoid.MoveDirection.Magnitude > 0 then
                SetupPhysicsObjects(activeRoot)
                if physicsVelocityConstraint then
                    physicsVelocityConstraint.MaxForce = 999999
                    local yVel = activeRoot.AssemblyLinearVelocity.Y
                    physicsVelocityConstraint.VectorVelocity = Vector3.new(
                        humanoid.MoveDirection.X * Config.Movement.PhysicsSpeed,
                        yVel,
                        humanoid.MoveDirection.Z * Config.Movement.PhysicsSpeed
                    )
                end
            elseif activeRoot and physicsVelocityConstraint then
                physicsVelocityConstraint.MaxForce = 0
            end
        end)
    else
        if State.connections.speedCFrame then
            State.connections.speedCFrame:Disconnect()
            State.connections.speedCFrame = nil
        end
        if physicsVelocityConstraint then
            physicsVelocityConstraint.MaxForce = 0
        end
    end
end

State.connections.charAdded = player.CharacterAdded:Connect(function(character)
    table.clear(State.noClipParts) -- old character's parts are gone; fresh scan repopulates
    local root = character:WaitForChild("HumanoidRootPart", 5)
    local humanoid = character:WaitForChild("Humanoid", 5)
    if root then SetupPhysicsObjects(root) end
    if humanoid then
        humanoid.WalkSpeed = toggles.speedBoost and speedValueWalk or 16
    end
end)

-- constant loop: every physics frame, so nothing (state changes, game
-- scripts, freshly streamed parts) can re-enable a collision in between
State.connections.noClipLoop = RunService.Stepped:Connect(function()
    if not Config.Movement.NoClip then return end
    applyNoClipPass()
end)

--============================================================================
-- PLAYER ESP logic
--============================================================================
local function RemovePlayerESP(playerTarget)
    local data = State.playerESPObjects[playerTarget]
    if not data then return end
    State.playerESPObjects[playerTarget] = nil
    if data.Highlight then safeDestroy(data.Highlight) end
    if data.Billboard then safeDestroy(data.Billboard) end
end

local function CreatePlayerESP(playerTarget)
    if playerTarget == player then return end

    local character = playerTarget.Character
    if not character then return end

    RemovePlayerESP(playerTarget)

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local highlight = Instance.new("Highlight")
    highlight.Name = "CustomYellowHighlight"
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillColor = Color3.fromRGB(255, 255, 0)
    highlight.OutlineColor = Color3.fromRGB(255, 255, 0)
    highlight.FillTransparency = 0.25
    highlight.Parent = character

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "CustomOrangeBillboard"
    billboard.Size = UDim2.fromOffset(200, 40)
    billboard.StudsOffset = Vector3.new(0, 4.0, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = root
    billboard.Parent = character

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.fromRGB(255, 120, 0)
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.TextStrokeTransparency = 0.5
    label.Font = Enum.Font.GothamBold
    label.TextScaled = true
    label.Text = "👤 " .. playerTarget.Name
    label.Parent = billboard

    State.playerESPObjects[playerTarget] = {
        Highlight = highlight,
        Billboard = billboard,
        Label = label,
        Root = root,
        Character = character,
    }
end

local function StartESPUpdater()
    if State.loops.espUpdater then return end
    State.loops.espUpdater = task.spawn(function()
        while Config.ESP.Players do
            local myRoot = GetRoot(GetCharacter())
            for target, data in pairs(State.playerESPObjects) do
                if not target.Parent or not data.Character.Parent or not data.Root.Parent then
                    RemovePlayerESP(target)
                else
                    local txt
                    if myRoot then
                        local dist = math.floor((myRoot.Position - data.Root.Position).Magnitude)
                        txt = string.format("👤 %s [%d studs]", target.Name, dist)
                    else
                        txt = "👤 " .. target.Name
                    end
                    if data.Label.Text ~= txt then
                        data.Label.Text = txt
                    end
                end
            end
            task.wait(0.15)
        end
        State.loops.espUpdater = nil
    end)
end

local function AttachPlayerESP(playerTarget)
    if playerTarget == player then return end

    if State.playerConnections[playerTarget] then
        State.playerConnections[playerTarget]:Disconnect()
        State.playerConnections[playerTarget] = nil
    end

    if playerTarget.Character and Config.ESP.Players and not State.playerESPObjects[playerTarget] then
        task.spawn(CreatePlayerESP, playerTarget)
    end

    State.playerConnections[playerTarget] = playerTarget.CharacterAdded:Connect(function(character)
        if character:WaitForChild("HumanoidRootPart", 5) and Config.ESP.Players then
            CreatePlayerESP(playerTarget)
        end
    end)
end

for _, p in ipairs(Players:GetPlayers()) do
    AttachPlayerESP(p)
end

State.connections.playerAddedESP = Players.PlayerAdded:Connect(AttachPlayerESP)
State.connections.playerRemovingESP = Players.PlayerRemoving:Connect(function(target)
    RemovePlayerESP(target)
    if State.playerConnections[target] then
        State.playerConnections[target]:Disconnect()
        State.playerConnections[target] = nil
    end
end)

local function setPlayerESP(on)
    Config.ESP.Players = on
    if on then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= player and p.Character and not State.playerESPObjects[p] then
                task.spawn(CreatePlayerESP, p)
            end
        end
        StartESPUpdater()
    else
        for target in pairs(State.playerESPObjects) do
            RemovePlayerESP(target)
        end
    end
end

--============================================================================
-- BASE ESP logic (Base Name ESP engine - replaces the old blue
-- prompt markers. Occupied secret-room bases with the OWNER'S NAME,
-- event-driven: markers paint the frame content streams in. Markers
-- ride on each base's entrance at map level.)
--============================================================================
local baseEspOn = false
local baseMarkers = {} -- [room] = {bb, label, anchor, roomPart, ownerResolved}
local baseNameCache = {}
local baseIdChecked = {}
local baseDirty = {}
local baseRoomConns = {}
local baseLiveConns = {}
local basePg = player:WaitForChild("PlayerGui")

local function baseNameForUserId(id)
    local num = tonumber(id)
    if not num then return nil end
    if baseNameCache[num] then return baseNameCache[num] end
    local p = Players:GetPlayerByUserId(num)
    if p then
        baseNameCache[num] = p.Name
        return p.Name
    end
    local nm = nil
    pcall(function() nm = Players:GetNameByUserIdAsync(num) end)
    if nm then baseNameCache[num] = nm end
    return nm
end

local function baseOwnerText(nm)
    if nm == "NPC BASE" then return "ð  NPC BASE" end
    return "ð  " .. nm .. "'s base"
end

local function baseResolveOwner(room)
    -- the room's own name: Interior_<id>. Non-positive = NPC room;
    -- positive = the owner's UserId (live-proven).
    local nameId = room.Name:match("_(%-?%d+)$")
    if not nameId then return nil end
    if tonumber(nameId) <= 0 then return "NPC BASE" end
    local nm = baseNameForUserId(nameId)
    if not baseIdChecked[room] then
        baseIdChecked[room] = true
        print("[ModMenu] Base ESP: " .. room.Name .. " owner id " .. nameId .. " -> " .. (nm or "not resolved yet"))
    end
    return nm
end

local function baseRoomOccupied(room)
    local extras = 0
    for _, ch in ipairs(room:GetChildren()) do
        if not ch.Name:find("^Expand") then extras += 1 end
    end
    if extras > 0 then return true end
    for _, d in ipairs(room:GetDescendants()) do
        if d:IsA("ProximityPrompt") or d:IsA("SurfaceGui") or d:IsA("Humanoid") then
            return true
        end
    end
    return false
end

local function baseEntrancePart(room)
    local suffix = room.Name:match("_(%-?%d+)$")
    if not suffix then return nil end
    local sr = Workspace:FindFirstChild("SecretRooms")
    local ent = sr and sr:FindFirstChild("Entrance_" .. suffix)
    if not ent then return nil end
    return ent.PrimaryPart or ent:FindFirstChildWhichIsA("BasePart", true)
end

local function baseMarkRoom(room, pivot)
    if baseMarkers[room] then return end
    local owner = baseResolveOwner(room)
    local part = room:FindFirstChildWhichIsA("BasePart", true)
    local anchor = nil
    if not part then
        anchor = Instance.new("Part")
        anchor.Name = "BaseESPAnchor"
        anchor.Size = Vector3.new(1, 1, 1)
        anchor.Transparency = 1
        anchor.CanCollide = false
        anchor.CanQuery = false
        anchor.Anchored = true
        anchor.Position = pivot
        anchor.Parent = Workspace
        part = anchor
    end
    local bb = Instance.new("BillboardGui")
    bb.Name = "BaseMark"
    bb.Size = UDim2.new(0, 240, 0, 40)
    bb.StudsOffset = Vector3.new(0, 3, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = 100000
    bb.Adornee = part
    local tl = Instance.new("TextLabel")
    tl.Size = UDim2.new(1, 0, 1, 0)
    tl.BackgroundColor3 = Color3.fromRGB(200, 120, 20)
    tl.BackgroundTransparency = 0.2
    tl.TextColor3 = Color3.new(1, 1, 1)
    tl.Font = Enum.Font.GothamBold
    tl.TextSize = 13
    tl.Text = owner and baseOwnerText(owner) or "ð  OCCUPIED"
    tl.Parent = bb
    Instance.new("UICorner", tl).CornerRadius = UDim.new(0, 6)
    bb.Parent = basePg
    baseMarkers[room] = { bb = bb, label = tl, anchor = anchor, roomPart = part, ownerResolved = owner ~= nil }
end

local function baseUnmarkRoom(room)
    local mk = baseMarkers[room]
    if mk then
        pcall(function() mk.bb:Destroy() end)
        if mk.anchor then pcall(function() mk.anchor:Destroy() end) end
        baseMarkers[room] = nil
    end
end

local function baseClearMarkers()
    for room in pairs(baseMarkers) do baseUnmarkRoom(room) end
end

local function baseRefreshOwner(room)
    local mk = baseMarkers[room]
    if not mk or mk.ownerResolved then return end
    local nm = baseResolveOwner(room)
    if nm then
        mk.ownerResolved = true
        mk.label.Text = baseOwnerText(nm)
    end
end

local function baseRefreshPlacement(room)
    local mk = baseMarkers[room]
    if not mk then return end
    local entPart = baseEntrancePart(room)
    local target = entPart or mk.roomPart or mk.anchor
    if target and mk.bb.Adornee ~= target then
        mk.bb.Adornee = target
    end
end

local function baseScanOnce()
    local rooms = Workspace:FindFirstChild("SecretRooms")
    if not rooms then return end
    for _, room in ipairs(rooms:GetChildren()) do
        if room.Name:sub(1, 9) ~= "Entrance_" then
            if baseRoomOccupied(room) then
                local ok, piv = pcall(function() return room:GetPivot().Position end)
                if ok then
                    baseMarkRoom(room, piv)
                    baseRefreshOwner(room)
                    baseRefreshPlacement(room)
                end
            else
                baseUnmarkRoom(room)
            end
        end
    end
    for room in pairs(baseMarkers) do
        if not room.Parent then baseUnmarkRoom(room) end
    end
end

-- streaming sweep points: housing map + the Y=10000 room grid
local basePoints = {}
for _, gx in ipairs({ -300, -100, 100, 300 }) do
    for _, gz in ipairs({ -100, 100, 300, 500, 700 }) do
        basePoints[#basePoints + 1] = Vector3.new(gx, 40, gz)
    end
end
for _, gx in ipairs({ -600, -300, 0, 300, 600 }) do
    for _, gz in ipairs({ -600, -300, 0, 300, 600 }) do
        basePoints[#basePoints + 1] = Vector3.new(gx, 10000, gz)
    end
end

local baseEspGen = 0
local function baseSweepLoop(gen)
    while baseEspOn and gen == baseEspGen do
        for i = 1, #basePoints do
            local point = basePoints[i]
            task.spawn(function()
                pcall(function()
                    player:RequestStreamAroundAsync(point, 2)
                end)
            end)
        end
        task.wait(4)
    end
end

-- zero-second refresh: events queue rooms, Heartbeat paints them
local function baseQueueRoom(room)
    if room then baseDirty[room] = true end
end

local function baseWatchRoom(room)
    if baseRoomConns[room] then return end
    baseRoomConns[room] = room.DescendantAdded:Connect(function()
        baseQueueRoom(room)
    end)
end

local function baseUnwatchRoom(room)
    local c = baseRoomConns[room]
    if c then c:Disconnect() baseRoomConns[room] = nil end
end

local function baseProcessRoom(room)
    if not room.Parent then
        baseUnwatchRoom(room)
        baseUnmarkRoom(room)
        return
    end
    baseWatchRoom(room)
    if baseRoomOccupied(room) then
        local ok, piv = pcall(function() return room:GetPivot().Position end)
        if ok then
            baseMarkRoom(room, piv)
            baseRefreshOwner(room)
            baseRefreshPlacement(room)
        end
    else
        baseUnmarkRoom(room)
    end
end

local function baseProcessQueue()
    if not baseEspOn then return end
    if next(baseDirty) == nil then return end
    local batch = baseDirty
    baseDirty = {}
    for room in pairs(batch) do
        pcall(baseProcessRoom, room)
    end
end

local function baseBindEvents()
    local rooms = Workspace:FindFirstChild("SecretRooms")
    if not rooms then
        baseLiveConns[#baseLiveConns + 1] = Workspace.ChildAdded:Connect(function(ch)
            if ch.Name == "SecretRooms" then baseBindEvents() end
        end)
        return
    end
    baseLiveConns[#baseLiveConns + 1] = rooms.ChildAdded:Connect(function(ch)
        if ch.Name:sub(1, 9) == "Entrance_" then
            baseQueueRoom(rooms:FindFirstChild("Interior_" .. ch.Name:sub(10)))
        else
            baseQueueRoom(ch)
        end
    end)
    baseLiveConns[#baseLiveConns + 1] = rooms.ChildRemoved:Connect(function(ch)
        if ch.Name:sub(1, 9) == "Entrance_" then
            baseQueueRoom(rooms:FindFirstChild("Interior_" .. ch.Name:sub(10)))
        else
            baseUnwatchRoom(ch)
            baseUnmarkRoom(ch)
        end
    end)
    baseLiveConns[#baseLiveConns + 1] = RunService.Heartbeat:Connect(baseProcessQueue)
    for _, ch in ipairs(rooms:GetChildren()) do
        if ch.Name:sub(1, 9) ~= "Entrance_" then baseQueueRoom(ch) end
    end
end

local function baseUnbindEvents()
    for _, c in ipairs(baseLiveConns) do pcall(function() c:Disconnect() end) end
    baseLiveConns = {}
    for room in pairs(baseRoomConns) do baseUnwatchRoom(room) end
    baseDirty = {}
end

local function StartPlayerBaseTracking()
    for _, d in ipairs(basePg:GetChildren()) do
        if d.Name == "BaseMark" then d:Destroy() end
    end
    for _, d in ipairs(Workspace:GetChildren()) do
        if d.Name == "BaseESPAnchor" then d:Destroy() end
    end
    baseEspGen += 1
    local gen = baseEspGen
    baseEspOn = true
    pcall(baseScanOnce)
    baseBindEvents()
    task.spawn(baseSweepLoop, gen)
    task.spawn(function()
        while baseEspOn and gen == baseEspGen do
            task.wait(30)
            if baseEspOn and gen == baseEspGen then pcall(baseScanOnce) end
        end
    end)
    return true
end

local function StopPlayerBaseTracking()
    baseEspGen += 1
    baseEspOn = false
    baseUnbindEvents()
    baseClearMarkers()
end

local baseEspToggle -- forward: set by the GUI section so failures can reset it
local function setBaseESP(on)
    Config.ESP.PlayerBases = on
    if on then
        if not StartPlayerBaseTracking() then
            Config.ESP.PlayerBases = false
            warn("[ModMenu] Base ESP unavailable on this executor")
            if baseEspToggle then pcall(function() baseEspToggle:Set(false) end) end
        end
    else
        StopPlayerBaseTracking()
    end
end

--============================================================================
-- HITBOX logic
--============================================================================
local function setPlayerHitbox(targetPlayer, expanded)
    if targetPlayer == player then return end
    local character = targetPlayer.Character
    if not character then return end
    local root = character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        if expanded then
            root.Size = Vector3.new(Config.Hitbox.Size, Config.Hitbox.Size, Config.Hitbox.Size)
            root.Transparency = 0.65
            root.CanCollide = false
        else
            root.Size = Vector3.new(2, 2, 1)
            root.Transparency = 1
            root.CanCollide = true
        end
    end
end

local function applyHitboxToPlayers(expanded)
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        setPlayerHitbox(otherPlayer, expanded)
    end
end

local hitboxRespawnConns = {}
local function hookHitboxRespawn(targetPlayer)
    if targetPlayer == player then return end
    safeDisconnect(hitboxRespawnConns[targetPlayer])
    hitboxRespawnConns[targetPlayer] = targetPlayer.CharacterAdded:Connect(function()
        if Config.Hitbox.Enabled then
            task.wait(1)
            setPlayerHitbox(targetPlayer, true)
        end
    end)
end
for _, p in ipairs(Players:GetPlayers()) do hookHitboxRespawn(p) end
State.connections.hitboxPlayerAdded = Players.PlayerAdded:Connect(function(p)
    hookHitboxRespawn(p)
    if Config.Hitbox.Enabled then
        task.wait(1)
        setPlayerHitbox(p, true)
    end
end)
State.connections.hitboxPlayerRemoving = Players.PlayerRemoving:Connect(function(p)
    safeDisconnect(hitboxRespawnConns[p])
    hitboxRespawnConns[p] = nil
end)

local function setHitbox(on)
    Config.Hitbox.Enabled = on
    applyHitboxToPlayers(on)
end

--============================================================================
-- BAT AIMBOT logic
--============================================================================
local aimbot = {
    bat = nil,
    batRemote = nil,
    target = nil,
    lastTargetScan = 0,
    lastEquipTry = 0,
    lastPos = nil,
    stuckSince = 0,
}

local AIMBOT_TARGET_SCAN = 0.25
local AIMBOT_MAX_CHASE = 1500
local AIMBOT_FACE_DEGREES = 3
local AIMBOT_STICK_DIST = 2.5
local AIMBOT_SWING_DOT = 0.7

local function aimbotIsBat(tool)
    if not tool or not tool:IsA("Tool") then return false end
    local lowerName = string.lower(tool.Name)
    return lowerName:find("bat") or lowerName:find("slap")
        or lowerName:find("glove") or lowerName:find("weapon")
end

local function findBat()
    local character = GetCharacter()
    local b = aimbot.bat
    if b and aimbotIsBat(b) then
        local bp = player:FindFirstChild("Backpack")
        if b.Parent == character or b.Parent == bp then
            return b
        end
    end
    aimbot.bat, aimbot.batRemote = nil, nil
    if not character then return nil end

    local function scan(container)
        if not container then return nil end
        for _, tool in ipairs(container:GetChildren()) do
            if aimbotIsBat(tool) then return tool end
        end
        return nil
    end

    local found = scan(character) or scan(player:FindFirstChild("Backpack"))
    if found then
        aimbot.bat = found
        aimbot.batRemote = found:FindFirstChildOfClass("RemoteEvent")
    end
    return found
end

local function aimbotValidateTarget(t)
    return t and t.Player.Parent and t.Root.Parent
        and t.Humanoid.Parent and t.Humanoid.Health > 0
end

local function getAimbotTarget(myRoot)
    local now = os.clock()

    if State.currentTarget ~= "[Closest Player]" then
        local targetPlayer = Players:FindFirstChild(State.currentTarget)
        if targetPlayer and targetPlayer.Character then
            local targetRoot = GetRoot(targetPlayer.Character)
            local humanoid = GetHumanoid(targetPlayer.Character)
            if targetRoot and humanoid and humanoid.Health > 0 then
                return targetRoot
            end
        end
        return nil
    end

    local c = aimbot.target
    if aimbotValidateTarget(c) then
        if now - aimbot.lastTargetScan < AIMBOT_TARGET_SCAN then
            return c.Root
        end
    else
        aimbot.target = nil
    end

    aimbot.lastTargetScan = now
    local best, bestDist, bestHum, bestPlayer = nil, AIMBOT_MAX_CHASE, nil, nil
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= player and otherPlayer.Character then
            local targetRoot = GetRoot(otherPlayer.Character)
            local humanoid = GetHumanoid(otherPlayer.Character)
            if targetRoot and humanoid and humanoid.Health > 0 then
                local dist = (targetRoot.Position - myRoot.Position).Magnitude
                if dist < bestDist then
                    best, bestDist = targetRoot, dist
                    bestHum, bestPlayer = humanoid, otherPlayer
                end
            end
        end
    end

    if best then
        aimbot.target = { Player = bestPlayer, Root = best, Humanoid = bestHum }
    end
    return best
end

local function aimbotFace(root, goalPos)
    local myPos = root.Position
    local dx, dz = goalPos.X - myPos.X, goalPos.Z - myPos.Z
    if dx * dx + dz * dz < 0.01 then return end
    local desired = Vector3.new(dx, 0, dz).Unit
    local look = root.CFrame.LookVector
    local current = Vector3.new(look.X, 0, look.Z)
    if current.Magnitude < 0.01 then return end
    local angle = math.acos(math.clamp(current.Unit:Dot(desired), -1, 1))
    if angle > math.rad(AIMBOT_FACE_DEGREES) then
        root.CFrame = CFrame.lookAt(myPos, Vector3.new(goalPos.X, myPos.Y, goalPos.Z))
    end
end

local function startBatAimbot()
    if State.connections.aimbot then
        State.connections.aimbot:Disconnect()
        State.connections.aimbot = nil
    end

    aimbot.bat, aimbot.batRemote, aimbot.target = nil, nil, nil
    aimbot.lastTargetScan, aimbot.lastEquipTry = 0, 0
    aimbot.lastPos, aimbot.stuckSince = nil, 0

    local character = GetCharacter()
    local root = GetRoot(character)
    SetupPhysicsObjects(root)

    local humanoid = GetHumanoid(character)
    if humanoid then
        humanoid.AutoRotate = false
    end

    State.connections.aimbot = RunService.RenderStepped:Connect(function()
        if not toggles.autoBatToggled then return end

        local activeCharacter = GetCharacter()
        local activeRoot = GetRoot(activeCharacter)
        local activeHumanoid = GetHumanoid(activeCharacter)
        if not activeRoot or not activeHumanoid then return end
        activeHumanoid.AutoRotate = false

        SetupPhysicsObjects(activeRoot)

        local now = os.clock()

        if not activeCharacter:FindFirstChildOfClass("Tool") then
            if now - aimbot.lastEquipTry > 0.5 then
                aimbot.lastEquipTry = now
                local bat = findBat()
                if bat and bat.Parent ~= activeCharacter then
                    pcall(activeHumanoid.EquipTool, activeHumanoid, bat)
                end
            end
        end

        local target = getAimbotTarget(activeRoot)
        if not target or not target.Parent then
            if physicsVelocityConstraint then
                physicsVelocityConstraint.MaxForce = 0
            end
            aimbot.lastPos, aimbot.stuckSince = nil, 0
            return
        end

        local targetVelocity = Vector3.new(0, 0, 0)
        pcall(function()
            targetVelocity = target.AssemblyLinearVelocity
        end)

        local myPosition = activeRoot.Position
        local targetPosition = target.Position
        local distance = (myPosition - targetPosition).Magnitude

        local pingCompensation = math.clamp(distance / 55, 0.03, 0.18)
        local predicted = targetPosition + (targetVelocity * pingCompensation)

        aimbotFace(activeRoot, predicted)

        if distance > 8 then
            local direction = Vector3.new(predicted.X - myPosition.X, 0, predicted.Z - myPosition.Z)
            if direction.Magnitude > 0.01 then
                direction = direction.Unit
                local speedMultiplier = activeHumanoid.WalkSpeed > 16 and activeHumanoid.WalkSpeed or 32
                if physicsVelocityConstraint then
                    physicsVelocityConstraint.MaxForce = 999999
                    physicsVelocityConstraint.VectorVelocity = Vector3.new(
                        direction.X * (speedMultiplier * 2),
                        activeRoot.AssemblyLinearVelocity.Y,
                        direction.Z * (speedMultiplier * 2)
                    )
                end
            end

            if not aimbot.lastPos or (myPosition - aimbot.lastPos).Magnitude > 1.5 then
                aimbot.lastPos = myPosition
                aimbot.stuckSince = now
            elseif now - aimbot.stuckSince > 1.5 then
                aimbot.stuckSince = now
                pcall(function()
                    activeHumanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)
            end
        else
            local combatOffset = target.CFrame.LookVector * -1.5
            local ideal = Vector3.new(
                targetPosition.X + combatOffset.X,
                myPosition.Y,
                targetPosition.Z + combatOffset.Z
            )
            if (myPosition - ideal).Magnitude > AIMBOT_STICK_DIST then
                activeRoot.CFrame = CFrame.new(ideal, Vector3.new(targetPosition.X, myPosition.Y, targetPosition.Z))
            end
            if physicsVelocityConstraint then
                physicsVelocityConstraint.MaxForce = 999999
                physicsVelocityConstraint.VectorVelocity = Vector3.new(0, activeRoot.AssemblyLinearVelocity.Y, 0)
            end
            aimbot.lastPos, aimbot.stuckSince = nil, 0
        end

        if distance < 11 and (now - State.lastAttackTime) >= Config.Combat.AttackCooldown then
            local tool = activeCharacter:FindFirstChildOfClass("Tool")
            if tool and tool == aimbot.bat then
                local look = activeRoot.CFrame.LookVector
                local toTarget = targetPosition - myPosition
                local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
                if flat.Magnitude > 0.1 then
                    local flatLook = Vector3.new(look.X, 0, look.Z)
                    if flatLook.Magnitude > 0.01
                        and flatLook.Unit:Dot(flat.Unit) > AIMBOT_SWING_DOT then
                        State.lastAttackTime = now
                        pcall(function()
                            if aimbot.batRemote then aimbot.batRemote:FireServer() end
                            tool:Activate()
                        end)
                    end
                end
            end
        end
    end)
end

local function stopBatAimbot()
    if State.connections.aimbot then
        State.connections.aimbot:Disconnect()
        State.connections.aimbot = nil
    end

    if physicsVelocityConstraint then
        physicsVelocityConstraint.MaxForce = 0
    end

    aimbot.bat, aimbot.batRemote, aimbot.target = nil, nil, nil

    local humanoid = GetHumanoid(GetCharacter())
    if humanoid then
        humanoid.AutoRotate = true
    end
end

-- Aimbot floating quick-toggle bubble (own ScreenGui; Rayfield has the menu)
local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
local oldFloat = playerGui:FindFirstChild("ModMenuFloat")
if oldFloat then oldFloat:Destroy() end
local floatGui = Instance.new("ScreenGui")
floatGui.Name = "ModMenuFloat"
floatGui.ResetOnSpawn = false
floatGui.Parent = playerGui

local aimbotFloatVisible = false

local aimFloatBtn = Instance.new("TextButton")
aimFloatBtn.Name = "AimbotFloatToggle"
aimFloatBtn.Size = UDim2.new(0, 84, 0, 84)
aimFloatBtn.Position = UDim2.new(1, -110, 0.5, -42)
aimFloatBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
aimFloatBtn.BackgroundTransparency = 0.2
aimFloatBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
aimFloatBtn.Font = Enum.Font.SourceSansBold
aimFloatBtn.TextSize = 15
aimFloatBtn.Text = "AIM\nOFF"
aimFloatBtn.Visible = false
aimFloatBtn.Parent = floatGui

local aimFloatCorner = Instance.new("UICorner")
aimFloatCorner.CornerRadius = UDim.new(1, 0)
aimFloatCorner.Parent = aimFloatBtn

local aimFloatStroke = Instance.new("UIStroke")
aimFloatStroke.Thickness = 2
aimFloatStroke.Color = Color3.fromRGB(255, 75, 75)
aimFloatStroke.Parent = aimFloatBtn

local function refreshAimbotUI()
    local on = toggles.autoBatToggled
    aimFloatBtn.Text = on and "AIM\nON" or "AIM\nOFF"
    aimFloatStroke.Color = on and Color3.fromRGB(75, 255, 75) or Color3.fromRGB(255, 75, 75)
    aimFloatBtn.Visible = aimbotFloatVisible
end

local function setAimbotEnabled(on)
    if toggles.autoBatToggled == on then
        refreshAimbotUI()
        return
    end
    toggles.autoBatToggled = on
    local ok, err = pcall(function()
        if on then
            startBatAimbot()
        else
            stopBatAimbot()
        end
    end)
    if not ok then
        warn("[ModMenu] Aimbot error: " .. tostring(err))
    end
    print("[ModMenu] Aimbot " .. (on and "ENABLED" or "DISABLED")
        .. " | float bubble visible: " .. tostring(aimbotFloatVisible))
    refreshAimbotUI()
end

do
    local dragging = false
    local moved = false
    local dragStart = Vector2.new()
    local startPos = UDim2.new()
    local endConn = nil

    aimFloatBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = aimFloatBtn.Position
            if endConn then endConn:Disconnect() end
            endConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if not moved then
                        setAimbotEnabled(not toggles.autoBatToggled)
                    end
                end
            end)
        end
    end)

    table.insert(State.connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            if delta.Magnitude > 10 then
                moved = true
            end
            if moved then
                aimFloatBtn.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end
    end))
end

--============================================================================
-- MISC logic: instant proximity, radius multi-pickup, anti-AFK, auto-collect
--============================================================================
local function applyPromptFix(prompt)
    if prompt:IsA("ProximityPrompt") and not State.originalHoldDurations[prompt] then
        State.originalHoldDurations[prompt] = prompt.HoldDuration
        if toggles.instantProximity then
            prompt.HoldDuration = 0
        end
    end
end

local function setInstantProximity(on)
    toggles.instantProximity = on
    if on then
        for _, prompt in ipairs(Workspace:GetDescendants()) do
            applyPromptFix(prompt)
            if State.originalHoldDurations[prompt] then
                prompt.HoldDuration = 0
            end
        end

        if not State.connections.instantPrompt then
            State.connections.instantPrompt = Workspace.DescendantAdded:Connect(function(descendant)
                if descendant:IsA("ProximityPrompt") then
                    applyPromptFix(descendant)
                end
            end)
        end
    else
        if State.connections.instantPrompt then
            State.connections.instantPrompt:Disconnect()
            State.connections.instantPrompt = nil
        end

        for prompt, duration in pairs(State.originalHoldDurations) do
            if prompt and prompt.Parent then
                prompt.HoldDuration = duration
            end
        end
        table.clear(State.originalHoldDurations)
    end
end

local promptSweepRadius = 25
local cachedPrompts = {}

local function rebuildPromptCache()
    table.clear(cachedPrompts)
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            cachedPrompts[d] = true
        end
    end
end

local function setMultiPickup(on)
    toggles.multiPrompt = on
    if on then
        rebuildPromptCache()

        safeDisconnect(State.connections.multiPromptAdded)
        safeDisconnect(State.connections.multiPromptRemoving)
        State.connections.multiPromptAdded = Workspace.DescendantAdded:Connect(function(d)
            if d:IsA("ProximityPrompt") then cachedPrompts[d] = true end
        end)
        State.connections.multiPromptRemoving = Workspace.DescendantRemoving:Connect(function(d)
            cachedPrompts[d] = nil
        end)

        State.loops.multiPrompt = task.spawn(function()
            while toggles.multiPrompt do
                local rootPart = GetRoot(GetCharacter())
                if rootPart then
                    for prompt in pairs(cachedPrompts) do
                        if prompt.Parent and prompt.Parent:IsA("BasePart") then
                            local distance = (rootPart.Position - prompt.Parent.Position).Magnitude
                            if distance <= promptSweepRadius then
                                task.spawn(function()
                                    pcall(function()
                                        prompt:InputHoldBegan()
                                        task.wait()
                                        prompt:InputHoldEnded()
                                    end)
                                end)
                            end
                        else
                            cachedPrompts[prompt] = nil
                        end
                    end
                end
                task.wait(0.2)
            end
        end)
    else
        if State.loops.multiPrompt then
            task.cancel(State.loops.multiPrompt)
            State.loops.multiPrompt = nil
        end
        safeDisconnect(State.connections.multiPromptAdded)
        State.connections.multiPromptAdded = nil
        safeDisconnect(State.connections.multiPromptRemoving)
        State.connections.multiPromptRemoving = nil
        table.clear(cachedPrompts)
    end
end

State.connections.afk = player.Idled:Connect(function()
    if toggles.antiAFK then
        local virtualUser = game:GetService("VirtualUser")
        virtualUser:CaptureController()
        virtualUser:ClickButton2(Vector2.new(0, 0))
    end
end)

local collectCache = {}
local COLLECT_COOLDOWN = 1.5
local COLLECT_PER_TICK = 12
local FALLBACK_TP_RADIUS = 50

local function handlePickup(part)
    local character = GetCharacter()
    local root = GetRoot(character)
    if not (root and part and part.Parent and part:IsA("BasePart")) then return end
    if firetouchinterest then
        pcall(function()
            firetouchinterest(root, part, 0)
            task.wait(0.01)
            if part.Parent then
                firetouchinterest(root, part, 1)
            end
        end)
    elseif (root.Position - part.Position).Magnitude <= FALLBACK_TP_RADIUS then
        local originalPosition = root.CFrame
        pcall(function()
            root.CFrame = part.CFrame
            task.wait(0.1)
        end)
        if root.Parent then
            root.CFrame = originalPosition
        end
    end
end

local function isMoneyPart(target)
    if not target or not target:IsA("BasePart") then return false end
    if target.Transparency >= 1 then return false end

    local nameLower = string.lower(target.Name)
    return MONEY_TARGETS[nameLower] or string.find(nameLower, "cash") or string.find(nameLower, "money") or string.find(nameLower, "coin")
end

local function getSortedMoneyParts(rootPart)
    local list = {}
    for part in pairs(collectCache) do
        if part.Parent and part:IsA("BasePart") then
            table.insert(list, { part = part, dist = (rootPart.Position - part.Position).Magnitude })
        else
            collectCache[part] = nil
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

local function setAutoCollect(on)
    toggles.autoCollect = on
    if on then
        table.clear(collectCache)
        for _, d in ipairs(Workspace:GetDescendants()) do
            if isMoneyPart(d) then collectCache[d] = 0 end
        end
        safeDisconnect(State.connections.collectAdded)
        safeDisconnect(State.connections.collectRemoving)
        State.connections.collectAdded = Workspace.DescendantAdded:Connect(function(d)
            if isMoneyPart(d) then collectCache[d] = 0 end
        end)
        State.connections.collectRemoving = Workspace.DescendantRemoving:Connect(function(d)
            collectCache[d] = nil
        end)

        State.loops.autoCollect = task.spawn(function()
            while toggles.autoCollect do
                local rootPart = GetRoot(GetCharacter())
                if rootPart then
                    local now = os.clock()
                    local picked = 0
                    for _, entry in ipairs(getSortedMoneyParts(rootPart)) do
                        if not toggles.autoCollect then break end
                        if picked >= COLLECT_PER_TICK then break end
                        local part = entry.part
                        if (now - (collectCache[part] or 0)) >= COLLECT_COOLDOWN then
                            collectCache[part] = now
                            picked += 1
                            task.spawn(handlePickup, part)
                        end
                    end
                end

                task.wait(Config.AutoCollect.TickRate)
            end
        end)
    else
        if State.loops.autoCollect then
            task.cancel(State.loops.autoCollect)
            State.loops.autoCollect = nil
        end
        safeDisconnect(State.connections.collectAdded)
        State.connections.collectAdded = nil
        safeDisconnect(State.connections.collectRemoving)
        State.connections.collectRemoving = nil
        table.clear(collectCache)
    end
end

--============================================================================
-- AUTOMATION logic: auto-upgrade brainrot slots
--============================================================================
local upgradeRemote = ReplicatedStorage:FindFirstChild("Gasifier")
if upgradeRemote then
    upgradeRemote = upgradeRemote:FindFirstChild("Services")
    if upgradeRemote then
        upgradeRemote = upgradeRemote:FindFirstChild("PlotService")
        if upgradeRemote then
            upgradeRemote = upgradeRemote:FindFirstChild("RF")
            if upgradeRemote then
                upgradeRemote = upgradeRemote:FindFirstChild("UpgradeBrainrot")
            end
        end
    end
end

local TOTAL_SLOTS = 30
local COOLDOWN_RATE = 0.15

for i = 1, TOTAL_SLOTS do
    State.selectedSlots[i] = true
end

local isAutoUpgrading = false
local autoUpgradeToggle -- forward: set by the GUI section

local lastUpgradeWarn, lastUpgradeWarnAt = nil, 0
local function warnUpgradeThrottled(msg)
    local now = os.clock()
    if msg == lastUpgradeWarn and now - lastUpgradeWarnAt < 5 then return end
    lastUpgradeWarn, lastUpgradeWarnAt = msg, now
    warn(msg)
end

local function setAutoUpgrade(on)
    if not upgradeRemote then
        warn("[ModMenu] UpgradeBrainrot remote not found.")
        if autoUpgradeToggle then pcall(function() autoUpgradeToggle:Set(false) end) end
        return
    end
    isAutoUpgrading = on
    if on then
        task.spawn(function()
            while isAutoUpgrading do
                local fundsExhausted = false
                local attemptedAny = false

                for slotIndex = 1, TOTAL_SLOTS do
                    if not isAutoUpgrading then break end
                    if State.selectedSlots[slotIndex] then
                        attemptedAny = true
                        local success, response = pcall(function()
                            return upgradeRemote:InvokeServer(slotIndex)
                        end)

                        local responseStr = tostring(response or "")
                        local lowerResponse = string.lower(responseStr)
                        if string.find(lowerResponse, "money") or string.find(lowerResponse, "cash") or string.find(lowerResponse, "fund") or string.find(lowerResponse, "afford") then
                            fundsExhausted = true
                            warnUpgradeThrottled("[ModMenu] Auto-Upgrade: out of funds at Slot #" .. slotIndex)
                            break
                        end
                        if not success or response == false then
                            warnUpgradeThrottled("[ModMenu] Auto-Upgrade Slot #" .. slotIndex .. " failed | Response: " .. responseStr)
                        end
                        -- success (including a nil return) is silent now: no console flood

                        task.wait(COOLDOWN_RATE)
                    end
                end

                if not attemptedAny and isAutoUpgrading then
                    warn("No targets set!")
                    isAutoUpgrading = false
                    if autoUpgradeToggle then pcall(function() autoUpgradeToggle:Set(false) end) end
                    break
                end

                if not isAutoUpgrading then break end

                if fundsExhausted then
                    task.wait(5)
                else
                    task.wait(1)
                end
            end
        end)
    end
end

-- Stop Everything (button): turn every FEATURE off through its own
-- switch so the menu's permanent infrastructure (respawn hooks,
-- jump/noclip listeners, join/leave hooks) keeps working afterwards.
-- The full cleanup() below is only for re-execute teardown.
local function stopAllFeatures()
    for _, t in pairs(featureToggles) do
        pcall(function() t:Set(false) end)
    end
    -- backstop direct offs (idempotent) in case a handle is missing
    toggles.speedBoost = false
    toggles.infiniteJump = false
    toggles.autoBatToggled = false
    toggles.instantProximity = false
    toggles.multiPrompt = false
    toggles.speedBypassCFrame = false
    toggles.antiAFK = false
    toggles.autoCollect = false
    isAutoUpgrading = false
    aimbotFloatVisible = false
    refreshAimbotUI()
    SetNoClip(false)
    setSpeedBypass(false)
    setPlayerESP(false)
    setBaseESP(false)
    setHitbox(false)
    stopBatAimbot()
    setInstantProximity(false)
    setMultiPickup(false)
    setAutoCollect(false)
    resetWalkSpeed()
end

--============================================================================
-- CLEANUP
--============================================================================
local function cleanup()
    stopAllFeatures()
    toggles.speedBoost = false
    toggles.infiniteJump = false
    toggles.autoBatToggled = false
    toggles.instantProximity = false
    toggles.multiPrompt = false
    toggles.speedBypassCFrame = false
    toggles.antiAFK = false
    toggles.autoCollect = false
    isAutoUpgrading = false
    aimbotFloatVisible = false
    if aimFloatBtn then
        aimFloatBtn.Visible = false
    end

    SetNoClip(false)
    Config.ESP.Players = false
    Config.ESP.PlayerBases = false
    Config.Hitbox.Enabled = false

    for _, connection in pairs(State.connections) do
        safeDisconnect(connection)
    end
    table.clear(State.connections)

    for _, conn in pairs(hitboxRespawnConns) do
        safeDisconnect(conn)
    end
    table.clear(hitboxRespawnConns)

    stopBatAimbot()
    StopPlayerBaseTracking()

    if State.loops.autoCollect then
        task.cancel(State.loops.autoCollect)
        State.loops.autoCollect = nil
    end

    if State.loops.multiPrompt then
        task.cancel(State.loops.multiPrompt)
        State.loops.multiPrompt = nil
    end

    if State.loops.espUpdater then
        task.cancel(State.loops.espUpdater)
        State.loops.espUpdater = nil
    end

    if physicsVelocityConstraint then
        safeDestroy(physicsVelocityConstraint)
    end

    if physicsAttachment then
        safeDestroy(physicsAttachment)
    end

    local humanoid = GetHumanoid(GetCharacter())
    if humanoid then
        humanoid.PlatformStand = false
        humanoid.WalkSpeed = 16
    end

    for playerTarget in pairs(State.playerESPObjects) do
        RemovePlayerESP(playerTarget)
    end

    for _, connection in pairs(State.playerConnections) do
        safeDisconnect(connection)
    end
    table.clear(State.playerConnections)

    for prompt, duration in pairs(State.originalHoldDurations) do
        if prompt and prompt.Parent then
            prompt.HoldDuration = duration
        end
    end
    table.clear(State.originalHoldDurations)
end

--============================================================================
-- RAYFIELD GUI (Gen 2) - everything above is feature logic, this is the skin
--============================================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Mod Menu v3.5",
    LoadingTitle = "Mod Menu v3.5",
    LoadingSubtitle = "Rayfield edition",
    ShowText = "Mod Menu",
    Theme = "Default",
    ToggleUIKeybind = "K",
    DisableRayfieldPrompts = true,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "ModMenu",
        FileName = "ModMenuConfig",
    },
    KeySystem = false,
})

local MovementTab = Window:CreateTab("Movement", nil)
local VisualsTab = Window:CreateTab("Visuals", nil)
local TeleportsTab = Window:CreateTab("Teleports", nil)
local CombatTab = Window:CreateTab("Combat", nil)
local AutomationTab = Window:CreateTab("Automation", nil)
local MiscTab = Window:CreateTab("Misc", nil)
local SettingsTab = Window:CreateTab("Settings", nil)

-- ---------- Movement ----------
featureToggles.noClip = MovementTab:CreateToggle({
    Name = "NoClip",
    CurrentValue = false,
    Flag = "MM_NoClip",
    Callback = function(value)
        SetNoClip(value)
    end,
})

featureToggles.infJump = MovementTab:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = false,
    Flag = "MM_InfJump",
    Callback = function(value)
        toggles.infiniteJump = value
    end,
})

featureToggles.speedBoost = MovementTab:CreateToggle({
    Name = "Speed Boost",
    CurrentValue = false,
    Flag = "MM_SpeedBoost",
    Callback = function(value)
        toggles.speedBoost = value
        resetWalkSpeed()
    end,
})

MovementTab:CreateSlider({
    Name = "Walk Speed",
    Range = { 10, 500 },
    Increment = 5,
    Suffix = " studs",
    CurrentValue = speedValueWalk,
    Flag = "MM_WalkSpeed",
    Callback = function(value)
        speedValueWalk = value
        persistSetting("WalkSpeed", value)
        if toggles.speedBoost then
            local humanoid = GetHumanoid(GetCharacter())
            if humanoid then
                humanoid.WalkSpeed = value
            end
        end
    end,
})

featureToggles.speedBypass = MovementTab:CreateToggle({
    Name = "Speed Bypass (Physics)",
    CurrentValue = false,
    Flag = "MM_SpeedBypass",
    Callback = function(value)
        setSpeedBypass(value)
    end,
})

MovementTab:CreateSlider({
    Name = "Physics Speed",
    Range = { 10, 500 },
    Increment = 5,
    Suffix = " studs",
    CurrentValue = Config.Movement.PhysicsSpeed,
    Flag = "MM_PhysicsSpeed",
    Callback = function(value)
        Config.Movement.PhysicsSpeed = value
        persistSetting("PhysicsSpeed", value)
    end,
})

-- ---------- Visuals ----------
featureToggles.playerESP = VisualsTab:CreateToggle({
    Name = "Player ESP",
    CurrentValue = false,
    Flag = "MM_PlayerESP",
    Callback = function(value)
        setPlayerESP(value)
    end,
})

baseEspToggle = VisualsTab:CreateToggle({
    Name = "Base ESP",
    CurrentValue = false,
    Flag = "MM_BaseESP",
    Callback = function(value)
        setBaseESP(value)
    end,
})

featureToggles.hitbox = VisualsTab:CreateToggle({
    Name = "Hitbox Expansion",
    CurrentValue = false,
    Flag = "MM_Hitbox",
    Callback = function(value)
        setHitbox(value)
    end,
})

-- ---------- Teleports ----------
local slotLabels = {}
local function refreshSlotLabel(i)
    if slotLabels[i] then
        slotLabels[i]:Set(State.savedPositions[i] and ("Slot " .. i .. ": saved ✅") or ("Slot " .. i .. ": empty"))
    end
end

for i = 1, 3 do
    TeleportsTab:CreateSection("Slot " .. i)
    slotLabels[i] = TeleportsTab:CreateLabel("Slot " .. i .. ": empty")
    TeleportsTab:CreateButton({
        Name = "💾 Save Slot " .. i,
        Callback = function()
            local root = GetRoot(GetCharacter())
            if root then
                State.savedPositions[i] = root.CFrame
                persistSetting("teleportSlots", { State.savedPositions[1], State.savedPositions[2], State.savedPositions[3] })
                refreshSlotLabel(i)
            end
        end,
    })
    TeleportsTab:CreateButton({
        Name = "📍 TP Slot " .. i,
        Callback = function()
            local root = GetRoot(GetCharacter())
            if root and State.savedPositions[i] then
                root.CFrame = State.savedPositions[i]
                root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
            end
        end,
    })
    refreshSlotLabel(i)
end

TeleportsTab:CreateButton({
    Name = "🗑️ Wipe Stored Pinpoints",
    Callback = function()
        for i = 1, 3 do
            State.savedPositions[i] = nil
            refreshSlotLabel(i)
        end
        persistSetting("teleportSlots", nil)
    end,
})

-- ---------- Combat ----------
featureToggles.aimbot = CombatTab:CreateToggle({
    Name = "BAT AIMBOT",
    CurrentValue = false,
    Flag = "MM_Aimbot",
    Callback = function(value)
        aimbotFloatVisible = value
        setAimbotEnabled(value)
    end,
})
local targetDropdown
local function buildTargetOptions(excludeName)
    local options = { "[Closest Player]" }
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Name ~= excludeName then
            options[#options + 1] = p.Name
        end
    end
    return options
end
local function refreshTargetDropdown(excludeName)
    if not targetDropdown then return end
    local options = buildTargetOptions(excludeName)
    pcall(function()
        if type(targetDropdown.Refresh) == "function" then
            targetDropdown:Refresh(options)
        else
            targetDropdown:Set(options)
        end
    end)
    pcall(function() targetDropdown:Set({ State.currentTarget }) end)
end

targetDropdown = CombatTab:CreateDropdown({
    Name = "Aimbot Target",
    Options = buildTargetOptions(),
    CurrentOption = { "[Closest Player]" },
    MultipleOptions = false,
    Callback = function(options)
        local name = (options and options[1]) or "[Closest Player]"
        State.currentTarget = name
        aimbot.target = nil
        print("[ModMenu] Aimbot target: " .. name)
    end,
})

-- the roster list follows joins/leaves (connections live in
-- State.connections, so only the re-execute teardown removes them)
State.connections.targetRosterAdded = Players.PlayerAdded:Connect(function()
    refreshTargetDropdown()
end)
State.connections.targetRosterRemoving = Players.PlayerRemoving:Connect(function(leaving)
    if State.currentTarget == leaving.Name then
        State.currentTarget = "[Closest Player]"
        aimbot.target = nil
    end
    refreshTargetDropdown(leaving.Name)
end)

CombatTab:CreateParagraph({
    Title = "Targeting",
    Content = "Pick a player above and the aimbot locks onto them; [Closest Player] chases whoever is nearest. The list updates as players join and leave. The floating AIM bubble appears while the aimbot toggle is on - drag it anywhere, tap it to flip the aimbot without opening the menu.",
})

-- ---------- Automation ----------
autoUpgradeToggle = AutomationTab:CreateToggle({
    Name = "Auto-Upgrade",
    CurrentValue = false,
    Flag = "MM_AutoUpgrade",
    Callback = function(value)
        setAutoUpgrade(value)
    end,
})

local slotCountLabel = AutomationTab:CreateLabel("Targeting: All Slots")
local slotToggles = {}
local function refreshSlotCount()
    local n = 0
    for i = 1, TOTAL_SLOTS do
        if State.selectedSlots[i] then n += 1 end
    end
    if n == TOTAL_SLOTS then
        slotCountLabel:Set("Targeting: All Slots")
    elseif n == 0 then
        slotCountLabel:Set("Targeting: None Selected")
    else
        slotCountLabel:Set("Targeting: (" .. n .. ") Slots")
    end
end

AutomationTab:CreateButton({
    Name = "Target All Slots",
    Callback = function()
        for i = 1, TOTAL_SLOTS do
            State.selectedSlots[i] = true
            if slotToggles[i] then pcall(function() slotToggles[i]:Set(true) end) end
        end
        refreshSlotCount()
    end,
})
AutomationTab:CreateButton({
    Name = "Target No Slots",
    Callback = function()
        for i = 1, TOTAL_SLOTS do
            State.selectedSlots[i] = false
            if slotToggles[i] then pcall(function() slotToggles[i]:Set(false) end) end
        end
        refreshSlotCount()
    end,
})

AutomationTab:CreateSection("Upgrade target slots")
for i = 1, TOTAL_SLOTS do
    slotToggles[i] = AutomationTab:CreateToggle({
        Name = "Slot #" .. i,
        CurrentValue = true,
        Flag = "MM_Slot" .. i,
        Callback = function(value)
            State.selectedSlots[i] = value
            refreshSlotCount()
        end,
    })
end
refreshSlotCount()

-- ---------- Misc ----------
featureToggles.instantProx = MiscTab:CreateToggle({
    Name = "Instant Proximity",
    CurrentValue = false,
    Flag = "MM_InstantProx",
    Callback = function(value)
        setInstantProximity(value)
    end,
})

featureToggles.multiPickup = MiscTab:CreateToggle({
    Name = "Radius Multi-Pickup",
    CurrentValue = false,
    Flag = "MM_MultiPickup",
    Callback = function(value)
        setMultiPickup(value)
    end,
})

featureToggles.antiAFK = MiscTab:CreateToggle({
    Name = "Anti-AFK System",
    CurrentValue = false,
    Flag = "MM_AntiAFK",
    Callback = function(value)
        toggles.antiAFK = value
    end,
})

featureToggles.autoCollect = MiscTab:CreateToggle({
    Name = "Auto-Collect Currency",
    CurrentValue = false,
    Flag = "MM_AutoCollect",
    Callback = function(value)
        setAutoCollect(value)
    end,
})

-- ---------- Settings ----------
SettingsTab:CreateDropdown({
    Name = "UI Theme",
    Options = { "Default", "AmberGlow", "Amethyst", "Bloom", "DarkBlue", "Green", "Light", "Ocean", "Serenity" },
    CurrentOption = { "Default" },
    MultipleOptions = false,
    Callback = function(options)
        local name = options and options[1]
        if name then
            pcall(function() Window.ModifyTheme(name) end)
        end
    end,
})

SettingsTab:CreateButton({
    Name = "🛑 Stop Everything (Cleanup)",
    Callback = function()
        stopAllFeatures()
        print("[ModMenu] All features stopped - menu still live, toggles work")
    end,
})

featureToggles.baseESP = baseEspToggle
featureToggles.autoUpgrade = autoUpgradeToggle

-- remember cleanup so the next execution can stop this instance's loops first
_envStore.__ModMenuCleanup = cleanup

print("[ModMenu] v3.5 loaded - Rayfield window created")
