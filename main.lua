--[[
    LAST STOP [BETA] - ROADSIDE TOOLKIT v10.5
    Client-side survival toolkit.

    Included:
      * Loot / pickup ESP (name + distance)
      * Zombie ESP and boss ESP
      * Teammate ESP (off by default)
      * 360-degree hostile target acquisition without character chasing
      * Melee swing attempts plus optional firearm aim / auto-shoot with LOS checks
      * Teleport-assisted loot pickup and return-to-bus navigation
      * Local no-clip and walk-speed controls with restoration on unload
      * Dedicated unload button and local health / player-count / aura HUD
      * Reversible low-effects mode
      * Draggable, collapsible UI
      * RightShift toggles the menu

    The aura excludes player characters and known friendly NPCs. It supports
    Uses Last Stop's observed ENTITY_CONTAINER / ITEM_CONTAINER hierarchy and
    Knit service discovery. Dead Rails APIs are not used for Last Stop;
    no remote is invoked unless its exact protocol is independently verified.
    Melee input remains subject to server hit validation; Last Stop pickup uses its visible F / Pick Up action.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    return
end

local env = _G
pcall(function()
    if type(getgenv) == "function" then
        local executorEnv = getgenv()
        if type(executorEnv) == "table" then
            env = executorEnv
        end
    end
end)

-- Clean up an older copy before starting a new one.
if type(env.__LASTSTOP_TOOLKIT_CLEANUP) == "function" then
    pcall(env.__LASTSTOP_TOOLKIT_CLEANUP)
end

env.__LASTSTOP_TOOLKIT_CLEANUP = nil

local state = {
    replicatedStorage = game:GetService("ReplicatedStorage"),
    currentAuraApi = "Not scanned",
    currentGunApi = "Not scanned",
    currentLootApi = "Not scanned",
    cachedGlobalSwingRemote = nil,
    lastGlobalSwingRemoteScan = -math.huge,
    cachedGlobalSwingPath = nil,
    cachedDeadRailsShootRemote = nil,
    cachedDeadRailsLootRemotes = {},
    deadRailsRemoteScanAt = {},
    deadRailsToolRemoteScanAt = {},
    cachedObjectModelsFolder = nil,
    cachedRuntimeItemsFolder = nil,
    cachedItemContainer = nil,
    objectModelsScanAt = 0,
    runtimeItemsScanAt = 0,
    itemContainerScanAt = 0,
    lastDamageEventSummary = "No DamageDealt event observed yet",
    lastProjectileEventSummary = "No ProjectileHit event observed yet",
    lastEntityKilledSummary = "No EntityKilled event observed yet",
    lastMethodCalledSummary = "No MethodCalled event observed yet",
    lastInventoryChangedSummary = "No InventoryChanged event observed yet",
    lastCollectedMethodName = "",
    lastCollectedMethodAt = 0,
    lastDamagePosition = nil,
    lastDamageEventAt = 0,
    lastEntityKilledType = "",
    lastEntityKilledAt = 0,
    lastLootDirectCount = 0,
    lastLootFeatureGrabCount = 0,
    lastLootRegisteredCount = 0,
    lastLootInRangeCount = 0,
    entityContextCache = setmetatable({}, {__mode = "k"}),
    entityContextCacheAt = setmetatable({}, {__mode = "k"}),
    entityRigCache = setmetatable({}, {__mode = "k"}),
    entityRigCacheAt = setmetatable({}, {__mode = "k"}),
    running = true,
    loot = true,
    zombies = true,
    bosses = true,
    players = false,
    distance = true,
    hud = true,
    performance = false,
    killAura = false,
    auraBosses = false,
    auraAllNPCs = false,
    autoEquipMelee = true,
    auraFace = false,
    auraAimCamera = false,
    auraHitRange = 6.5, -- input fallback only; native remotes use acquisition range
    auraRange = 250,
    auraInterval = 0.01,
    gunAimAssist = false,
    gunAutoShoot = false,
    gunAutoReload = false,
    lastGunReloadAt = 0,
    gunWallCheck = true,
    rapidToolResetMelee = false,
    rapidMeleeBusy = false,
    lastRapidMeleeAt = 0,
    gunRange = 180,
    gunFireInterval = 0.22,
    autoLoot = false,
    autoReturnBus = true,
    autoStoreAtBus = false,
    autoEmergencyReturn = false,
    autoCollectMoney = true,
    autoCollectBonds = true,
    autoCollectAmmo = true,
    autoCollectGuns = true,
    autoCollectMeds = true,
    manualReturnRequested = false,
    manualStoreRequested = false,
    manualDiagnosticsRequested = false,
    currentAuraTargetInstance = nil,
    auraUnverifiedCount = 0,
    deadAuraBlacklist = setmetatable({}, {__mode = "k"}),
    auraDeathConnections = setmetatable({}, {__mode = "k"}),
    lootRejected = setmetatable({}, {__mode = "k"}),
    lootRange = 80,
    lootReturnThreshold = 9,
    noClip = false,
    walkSpeed = false,
    walkSpeedValue = 28,
    maxDistance = 1000,
    scanInterval = 2.0,
}

local connections = {}
local markers = {}
local auraCandidates = {}
local auraRegistrationPending = setmetatable({}, {__mode = "k"})
local lootCandidates = setmetatable({}, {__mode = "k"})
local lootRegistrationPending = setmetatable({}, {__mode = "k"})
local lootInteractionCache = setmetatable({}, {__mode = "k"})
local currentAuraStatus = "Off"
local currentAuraWeapon = "Not detected"
local currentAuraTargetName = "--"
local currentAuraInput = "idle"
local auraConfirmedHits = 0
local auraAttackAttempts = 0
local lastAuraAttack = 0
local releaseAuraInputCallback = nil
local lootStatus = "Off"
local lootCurrentTarget = "--"
local lootCollected = 0
local lootCollectedSinceReturn = 0
local lootAttempts = 0
local lootCandidateCount = 0
local lootInRangeCount = 0
local lootLastAttempt = setmetatable({}, {__mode = "k"})
local lootFailedAttempts = setmetatable({}, {__mode = "k"})
local lootTeleports = 0
local gunTargetActive = false
local gunStatus = "Off"
local gunTargetName = "--"
local gunShots = 0
local gunConfirmedHits = 0
local gunBlockedShots = 0
local lastGunShot = 0
local lastGunBlockedAt = 0
local combatTargetActive = false
local primeNoClipCallback = nil
local characterPartAddedConnection = nil
local characterPartRemovingConnection = nil
local noClipCache = {}
local originalWalkSpeeds = {}
local visualCache = {}
local gui
local mainFrame
local statusLabel
local hudFrame
local hudLabel
local lastScanCount = 0
local originalGlobalShadows = Lighting.GlobalShadows

local function restoreNoClip()
    for part, oldValue in pairs(noClipCache) do
        if part and part.Parent then
            pcall(function()
                part.CanCollide = oldValue
            end)
        end
    end
    table.clear(noClipCache)
end

local function restoreWalkSpeed()
    for humanoid, oldValue in pairs(originalWalkSpeeds) do
        if humanoid and humanoid.Parent then
            pcall(function()
                humanoid.WalkSpeed = oldValue
            end)
        end
    end
    table.clear(originalWalkSpeeds)
end

local function restoreMovement()
    state.noClip = false
    state.walkSpeed = false
    restoreNoClip()
    restoreWalkSpeed()
end

local function track(connection)
    table.insert(connections, connection)
    return connection
end

local function safeDestroy(object)
    if object then
        pcall(function()
            object:Destroy()
        end)
    end
end

local function isVisualEffect(object)
    return object:IsA("ParticleEmitter")
        or object:IsA("Trail")
        or object:IsA("Beam")
        or object:IsA("Fire")
        or object:IsA("Smoke")
        or object:IsA("Sparkles")
        or object:IsA("PostEffect")
end

local function disableEffect(object)
    if not isVisualEffect(object) then
        return
    end

    if visualCache[object] == nil then
        local ok, oldValue = pcall(function()
            return object.Enabled
        end)
        if ok then
            visualCache[object] = oldValue
        end
    end

    pcall(function()
        object.Enabled = false
    end)
end

local function setPerformanceMode(enabled)
    state.performance = enabled

    if enabled then
        originalGlobalShadows = Lighting.GlobalShadows
        pcall(function()
            Lighting.GlobalShadows = false
        end)

        for _, object in ipairs(Workspace:GetDescendants()) do
            disableEffect(object)
        end
        for _, object in ipairs(Lighting:GetDescendants()) do
            disableEffect(object)
        end
    else
        pcall(function()
            Lighting.GlobalShadows = originalGlobalShadows
        end)

        for object, oldValue in pairs(visualCache) do
            if object and object.Parent then
                pcall(function()
                    object.Enabled = oldValue
                end)
            end
        end
        table.clear(visualCache)
    end
end

local function destroyMarker(instance)
    local marker = markers[instance]
    if not marker then
        return
    end

    safeDestroy(marker.highlight)
    safeDestroy(marker.billboard)
    markers[instance] = nil
end

local function cleanup()
    if not state.running then
        return
    end

    state.running = false
    combatTargetActive = false
    gunTargetActive = false
    if characterPartAddedConnection then
        pcall(function() characterPartAddedConnection:Disconnect() end)
        characterPartAddedConnection = nil
    end
    if characterPartRemovingConnection then
        pcall(function() characterPartRemovingConnection:Disconnect() end)
        characterPartRemovingConnection = nil
    end
    if releaseAuraInputCallback then
        pcall(releaseAuraInputCallback)
    end

    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(connections)

    for instance in pairs(markers) do
        destroyMarker(instance)
    end

    if state.performance then
        setPerformanceMode(false)
    end

    restoreMovement()
    for _, modelConnections in pairs(state.auraDeathConnections) do
        for _, connection in ipairs(modelConnections) do
            pcall(function() connection:Disconnect() end)
        end
    end
    table.clear(state.auraDeathConnections)
    table.clear(state.deadAuraBlacklist)
    table.clear(auraCandidates)
    table.clear(auraRegistrationPending)
    table.clear(lootCandidates)
    table.clear(lootRegistrationPending)
    table.clear(lootInteractionCache)
    table.clear(state.lootRejected)
    safeDestroy(gui)
    gui = nil

    if env.__LASTSTOP_TOOLKIT_CLEANUP then
        env.__LASTSTOP_TOOLKIT_CLEANUP = nil
    end
end

env.__LASTSTOP_TOOLKIT_CLEANUP = cleanup

local function make(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do
        object[key] = value
    end
    object.Parent = parent
    return object
end

local function getGuiParent()
    if type(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then
            return result
        end
    end

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        return playerGui
    end

    return LocalPlayer:WaitForChild("PlayerGui")
end

local guiParent = getGuiParent()
local guiProperties = {
    Name = "LastStopRoadsideToolkit",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}
local guiOk, createdGui = pcall(function()
    return make("ScreenGui", guiProperties, guiParent)
end)
if not guiOk then
    local fallbackGuiParent = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        or LocalPlayer:WaitForChild("PlayerGui")
    guiOk, createdGui = pcall(function()
        return make("ScreenGui", guiProperties, fallbackGuiParent)
    end)
end
if not guiOk or not createdGui then
    cleanup()
    return
end
gui = createdGui

local palette = {
    background = Color3.fromRGB(15, 18, 24),
    panel = Color3.fromRGB(22, 27, 35),
    row = Color3.fromRGB(29, 35, 45),
    rowOn = Color3.fromRGB(34, 48, 48),
    border = Color3.fromRGB(54, 65, 78),
    text = Color3.fromRGB(235, 240, 245),
    muted = Color3.fromRGB(145, 157, 170),
    accent = Color3.fromRGB(94, 220, 176),
    red = Color3.fromRGB(255, 105, 105),
}

mainFrame = make("Frame", {
    Name = "Main",
    Size = UDim2.new(0, 322, 0, 470),
    Position = UDim2.new(0, 20, 0, 115),
    BackgroundColor3 = palette.background,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 10)}, mainFrame)
make("UIStroke", {Color = palette.border, Thickness = 1, Transparency = 0.15}, mainFrame)

local topBar = make("Frame", {
    Name = "TopBar",
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = palette.panel,
    BorderSizePixel = 0,
    Active = true,
}, mainFrame)
make("UICorner", {CornerRadius = UDim.new(0, 10)}, topBar)

make("Frame", {
    Name = "HeaderFill",
    Position = UDim2.new(0, 0, 1, -10),
    Size = UDim2.new(1, 0, 0, 10),
    BackgroundColor3 = palette.panel,
    BorderSizePixel = 0,
}, topBar)

make("TextLabel", {
    Name = "Title",
    Position = UDim2.new(0, 14, 0, 7),
    Size = UDim2.new(1, -105, 0, 20),
    BackgroundTransparency = 1,
    Text = "LAST STOP  /  ROADSIDE",
    TextColor3 = palette.text,
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)

make("TextLabel", {
    Name = "Subtitle",
    Position = UDim2.new(0, 14, 0, 27),
    Size = UDim2.new(1, -105, 0, 13),
    BackgroundTransparency = 1,
    Text = "CLIENT-SIDE SURVIVAL TOOLKIT  /  V10.5",
    TextColor3 = palette.muted,
    Font = Enum.Font.Gotham,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)

local minimizeButton = make("TextButton", {
    Name = "Minimize",
    Position = UDim2.new(1, -70, 0, 9),
    Size = UDim2.new(0, 25, 0, 27),
    BackgroundColor3 = palette.row,
    BorderSizePixel = 0,
    Text = "-",
    TextColor3 = palette.text,
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    AutoButtonColor = false,
}, topBar)
make("UICorner", {CornerRadius = UDim.new(0, 6)}, minimizeButton)

local closeButton = make("TextButton", {
    Name = "Close",
    Position = UDim2.new(1, -37, 0, 9),
    Size = UDim2.new(0, 25, 0, 27),
    BackgroundColor3 = Color3.fromRGB(66, 35, 40),
    BorderSizePixel = 0,
    Text = "X",
    TextColor3 = palette.red,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
}, topBar)
make("UICorner", {CornerRadius = UDim.new(0, 6)}, closeButton)

local content = make("ScrollingFrame", {
    Name = "Content",
    Position = UDim2.new(0, 0, 0, 54),
    Size = UDim2.new(1, 0, 1, -88),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = palette.border,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, mainFrame)

make("UIPadding", {
    PaddingLeft = UDim.new(0, 12),
    PaddingRight = UDim.new(0, 12),
    PaddingTop = UDim.new(0, 5),
    PaddingBottom = UDim.new(0, 10),
}, content)
make("UIListLayout", {
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, content)

local footer = make("Frame", {
    Name = "Footer",
    Position = UDim2.new(0, 0, 1, -29),
    Size = UDim2.new(1, 0, 0, 29),
    BackgroundColor3 = palette.panel,
    BorderSizePixel = 0,
}, mainFrame)

statusLabel = make("TextLabel", {
    Position = UDim2.new(0, 13, 0, 0),
    Size = UDim2.new(1, -26, 1, 0),
    BackgroundTransparency = 1,
    Text = "Ready  |  RightShift: hide menu",
    TextColor3 = palette.muted,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
}, footer)

local layoutOrder = 0
local toggleRefreshers = {}

local function addSection(text)
    layoutOrder = layoutOrder + 1
    make("TextLabel", {
        Name = "Section_" .. tostring(layoutOrder),
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Text = string.upper(text),
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = layoutOrder,
    }, content)
end

local function addToggle(labelText, key, description)
    layoutOrder = layoutOrder + 1
    local row = make("TextButton", {
        Name = "Toggle_" .. key,
        Size = UDim2.new(1, 0, 0, description and 48 or 38),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, description and 7 or 0),
        Size = UDim2.new(1, -83, 0, description and 18 or 38),
        BackgroundTransparency = 1,
        Text = labelText,
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = description and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center,
    }, row)

    if description then
        make("TextLabel", {
            Position = UDim2.new(0, 11, 0, 26),
            Size = UDim2.new(1, -22, 0, 13),
            BackgroundTransparency = 1,
            Text = description,
            TextColor3 = palette.muted,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
    end

    local indicator = make("TextLabel", {
        Position = UDim2.new(1, -59, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = palette.muted,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)

    local function refresh()
        local enabled = state[key]
        indicator.Text = enabled and "ON" or "OFF"
        indicator.TextColor3 = enabled and palette.accent or palette.muted
        row.BackgroundColor3 = enabled and palette.rowOn or palette.row
    end

    refresh()
    toggleRefreshers[key] = refresh

    track(row.MouseButton1Click:Connect(function()
        if key == "performance" then
            setPerformanceMode(not state.performance)
        else
            state[key] = not state[key]
            if key == "noClip" then
                if state.noClip then
                    if primeNoClipCallback then
                        primeNoClipCallback()
                    end
                else
                    restoreNoClip()
                end
            elseif key == "walkSpeed" and not state.walkSpeed then
                restoreWalkSpeed()
            end
        end
        refresh()
    end))
end

local function setFeatureToggle(key, value)
    state[key] = value
    local refresh = toggleRefreshers[key]
    if refresh then
        refresh()
    end
end

local function addActionButton(labelText, callback, backgroundColor)
    layoutOrder = layoutOrder + 1
    local button = make("TextButton", {
        Name = "Action_" .. string.gsub(labelText, "%W+", ""),
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = backgroundColor or palette.panel,
        BorderSizePixel = 0,
        Text = labelText,
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        AutoButtonColor = false,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, button)
    track(button.MouseButton1Click:Connect(callback))
    return button
end

local function addAuraRangeControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "AuraRangeControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "Aura scan radius (not melee hitbox)",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = tostring(state.auraRange) .. " studs",
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = tostring(state.auraRange) .. " studs"
    end

    track(minus.MouseButton1Click:Connect(function()
        state.auraRange = math.max(10, state.auraRange - 5)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.auraRange = math.min(250, state.auraRange + 5)
        refresh()
    end))
end

local function addGunRangeControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "GunRangeControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "Gun target range",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = tostring(state.gunRange) .. " studs",
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = tostring(state.gunRange) .. " studs"
    end

    track(minus.MouseButton1Click:Connect(function()
        state.gunRange = math.max(25, state.gunRange - 25)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.gunRange = math.min(300, state.gunRange + 25)
        refresh()
    end))
end

local function addLootRangeControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "LootRangeControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "Auto-loot search radius",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = tostring(state.lootRange) .. " studs",
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = tostring(state.lootRange) .. " studs"
    end

    track(minus.MouseButton1Click:Connect(function()
        state.lootRange = math.max(20, state.lootRange - 10)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.lootRange = math.min(300, state.lootRange + 10)
        refresh()
    end))
end

local function addLootReturnThresholdControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "LootReturnThresholdControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "Return at tool count",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = tostring(state.lootReturnThreshold),
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = tostring(state.lootReturnThreshold)
    end

    track(minus.MouseButton1Click:Connect(function()
        state.lootReturnThreshold = math.max(3, state.lootReturnThreshold - 1)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.lootReturnThreshold = math.min(10, state.lootReturnThreshold + 1)
        refresh()
    end))
end

local function addWalkSpeedControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "WalkSpeedControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "Walk speed",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = tostring(state.walkSpeedValue),
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = tostring(state.walkSpeedValue)
    end

    track(minus.MouseButton1Click:Connect(function()
        state.walkSpeedValue = math.max(16, state.walkSpeedValue - 2)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.walkSpeedValue = math.min(60, state.walkSpeedValue + 2)
        refresh()
    end))
end

local function addAttackDelayControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "AuraDelayControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "Melee input interval",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = string.format("%.2fs", state.auraInterval),
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = string.format("%.2fs", state.auraInterval)
    end

    track(minus.MouseButton1Click:Connect(function()
        state.auraInterval = math.max(0.01, math.floor((state.auraInterval - 0.01) * 100 + 0.5) / 100)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.auraInterval = math.min(0.50, math.floor((state.auraInterval + 0.01) * 100 + 0.5) / 100)
        refresh()
    end))
end

local function addDistanceControl()
    layoutOrder = layoutOrder + 1
    local row = make("Frame", {
        Name = "DistanceControl",
        Size = UDim2.new(1, 0, 0, 42),
        BackgroundColor3 = palette.row,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder,
    }, content)
    make("UICorner", {CornerRadius = UDim.new(0, 7)}, row)

    make("TextLabel", {
        Position = UDim2.new(0, 11, 0, 0),
        Size = UDim2.new(1, -145, 1, 0),
        BackgroundTransparency = 1,
        Text = "ESP render distance",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLabel = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 0),
        Size = UDim2.new(0, 48, 1, 0),
        BackgroundTransparency = 1,
        Text = tostring(state.maxDistance),
        TextColor3 = palette.accent,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local minus = make("TextButton", {
        Position = UDim2.new(1, -62, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "-",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, minus)

    local plus = make("TextButton", {
        Position = UDim2.new(1, -32, 0, 8),
        Size = UDim2.new(0, 24, 0, 26),
        BackgroundColor3 = palette.panel,
        BorderSizePixel = 0,
        Text = "+",
        TextColor3 = palette.text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
    }, row)
    make("UICorner", {CornerRadius = UDim.new(0, 5)}, plus)

    local function refresh()
        valueLabel.Text = tostring(state.maxDistance)
    end

    track(minus.MouseButton1Click:Connect(function()
        state.maxDistance = math.max(250, state.maxDistance - 250)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.maxDistance = math.min(3000, state.maxDistance + 250)
        refresh()
    end))
end

addSection("Visual tracking")
addToggle("Loot and pickups", "loot", "Fuel, parts, weapons, ammo, supplies and likely drops")
addToggle("Zombies / enemies", "zombies")
addToggle("Bosses", "bosses")
addToggle("Teammates", "players")
addToggle("Distance labels", "distance")
addDistanceControl()

addSection("Combat")
addToggle("Zombie / enemy kill aura", "killAura", "Automates normal Swing input; no verified long-range melee remote")
addToggle("Include bosses", "auraBosses", "Includes Fred, Anubis, Dracula, Crystalus and Juggernaut")
addToggle("Target unknown NPCs", "auraAllNPCs", "Fallback detection; known friendly NPCs are excluded")
addToggle("Auto-equip melee", "autoEquipMelee", "Equips an available melee tool when none is equipped")
addToggle("Auto-face target", "auraFace", "Rotates your character toward the target for normal melee input")
addToggle("Aim camera at target", "auraAimCamera", "Optional camera aim for click-to-swing and gun input")
addToggle("Gun auto-aim", "gunAimAssist", "Aims at the nearest visible hostile while a firearm is equipped")
addToggle("Gun auto-shoot", "gunAutoShoot", "Fires only when a raycast confirms a clear line to the target")
addToggle("Gun auto-reload", "gunAutoReload", "Uses Last Stop's normal R reload control when an ammo counter reads zero")
addGunRangeControl()
addAuraRangeControl()
addAttackDelayControl()

addSection("Automation")
addToggle("Auto loot nearby items", "autoLoot", "Scans GUID-named ITEM_CONTAINER Tools and presses F / Pick Up")
addToggle("Return to bus when done", "autoReturnBus", "Teleports back after a loot sweep or inventory threshold")
addToggle("Auto-store at bus", "autoStoreAtBus", "Disabled until Last Stop StoreItem argument contract is verified")
addToggle("Emergency return below 35% HP", "autoEmergencyReturn", "Requests a bus return when health falls below 35 percent")
addSection("Loot priorities")
addToggle("Money bags / cash", "autoCollectMoney")
addToggle("Bonds", "autoCollectBonds")
addToggle("Ammo", "autoCollectAmmo")
addToggle("Weapons", "autoCollectGuns")
addToggle("Medical supplies", "autoCollectMeds")
addLootRangeControl()
addLootReturnThresholdControl()

layoutOrder = layoutOrder + 1
do
local emergencyReturnButton = make("TextButton", {
    Name = "EmergencyReturnBus",
    Size = UDim2.new(1, 0, 0, 36),
    BackgroundColor3 = Color3.fromRGB(68, 48, 34),
    BorderSizePixel = 0,
    Text = "EMERGENCY RETURN TO BUS",
    TextColor3 = Color3.fromRGB(255, 205, 135),
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    AutoButtonColor = false,
    LayoutOrder = layoutOrder,
}, content)
make("UICorner", {CornerRadius = UDim.new(0, 7)}, emergencyReturnButton)
track(emergencyReturnButton.MouseButton1Click:Connect(function()
    state.manualReturnRequested = true
    lootStatus = "Emergency return requested"
end))
end

addActionButton("STORE INVENTORY AT BUS (IF SUPPORTED)", function()
    state.manualStoreRequested = true
    lootStatus = "Store request queued"
end, Color3.fromRGB(37, 67, 78))

addActionButton("COPY GAME API DIAGNOSTICS", function()
    state.manualDiagnosticsRequested = true
    lootStatus = "Diagnostics queued"
end, Color3.fromRGB(37, 67, 78))

addActionButton("START MELEE + AUTO LOOT", function()
    setFeatureToggle("killAura", true)
    setFeatureToggle("autoLoot", true)
    if statusLabel then statusLabel.Text = "Melee + auto loot enabled" end
end, Color3.fromRGB(42, 76, 62))

addActionButton("STOP ALL AUTOMATION", function()
    setFeatureToggle("killAura", false)
    setFeatureToggle("autoLoot", false)
    setFeatureToggle("gunAimAssist", false)
    setFeatureToggle("gunAutoShoot", false)
    if statusLabel then statusLabel.Text = "Combat and loot automation stopped" end
end, Color3.fromRGB(76, 42, 48))

addSection("Movement")
addToggle("No clip", "noClip", "Disables character part collisions locally; restores them when off")
addToggle("Walk speed", "walkSpeed", "Applies the selected local Humanoid speed")
addWalkSpeedControl()

addSection("Utility")
addToggle("Status HUD", "hud", "Local health, player count and current ESP marker count")
addToggle("Performance mode", "performance", "Disables selected visual effects locally; restores them when turned off")

addSection("Game controls")
make("TextLabel", {
    Name = "ControlsInfo",
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = palette.row,
    BorderSizePixel = 0,
    Text = "CLICK  Grab / Shoot     Z  Place / Attach\nE  Equip / Use     Q  Drop     R  Reload\nTAB  Inventory     Y  Inspect",
    TextColor3 = palette.muted,
    Font = Enum.Font.Gotham,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
    LayoutOrder = layoutOrder + 1,
}, content)

layoutOrder = layoutOrder + 2
local unloadButton = make("TextButton", {
    Name = "UnloadScript",
    Size = UDim2.new(1, 0, 0, 38),
    BackgroundColor3 = Color3.fromRGB(66, 35, 40),
    BorderSizePixel = 0,
    Text = "UNLOAD SCRIPT",
    TextColor3 = palette.red,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    AutoButtonColor = false,
    LayoutOrder = layoutOrder,
}, content)
make("UICorner", {CornerRadius = UDim.new(0, 7)}, unloadButton)

-- Small status HUD, separate from the main menu.
hudFrame = make("Frame", {
    Name = "StatusHUD",
    Size = UDim2.new(0, 430, 0, 140),
    Position = UDim2.new(1, -445, 0, 18),
    BackgroundColor3 = palette.background,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Visible = state.hud,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 8)}, hudFrame)
make("UIStroke", {Color = palette.border, Thickness = 1, Transparency = 0.2}, hudFrame)

hudLabel = make("TextLabel", {
    Position = UDim2.new(0, 10, 0, 3),
    Size = UDim2.new(1, -20, 1, -6),
    BackgroundTransparency = 1,
    Text = "HP --/--  |  Players --\nESP: 0  |  NPCs: 0  |  Melee: Off\nGun: Off  |  Shots: 0  |  Blocked: 0\nLoot: Off  |  Looted: 0  |  Teleports: 0\nAttempts: 0  |  Target: --  |  Candidates: 0",
    TextColor3 = palette.text,
    Font = Enum.Font.GothamSemibold,
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
}, hudFrame)

-- Dragging.
local dragging = false
local dragInputType = nil
local dragStart
local frameStart

track(topBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragInputType = input.UserInputType
        dragStart = input.Position
        frameStart = mainFrame.Position
    end
end))

track(UserInputService.InputEnded:Connect(function(input)
    if dragging and input.UserInputType == dragInputType then
        dragging = false
        dragInputType = nil
    end
end))

track(UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(
            frameStart.X.Scale,
            frameStart.X.Offset + delta.X,
            frameStart.Y.Scale,
            frameStart.Y.Offset + delta.Y
        )
    end
end))

local minimized = false
track(minimizeButton.MouseButton1Click:Connect(function()
    minimized = not minimized
    content.Visible = not minimized
    footer.Visible = not minimized
    mainFrame.Size = minimized and UDim2.new(0, 322, 0, 48) or UDim2.new(0, 322, 0, 470)
    minimizeButton.Text = minimized and "+" or "-"
end))

track(closeButton.MouseButton1Click:Connect(cleanup))
track(unloadButton.MouseButton1Click:Connect(cleanup))

track(UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        gui.Enabled = not gui.Enabled
    end
end))

local bossWords = {
    "boss", "fred", "anubis", "dracula", "nightmare", "vampire lord",
    "overlord", "crystalus", "juggernaut"
}

local zombieWords = {
    "zombie", "undead", "infected", "ghoul", "skeleton", "vampire",
    "crawler", "walker", "bloater", "brute", "bandit", "raider",
    "sniper", "alien", "mutant", "monster", "enemy", "guard", "soldier",
    "trooper", "hostile", "mummy", "patient", "werewolf", "wolf",
    "skeleton king", "zombie dog", "infected human", "mutant human"
}

local friendlyWords = {
    "shopkeeper", "doctor", "lumberjack", "trader", "merchant", "vendor",
    "blacksmith", "quest giver", "questgiver", "survivor", "civilian",
    "settler", "ally", "friendly"
}

local npcContainerWords = {"npc", "npcs", "entities", "mob", "mobs"}

local lootWords = {
    "loot", "pickup", "drop", "fuel", "gas can", "gasoline", "wood",
    "scrap", "ammo", "bullet", "med", "bandage", "food", "water",
    "battery", "weapon", "gun", "rifle", "pistol", "revolver", "shotgun",
    "key", "cure", "potion", "cash", "ticket", "crate", "material", "metal",
    "coal", "pipe", "armor", "vest", "flashlight", "fuse", "engine", "canister"
}

local lootFolderWords = {"loot", "drops", "pickups", "worlditems", "items", "item_container", "itemcontainer"}

local function hasAny(text, words)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

local function getContextName(instance)
    local names = {}
    local function appendObjectContext(object)
        if not object then
            return
        end
        table.insert(names, string.lower(object.Name))
        local okEntity, entityName = pcall(function()
            return object:GetAttribute("EntityName")
        end)
        if okEntity and type(entityName) == "string" and entityName ~= "" then
            table.insert(names, string.lower(entityName))
        end
        local okBounty, bounty = pcall(function()
            return object:GetAttribute("Bounty")
        end)
        if okBounty and bounty ~= nil and bounty ~= false and bounty ~= 0 and bounty ~= "" then
            table.insert(names, "bounty")
        end
    end

    appendObjectContext(instance)
    local parent = instance.Parent
    for _ = 1, 7 do
        if not parent then
            break
        end
        appendObjectContext(parent)
        parent = parent.Parent
    end
    return table.concat(names, " ")
end

-- Last Stop-specific containers. Unlike Dead Rails, this experience exposes
-- ENTITY_CONTAINER and ITEM_CONTAINER in Workspace.
state.getLastStopEntityContainer = function()
    return Workspace:FindFirstChild("ENTITY_CONTAINER")
end

state.getLastStopEntityContext = function(model)
    if model then
        local cached = state.entityContextCache[model]
        local cachedAt = state.entityContextCacheAt[model] or 0
        if cached and os.clock() - cachedAt < 0.35 then
            return cached
        end
    end
    local names = {getContextName(model)}
    if not model or not model:IsA("Model") then
        return table.concat(names, " ")
    end

    local ok, descendants = pcall(function()
        return model:GetDescendants()
    end)
    if ok then
        local inspected = 0
        for _, object in ipairs(descendants) do
            local name = string.lower(object.Name)
            if hasAny(name, zombieWords) or hasAny(name, bossWords)
                or hasAny(name, friendlyWords)
                or hasAny(name, {"corpse", "ragdoll", "deadbody", "dead_body", "death"}) then
                table.insert(names, name)
                inspected = inspected + 1
                if inspected >= 48 then break end
            end

            for _, attributeName in ipairs({"EntityName", "DisplayName", "NPCName"}) do
                local attrOk, value = pcall(function()
                    return object:GetAttribute(attributeName)
                end)
                if attrOk and type(value) == "string" and value ~= "" then
                    local lowered = string.lower(value)
                    if hasAny(lowered, zombieWords) or hasAny(lowered, bossWords)
                        or hasAny(lowered, friendlyWords) then
                        table.insert(names, lowered)
                    end
                end
            end
        end
    end
    local result = table.concat(names, " ")
    if model then
        state.entityContextCache[model] = result
        state.entityContextCacheAt[model] = os.clock()
    end
    return result
end

state.getLastStopEntityRoot = function(instance)
    local entityContainer = state.getLastStopEntityContainer()
    local current = instance
    local highestModel = nil

    while current and current ~= Workspace do
        if current:IsA("Model") then
            highestModel = current
            if entityContainer and current.Parent == entityContainer then
                return current
            end
        end
        current = current.Parent
    end

    if highestModel then
        local context = state.getLastStopEntityContext(highestModel)
        if hasAny(context, zombieWords) or hasAny(context, bossWords) then
            return highestModel
        end
    end
    return nil
end

state.isLastStopEntityRoot = function(model)
    if not model or not model:IsA("Model") then
        return false
    end
    local entityContainer = state.getLastStopEntityContainer()
    if entityContainer and model.Parent == entityContainer then
        return true
    end
    local context = state.getLastStopEntityContext(model)
    return hasAny(context, zombieWords) or hasAny(context, bossWords)
end

state.getEntityRigEvidence = function(model)
    if model then
        local cached = state.entityRigCache[model]
        local cachedAt = state.entityRigCacheAt[model] or 0
        if cached and os.clock() - cachedAt < 0.15 then
            return cached[1], cached[2], cached[3], cached[4]
        end
    end
    local motorCount, ballSocketCount, animatorCount, playingTrackCount = 0, 0, 0, 0
    if not model then
        return motorCount, ballSocketCount, animatorCount, playingTrackCount
    end
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("Motor6D") then
            motorCount = motorCount + 1
        elseif object:IsA("BallSocketConstraint") then
            ballSocketCount = ballSocketCount + 1
        elseif object:IsA("Animator") then
            animatorCount = animatorCount + 1
            local ok, tracks = pcall(function()
                return object:GetPlayingAnimationTracks()
            end)
            if ok and type(tracks) == "table" then
                playingTrackCount = playingTrackCount + #tracks
            end
        end
    end
    if model then
        state.entityRigCache[model] = {motorCount, ballSocketCount, animatorCount, playingTrackCount}
        state.entityRigCacheAt[model] = os.clock()
    end
    return motorCount, ballSocketCount, animatorCount, playingTrackCount
end

state.isGuidLikeName = function(value)
    if type(value) ~= "string" then return false end
    local compact = string.gsub(value, "[%-%{%}]", "")
    return #compact >= 24 and string.match(compact, "^[%x]+$") ~= nil
end

state.cleanDisplayValue = function(value)
    if type(value) ~= "string" then return nil end
    value = string.gsub(value, "[%c]", " ")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    if value == "" or #value > 56 or state.isGuidLikeName(value) then return nil end
    local lower = string.lower(value)
    local generic = {
        handle=true, configuration=true, promptpart=true, attachment=true,
        model=true, meshpart=true, tool=true, data=true, part=true,
        basepart=true, unionoperation=true, folder=true, item=true,
        pricetag=true, frame=true, label=true, canvasgroup=true,
        main=true, primary=true, primaryweld=true, weld=true,
        weldconstraint=true, motor6d=true, tps=true, fps=true,
        common=true, uncommon=true, rare=true, epic=true, legendary=true,
        mythic=true, shine=true, surfaceappearance=true, basemodel=true,
    }
    if generic[lower] then return nil end
    if string.match(lower, "^%$?%s*[%d%.]+%s*[kmb]?$")
        or string.match(lower, "^%d+%s*x$")
        or string.match(lower, "^%d+/%d+$") then return nil end
    if string.match(lower, "^cube[%._%-]?%d*$")
        or string.match(lower, "^cylinder[%._%-]?%d*$")
        or string.match(lower, "^mesh[%._%-]?%d*$") then return nil end
    return value
end

state.getItemDisplayName = function(object)
    if not object then return "Unknown item" end
    local function clean(value)
        return state.cleanDisplayValue(value)
    end
    if object:IsA("Tool") then
        local ok, tooltip = pcall(function() return object.ToolTip end)
        local cleaned = ok and clean(tooltip) or nil
        if cleaned then return cleaned end
    end

    local preferredAttributes = {"DisplayName", "ItemName", "WeaponName", "ItemType", "ToolType", "Type", "DisplayText", "Title", "Name"}
    for _, attributeName in ipairs(preferredAttributes) do
        local ok, value = pcall(function() return object:GetAttribute(attributeName) end)
        local cleaned = ok and clean(value) or nil
        if cleaned then return cleaned end
    end

    local descendants = {}
    pcall(function() descendants = object:GetDescendants() end)

    -- Last Stop world Tools expose a PriceTag BillboardGui. Read its text
    -- instead of displaying the GUID used as the Tool's Instance.Name.
    for _, child in ipairs(descendants) do
        if child:IsA("TextLabel") or child:IsA("TextButton") then
            local ok, text = pcall(function() return child.Text end)
            if ok and type(text) == "string" then
                for line in string.gmatch(text, "[^\r\n]+") do
                    local cleaned = clean(line)
                    if cleaned then return cleaned end
                end
            end
        end
    end

    for _, wanted in ipairs({"displayname", "itemname", "weaponname", "itemtype", "tooltype", "displaytext", "title", "name"}) do
        for _, child in ipairs(descendants) do
            if string.lower(child.Name) == wanted then
                if child:IsA("StringValue") then
                    local cleaned = clean(child.Value)
                    if cleaned then return cleaned end
                elseif child:IsA("TextLabel") or child:IsA("TextButton") then
                    local ok, text = pcall(function() return child.Text end)
                    local cleaned = ok and clean(text) or nil
                    if cleaned then return cleaned end
                end
            end
        end
    end

    for _, child in ipairs(descendants) do
        if child:IsA("StringValue") then
            local cleaned = clean(child.Value)
            if cleaned then return cleaned end
        end
    end

    -- Mesh names such as Ammo, Bat, Silencer or Wood are often the only
    -- readable identifier inside Last Stop's nested Item model.
    for _, child in ipairs(descendants) do
        if child:IsA("MeshPart") or child:IsA("Part") or child:IsA("UnionOperation") then
            local cleaned = clean(child.Name)
            if cleaned then return cleaned end
        end
    end

    return clean(object.Name) or "Unidentified loot"
end

state.getItemIdentityText = function(object)
    if not object then return "" end
    local values, seen = {}, {}
    local function add(value)
        local cleaned = state.cleanDisplayValue(value)
        if cleaned then
            local lower = string.lower(cleaned)
            if not seen[lower] then
                seen[lower] = true
                table.insert(values, lower)
            end
        end
    end
    add(object.Name)
    if object:IsA("Tool") then pcall(function() add(object.ToolTip) end) end

    local function addAttributes(instance)
        local ok, attributes = pcall(function() return instance:GetAttributes() end)
        if ok and type(attributes) == "table" then
            for key, value in pairs(attributes) do
                if hasAny(string.lower(tostring(key)), {"name", "type", "item", "weapon", "display", "title"}) then
                    add(value)
                end
            end
        end
    end
    addAttributes(object)

    local descendants = {}
    pcall(function() descendants = object:GetDescendants() end)
    for index, child in ipairs(descendants) do
        if child:IsA("StringValue") then add(child.Value) end
        if child:IsA("TextLabel") or child:IsA("TextButton") then
            local ok, text = pcall(function() return child.Text end)
            if ok and type(text) == "string" then
                for line in string.gmatch(text, "[^\r\n]+") do add(line) end
            end
        end
        addAttributes(child)
        if child:IsA("MeshPart") or child:IsA("Part") or child:IsA("UnionOperation") then
            add(child.Name)
        end
        if index >= 72 then break end
    end
    return table.concat(values, " ")
end

local function classify(instance)
    local ownName = string.lower(instance.Name)
    -- Vehicle hardware and large interactable structures are not loose loot.
    if hasAny(ownName, {"wheel", "tire", "tyre", "rim", "hubcap", "building", "bus", "vehicle", "truck", "garage", "chassis"}) then
        return nil
    end
    local context = getContextName(instance)

    local ok, tags = pcall(function()
        return CollectionService:GetTags(instance)
    end)
    if ok then
        for _, tag in ipairs(tags) do
            local tagName = string.lower(tag)
            if hasAny(tagName, bossWords) then
                return "boss"
            elseif hasAny(tagName, zombieWords) then
                return "zombie"
            elseif hasAny(tagName, lootWords) then
                return "loot"
            end
        end
    end

    if hasAny(context, bossWords) then
        return "boss"
    end
    if hasAny(context, zombieWords) then
        return "zombie"
    end
    if hasAny(context, lootWords) then
        return "loot"
    end

    local parentName = instance.Parent and string.lower(instance.Parent.Name) or ""
    if hasAny(parentName, lootFolderWords) then
        return "loot"
    end

    if instance:IsA("Tool") then
        return "loot"
    end

    if instance:IsA("Model") and instance:FindFirstChildWhichIsA("Humanoid", true)
        and hasAny(context, {"npc", "enemy", "hostile"}) then
        return "zombie"
    end

    return nil
end

local function classifyAura(instance)
    local context = instance and instance:IsA("Model")
        and state.getLastStopEntityContext(instance) or getContextName(instance)
    if hasAny(context, friendlyWords) then
        return nil
    end

    -- Dead Rails-derived NPCs can identify themselves with EntityName/Bounty
    -- attributes instead of descriptive Model names.
    local entityName = nil
    local bountyValue = nil
    pcall(function()
        entityName = instance:GetAttribute("EntityName")
        bountyValue = instance:GetAttribute("Bounty")
    end)
    if type(entityName) == "string" and entityName ~= "" then
        local loweredEntityName = string.lower(entityName)
        if hasAny(loweredEntityName, friendlyWords) then
            return nil
        elseif hasAny(loweredEntityName, bossWords) then
            return "boss"
        elseif hasAny(loweredEntityName, zombieWords) then
            return "zombie"
        end
    end
    if bountyValue ~= nil and bountyValue ~= false and bountyValue ~= 0 and bountyValue ~= "" then
        return "zombie"
    end
    local attributeAncestor = instance.Parent
    for _ = 1, 7 do
        if not attributeAncestor or attributeAncestor == Workspace then
            break
        end
        local okBounty, ancestorBounty = pcall(function()
            return attributeAncestor:GetAttribute("Bounty")
        end)
        if okBounty and ancestorBounty ~= nil and ancestorBounty ~= false
            and ancestorBounty ~= 0 and ancestorBounty ~= "" then
            return "zombie"
        end
        attributeAncestor = attributeAncestor.Parent
    end

    local ok, tags = pcall(function()
        return CollectionService:GetTags(instance)
    end)
    if ok then
        for _, tag in ipairs(tags) do
            local tagName = string.lower(tag)
            if hasAny(tagName, bossWords) then
                return "boss"
            elseif hasAny(tagName, zombieWords) then
                return "zombie"
            end
        end
    end

    if hasAny(context, bossWords) then
        return "boss"
    end
    if hasAny(context, zombieWords) then
        return "zombie"
    end
    if hasAny(context, {"enemies", "hostiles", "zombies", "bandits", "guards", "soldiers", "bosses", "mobs"}) then
        return "zombie"
    end

    return nil
end

local function isPlayerCharacter(instance)
    local current = instance
    while current and current ~= Workspace do
        if current:IsA("Model") and Players:GetPlayerFromCharacter(current) ~= nil then
            return true
        end
        current = current.Parent
    end
    return false
end

local function getRootPart(instance)
    if instance:IsA("BasePart") then
        return instance
    end

    if instance:IsA("Tool") then
        local handle = instance:FindFirstChild("Handle")
        if handle and handle:IsA("BasePart") then return handle end
        local directPart = instance:FindFirstChildWhichIsA("BasePart")
        if directPart then return directPart end
        -- Last Stop world Tools may wrap their physical part inside a Folder/Model.
        return instance:FindFirstChildWhichIsA("BasePart", true)
    end

    if instance:IsA("Model") then
        if instance.PrimaryPart then
            return instance.PrimaryPart
        end

        local preferred = instance:FindFirstChild("HumanoidRootPart", true)
            or instance:FindFirstChild("RootPart", true)
            or instance:FindFirstChild("Root", true)
            or instance:FindFirstChild("Hitbox", true)
            or instance:FindFirstChild("Torso", true)
            or instance:FindFirstChild("UpperTorso", true)
            or instance:FindFirstChild("Head", true)

        if preferred and preferred:IsA("BasePart") then
            return preferred
        end

        return instance:FindFirstChildWhichIsA("BasePart", true)
    end

    return nil
end

local meleeWords = {
    "shovel", "sword", "knife", "axe", "machete", "bat", "spear",
    "club", "crowbar", "pickaxe", "hammer", "melee", "katana",
    "scythe", "sledgehammer", "chainsaw", "pipe", "pitchfork", "tomahawk",
    "cleaver", "saber", "bayonet", "brass_knuckles", "wood_axe", "cane",
    "vampire_knife", "sickle", "fists", "baton", "rapier", "halberd", "mace"
}

local function isMeleeTool(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end

    local toolName = state.getItemIdentityText(tool)
    local ok, isMelee = pcall(function()
        return tool:GetAttribute("IsMelee")
    end)
    if ok and isMelee == true then
        return true
    end
    if tool:FindFirstChild("MeleeWeaponConfiguration", true) then
        return true
    end

    return hasAny(toolName, meleeWords)
end

local function getEquippedMeleeTool(character)
    if not character then
        return nil
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Tool") and isMeleeTool(child) then
            return child
        end
    end

    return nil
end

local function readToolNumber(tool, key)
    local ok, attribute = pcall(function()
        return tool:GetAttribute(key)
    end)
    if ok and type(attribute) == "number" then
        return attribute
    end

    local valueObject = tool:FindFirstChild(key)
    if valueObject and (valueObject:IsA("NumberValue") or valueObject:IsA("IntValue")) then
        return valueObject.Value
    end
    return nil
end

local function getMeleeToolScore(tool)
    local damage = readToolNumber(tool, "MeleeDamage")
        or readToolNumber(tool, "Damage")
        or readToolNumber(tool, "BaseDamage")
        or readToolNumber(tool, "Power")

    local name = state.getItemIdentityText(tool)
    local nameScore = 1
    local priorities = {
        {"chainsaw", 12}, {"katana", 11}, {"sword", 10}, {"axe", 9},
        {"machete", 9}, {"spear", 8}, {"pickaxe", 7}, {"crowbar", 7},
        {"shovel", 6}, {"bat", 6}, {"knife", 5}, {"hammer", 5}
    }
    for _, entry in ipairs(priorities) do
        if string.find(name, entry[1], 1, true) then
            nameScore = entry[2]
            break
        end
    end

    return (damage or 0) * 100 + nameScore
end

local function getBestMeleeTool(character)
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local bestTool = nil
    local bestScore = -math.huge

    local function consider(container)
        if not container then
            return
        end
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") and isMeleeTool(child) then
                local score = getMeleeToolScore(child)
                if score > bestScore then
                    bestScore = score
                    bestTool = child
                end
            end
        end
    end

    consider(character)
    consider(backpack)
    return bestTool
end

local function findMeleeVisual(character)
    if not character then
        return nil
    end

    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("Model") or object:IsA("BasePart") then
            local name = state.getItemIdentityText(object)
            if hasAny(name, meleeWords) and not object:FindFirstAncestorOfClass("Tool") then
                return object
            end
        end
    end

    return nil
end

local cachedMeleeVisualCharacter = nil
local cachedMeleeVisual = nil
local cachedMeleeVisualAt = 0
local function getCachedMeleeVisual(character)
    if character ~= cachedMeleeVisualCharacter or os.clock() - cachedMeleeVisualAt >= 0.5 then
        cachedMeleeVisualCharacter = character
        cachedMeleeVisual = findMeleeVisual(character)
        cachedMeleeVisualAt = os.clock()
    end
    return cachedMeleeVisual
end

local swingPromptCache = false
local swingPromptWeaponCache = nil
local swingPromptCacheAt = 0
local function getSwingPromptInfo()
    if os.clock() - swingPromptCacheAt < 0.4 then
        return swingPromptCache, swingPromptWeaponCache
    end

    swingPromptCacheAt = os.clock()
    swingPromptCache = false
    swingPromptWeaponCache = nil

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return false, nil
    end

    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            local ok, text = pcall(function()
                return object.Text
            end)
            if ok and type(text) == "string" then
                local lowerText = string.lower(text)
                if string.find(lowerText, "swing", 1, true) then
                    swingPromptCache = true
                end
                if not swingPromptWeaponCache then
                    for _, word in ipairs(meleeWords) do
                        if string.find(lowerText, word, 1, true) then
                            swingPromptWeaponCache = string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
                            break
                        end
                    end
                end
                if swingPromptCache and swingPromptWeaponCache then
                    break
                end
            end
        end
    end

    return swingPromptCache, swingPromptWeaponCache
end

local function getMeleeReady(character)
    local tool = getEquippedMeleeTool(character)
    if tool then
        return true, tool.Name, tool
    end

    local visual = getCachedMeleeVisual(character)
    if visual then
        return true, visual.Name .. " (character model)", nil
    end

    -- Last Stop exposes its melee action as a live "Swing" prompt. The item
    -- can be represented by the game's own hotbar system rather than a Tool.
    local hasPrompt, uiWeaponName = getSwingPromptInfo()
    if hasPrompt then
        -- Last Stop's hotbar can equip a GUID-named Tool with no Dead Rails
        -- MeleeWeaponConfiguration/SwingEvent descendants. If exactly one Tool
        -- is equipped, retain it for Tool:Activate/input fallback instead of nil.
        local onlyEquippedTool = nil
        local equippedToolCount = 0
        if character then
            for _, child in ipairs(character:GetChildren()) do
                if child:IsA("Tool") then
                    equippedToolCount = equippedToolCount + 1
                    onlyEquippedTool = child
                end
            end
        end
        if equippedToolCount ~= 1 then
            onlyEquippedTool = nil
        end
        local displayName = uiWeaponName or (onlyEquippedTool and onlyEquippedTool.Name) or "Melee"
        return true, displayName .. " (Swing prompt)", onlyEquippedTool
    end

    return false, "No melee / Swing prompt detected", nil
end

local mousePress = env.mouse1press
local mouseRelease = env.mouse1release
local mouseClick = env.mouse1click
if type(mousePress) ~= "function" then
    pcall(function()
        mousePress = mouse1press
    end)
end
if type(mouseRelease) ~= "function" then
    pcall(function()
        mouseRelease = mouse1release
    end)
end
if type(mouseClick) ~= "function" then
    pcall(function()
        mouseClick = mouse1click
    end)
end

local virtualInput
pcall(function()
    virtualInput = game:GetService("VirtualInputManager")
end)

local attackInputHeld = false
local attackInputKind = "idle"
local attackInputPosition = nil

local function releaseAuraInput()
    if not attackInputHeld then
        currentAuraInput = "idle"
        return
    end

    if attackInputKind == "executor hold" and type(mouseRelease) == "function" then
        pcall(mouseRelease)
    elseif attackInputKind == "virtual hold" and virtualInput and attackInputPosition then
        pcall(function()
            virtualInput:SendMouseButtonEvent(
                attackInputPosition.X,
                attackInputPosition.Y,
                0,
                false,
                game,
                0
            )
        end)
    end

    attackInputHeld = false
    attackInputKind = "idle"
    attackInputPosition = nil
    currentAuraInput = "idle"
end

releaseAuraInputCallback = releaseAuraInput
track(UserInputService.WindowFocusReleased:Connect(function()
    releaseAuraInput()
end))

local function isScreenPointOverToolkit(x, y)
    if not gui or not gui.Enabled then
        return false
    end

    local function containsPoint(frame)
        if not frame or not frame.Visible then
            return false
        end
        local position = frame.AbsolutePosition
        local size = frame.AbsoluteSize
        return x >= position.X and x <= position.X + size.X
            and y >= position.Y and y <= position.Y + size.Y
    end

    return containsPoint(mainFrame) or containsPoint(hudFrame)
end

local function isPointerOverToolkit()
    local mousePosition = UserInputService:GetMouseLocation()
    return isScreenPointOverToolkit(mousePosition.X, mousePosition.Y)
end

-- Dead Rails-derived combat adapters. Two public implementations expose
-- different but related protocols: state.replicatedStorage.Shared.Universe.Network
-- .RemoteEvent.SwingMelee(tool, os.clock(), direction), and Tool.SwingEvent(direction).
-- Resolve only existing RemoteEvents; never invent or invoke unrelated remotes.

state.getGlobalSwingRemote = function()
    if game.GameId == 10759337137 then
        return nil, nil
    end
    if state.cachedGlobalSwingRemote and state.cachedGlobalSwingRemote.Parent then
        return state.cachedGlobalSwingRemote, state.cachedGlobalSwingPath
    end
    if os.clock() - state.lastGlobalSwingRemoteScan < 2 then
        return nil, nil
    end
    state.lastGlobalSwingRemoteScan = os.clock()

    local shared = state.replicatedStorage:FindFirstChild("Shared")
    local universe = shared and shared:FindFirstChild("Universe")
    local universeNetwork = universe and universe:FindFirstChild("Network")
    local universeEvents = universeNetwork and universeNetwork:FindFirstChild("RemoteEvent")
    local candidate = universeEvents and universeEvents:FindFirstChild("SwingMelee")
    if candidate and candidate:IsA("RemoteEvent") then
        state.cachedGlobalSwingRemote = candidate
        state.cachedGlobalSwingPath = "Shared.Universe.Network.RemoteEvent.SwingMelee"
        return candidate, state.cachedGlobalSwingPath
    end

    local sharedNetwork = shared and shared:FindFirstChild("Network")
    local sharedEvents = sharedNetwork and sharedNetwork:FindFirstChild("RemoteEvent")
    candidate = sharedEvents and sharedEvents:FindFirstChild("SwingMelee")
    if candidate and candidate:IsA("RemoteEvent") then
        state.cachedGlobalSwingRemote = candidate
        state.cachedGlobalSwingPath = "Shared.Network.RemoteEvent.SwingMelee"
        return candidate, state.cachedGlobalSwingPath
    end

    -- Last-resort discovery for a renamed hierarchy, limited to this exact event name.
    local ok, descendants = pcall(function()
        return state.replicatedStorage:GetDescendants()
    end)
    if ok then
        for _, object in ipairs(descendants) do
            if object:IsA("RemoteEvent") and object.Name == "SwingMelee" then
                state.cachedGlobalSwingRemote = object
                state.cachedGlobalSwingPath = object:GetFullName()
                return object, state.cachedGlobalSwingPath
            end
        end
    end
    return nil, nil
end

state.resolveMeleeRemote = function(tool)
    local globalRemote, globalPath = state.getGlobalSwingRemote()
    if globalRemote then
        return globalRemote, "SwingMelee: " .. tostring(globalPath), "global"
    end

    if tool and tool.Parent then
        local toolRemote = tool:FindFirstChild("SwingEvent", true)
        if toolRemote and toolRemote:IsA("RemoteEvent") then
            return toolRemote, "Tool.SwingEvent", "tool"
        end
    end
    return nil, "Input fallback", "fallback"
end

state.sendNativeMelee = function(tool, targetRoot, characterRoot)
    if not characterRoot then
        return false, "Missing character root"
    end
    if not tool then
        return false, "Last Stop Swing input only; no Tool object for remote adapter"
    end

    local remote, apiName, apiKind = state.resolveMeleeRemote(tool)
    if not remote then
        state.currentAuraApi = game.GameId == 10759337137
            and "Last Stop: no public swing remote; input only" or "No compatible swing remote"
        return false, apiName
    end

    -- Dead Rails' public Auto Swing loop sends a native swing every 0.01s
    -- using the camera direction, even when it has no local target candidate.
    -- When a target is known, prefer its direction; otherwise use camera-forward.
    local direction
    if targetRoot and targetRoot.Parent then
        local offset = targetRoot.Position - characterRoot.Position
        if offset.Magnitude > 0.001 then
            direction = offset.Unit
        end
    end
    if not direction then
        local camera = Workspace.CurrentCamera
        direction = camera and camera.CFrame.LookVector or characterRoot.CFrame.LookVector
    end

    local ok, err = pcall(function()
        if apiKind == "tool" then
            remote:FireServer(direction)
        else
            remote:FireServer(tool, os.clock(), direction)
        end
    end)

    if not ok then
        state.currentAuraApi = apiName .. " failed"
        return false, tostring(err)
    end

    state.currentAuraApi = apiName
    currentAuraInput = "remote request"
    auraAttackAttempts = auraAttackAttempts + 1
    return true, apiName
end

local function beginAuraAttack(tool, targetRoot, characterRoot)
    if not targetRoot or not targetRoot.Parent then
        return false, "Target unavailable"
    end

    -- Prefer the game's own melee request. It does not require a visible target,
    -- cursor movement, camera animation, or local character translation.
    local nativeSent, nativeResult = state.sendNativeMelee(tool, targetRoot, characterRoot)
    if nativeSent then
        return true, nativeResult
    end

    -- Fallback only: normal simulated input is screen-bound and short-range.
    if isPointerOverToolkit() then
        return false, "Move cursor off toolkit"
    end

    local camera = Workspace.CurrentCamera
    if virtualInput and camera then
        local point, onScreen = camera:WorldToScreenPoint(targetRoot.Position)
        if not onScreen or isScreenPointOverToolkit(point.X, point.Y) then
            return false, "Fallback target not on screen"
        end

        local previousMouse = nil
        pcall(function()
            previousMouse = UserInputService:GetMouseLocation()
        end)

        local downOk = pcall(function()
            virtualInput:SendMouseMoveEvent(point.X, point.Y, game)
            virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, true, game, 0)
        end)
        if not downOk then
            return false, "Fallback input failed"
        end

        task.wait(0.01)
        local upOk = pcall(function()
            virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
        end)
        if not upOk then
            pcall(function()
                virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
            end)
            return false, "Fallback release failed"
        end
        if previousMouse then
            pcall(function()
                virtualInput:SendMouseMoveEvent(previousMouse.X, previousMouse.Y, game)
            end)
        end

        attackInputHeld = false
        attackInputKind = "idle"
        attackInputPosition = nil
        currentAuraInput = "click fallback"
        state.currentAuraApi = "Input fallback"
        auraAttackAttempts = auraAttackAttempts + 1
        return true, "Input fallback"
    end

    if type(mouseClick) == "function" then
        local ok = pcall(mouseClick)
        if ok then
            currentAuraInput = "executor click fallback"
            state.currentAuraApi = "Input fallback"
            auraAttackAttempts = auraAttackAttempts + 1
            return true, "Input fallback"
        end
    end

    if tool then
        local ok = pcall(function()
            tool:Activate()
        end)
        if ok then
            currentAuraInput = "Tool:Activate fallback"
            state.currentAuraApi = "Input fallback"
            auraAttackAttempts = auraAttackAttempts + 1
            return true, "Input fallback"
        end
    end

    return false, "No usable melee API or input"
end


local targetHealthValueCache = setmetatable({}, {__mode = "k"})
local targetHealthScanAt = setmetatable({}, {__mode = "k"})

state.markAuraDead = function(model)
    if not model then
        return
    end
    state.deadAuraBlacklist[model] = true
    auraCandidates[model] = nil
    if state.currentAuraTargetInstance == model then
        state.currentAuraTargetInstance = nil
        currentAuraTargetName = "--"
        currentAuraStatus = "Dead target ignored"
        combatTargetActive = false
        releaseAuraInput()
    end
end

local function getTargetHealth(model)
    if not model then
        return nil
    end

    local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        return humanoid.Health
    end

    local attributeNames = {"Health", "HP", "CurrentHealth", "CurrentHP", "HitPoints", "health", "hp"}
    for _, key in ipairs(attributeNames) do
        local ok, value = pcall(function()
            return model:GetAttribute(key)
        end)
        if ok and type(value) == "number" then
            return value
        end
    end

    local cachedValue = targetHealthValueCache[model]
    if cachedValue and cachedValue.Parent then
        local value = tonumber(cachedValue.Value)
        if value ~= nil then
            return value
        end
    end
    if cachedValue == false and os.clock() - (targetHealthScanAt[model] or 0) < 1 then
        return nil
    end

    targetHealthScanAt[model] = os.clock()
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("NumberValue") or object:IsA("IntValue") or object:IsA("StringValue") then
            local name = string.lower(object.Name)
            if hasAny(name, {"health", "hp", "currenthealth", "currenthp", "hitpoints"}) then
                local value = tonumber(object.Value)
                if value ~= nil then
                    targetHealthValueCache[model] = object
                    return value
                end
            end
        elseif object:IsA("TextLabel") or object:IsA("TextButton") then
            local name = string.lower(object.Name)
            if hasAny(name, {"health", "hp"}) then
                local ok, text = pcall(function() return object.Text end)
                if ok and type(text) == "string" then
                    local current = string.match(text, "([%-]?%d+%.?%d*)%s*/")
                    if current then
                        local value = tonumber(current)
                        if value ~= nil then
                            return value
                        end
                    end
                end
            end
        end
    end

    targetHealthValueCache[model] = false
    return nil
end

local function isTargetDead(model)
    if not model or not model.Parent then
        return true
    end
    if state.deadAuraBlacklist[model] then
        return true
    end

    local context = state.getLastStopEntityContext(model)
    if hasAny(context, {"corpse", "ragdoll", "dead body", "deadbody", "zombie corpse", "dead npc", "deathstate"}) then
        state.markAuraDead(model)
        return true
    end

    for _, attributeName in ipairs({"Dead", "IsDead", "Died", "Death", "IsRagdoll", "Ragdolled", "Alive", "IsAlive"}) do
        local ok, value = pcall(function()
            return model:GetAttribute(attributeName)
        end)
        if ok then
            if ((attributeName == "Dead" or attributeName == "IsDead" or attributeName == "Died"
                or attributeName == "Death" or attributeName == "IsRagdoll" or attributeName == "Ragdolled")
                and (value == true or value == 1)) then
                state.markAuraDead(model)
                return true
            end
            if (attributeName == "Alive" or attributeName == "IsAlive")
                and (value == false or value == 0) then
                state.markAuraDead(model)
                return true
            end
        end
    end

    for _, stateAttribute in ipairs({"State", "Status", "LifeState", "AIState", "DeathState"}) do
        local ok, value = pcall(function() return model:GetAttribute(stateAttribute) end)
        if ok and type(value) == "string"
            and hasAny(string.lower(value), {"dead", "death", "corpse", "ragdoll", "destroyed"}) then
            state.markAuraDead(model)
            return true
        end
    end

    for _, valueName in ipairs({"Dead", "IsDead", "Died", "Death", "IsRagdoll", "Ragdolled", "Alive", "IsAlive"}) do
        local valueObject = model:FindFirstChild(valueName, true)
        if valueObject and valueObject:IsA("BoolValue") then
            if valueName ~= "Alive" and valueName ~= "IsAlive" and valueObject.Value then
                state.markAuraDead(model)
                return true
            end
            if (valueName == "Alive" or valueName == "IsAlive") and not valueObject.Value then
                state.markAuraDead(model)
                return true
            end
        end
    end

    for _, stateName in ipairs({"State", "Status", "LifeState", "AIState", "DeathState"}) do
        local valueObject = model:FindFirstChild(stateName, true)
        if valueObject and valueObject:IsA("StringValue")
            and hasAny(string.lower(valueObject.Value), {"dead", "death", "corpse", "ragdoll", "destroyed"}) then
            state.markAuraDead(model)
            return true
        end
    end

    local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        if humanoid.Health <= 0 then
            state.markAuraDead(model)
            return true
        end
        local ok, humanoidState = pcall(function()
            return humanoid:GetState()
        end)
        if ok and humanoidState == Enum.HumanoidStateType.Dead then
            state.markAuraDead(model)
            return true
        end
    end

    local health = getTargetHealth(model)
    if health ~= nil and health <= 0 then
        state.markAuraDead(model)
        return true
    end

    if state.lastEntityKilledAt > 0 and os.clock() - state.lastEntityKilledAt <= 1.5
        and state.lastDamagePosition and os.clock() - state.lastDamageEventAt <= 1.5 then
        local killedType = string.lower(state.lastEntityKilledType or "")
        local modelContext = state.getLastStopEntityContext(model)
        local root = getRootPart(model)
        if root and killedType ~= "" and hasAny(modelContext, {killedType})
            and (root.Position - state.lastDamagePosition).Magnitude <= 10 then
            state.markAuraDead(model)
            return true
        end
    end

    if state.isLastStopEntityRoot(model) then
        local motors, ballSockets, animators, playingTracks = state.getEntityRigEvidence(model)
        -- Captured Last Stop corpses had multiple BallSocketConstraints and
        -- zero playing tracks; live zombie rigs had no BallSockets and active tracks.
        if ballSockets >= 3 and playingTracks == 0 and motors <= 8 then
            state.markAuraDead(model)
            return true
        end
    end
    return false
end

state.hasTargetAliveSignal = function(model)
    if not model then
        return false
    end
    if getTargetHealth(model) ~= nil then
        return true
    end

    for _, attributeName in ipairs({"Alive", "IsAlive"}) do
        local ok, value = pcall(function() return model:GetAttribute(attributeName) end)
        if ok and value == true then
            return true
        end
    end

    for _, valueName in ipairs({"Alive", "IsAlive"}) do
        local valueObject = model:FindFirstChild(valueName, true)
        if valueObject and valueObject:IsA("BoolValue") and valueObject.Value then
            return true
        end
    end

    -- Last Stop's custom NPCs are rooted in ENTITY_CONTAINER and often have
    -- no Humanoid/Health object. Treat a non-ragdolled entity rig as observable.
    if state.isLastStopEntityRoot(model) then
        local motors, ballSockets, animators, playingTracks = state.getEntityRigEvidence(model)
        if motors >= 2 or playingTracks > 0 then
            return true
        end
        if motors == 0 and ballSockets >= 3 then
            state.markAuraDead(model)
            return false
        end
        local entityContainer = state.getLastStopEntityContainer()
        if entityContainer and model.Parent == entityContainer then
            return true
        end
    end
    return false
end

state.bindAuraDeathSignals = function(model)
    if not model or state.auraDeathConnections[model] then
        return
    end

    local modelConnections = {}
    local watchedObjects = setmetatable({}, {__mode = "k"})
    state.auraDeathConnections[model] = modelConnections
    local function add(connection)
        if connection then
            table.insert(modelConnections, connection)
        end
    end
    local function checkDeath()
        if model.Parent and isTargetDead(model) then
            state.markAuraDead(model)
        end
    end

    for _, attributeName in ipairs({"Dead", "IsDead", "Died", "Death", "IsRagdoll", "Ragdolled", "Alive", "IsAlive", "Health", "HP", "CurrentHealth", "CurrentHP", "HitPoints", "State", "Status", "LifeState", "AIState", "DeathState"}) do
        local ok, signal = pcall(function()
            return model:GetAttributeChangedSignal(attributeName)
        end)
        if ok and signal then
            add(signal:Connect(checkDeath))
        end
    end

    local function watchObject(object)
        if not object or watchedObjects[object] then
            return
        end
        watchedObjects[object] = true

        if object:IsA("Humanoid") then
            add(object.Died:Connect(function()
                state.markAuraDead(model)
            end))
            add(object.HealthChanged:Connect(function(health)
                if health <= 0 then
                    state.markAuraDead(model)
                end
            end))
            return
        end

        local name = string.lower(object.Name)
        if object:IsA("BoolValue") or object:IsA("StringValue")
            or object:IsA("NumberValue") or object:IsA("IntValue") then
            if hasAny(name, {"dead", "alive", "health", "hp", "state", "status", "life", "death", "ragdoll"}) then
                if hasAny(name, {"health", "hp", "currenthealth", "currenthp", "hitpoints"}) then
                    targetHealthValueCache[model] = object
                end
                add(object.Changed:Connect(checkDeath))
            end
        end
    end

    for _, object in ipairs(model:GetDescendants()) do
        watchObject(object)
    end
    add(model.DescendantAdded:Connect(function(object)
        state.entityContextCache[model] = nil
        state.entityRigCache[model] = nil
        watchObject(object)
        if object:IsA("BallSocketConstraint") then
            task.defer(checkDeath)
        end
    end))
    add(model.DescendantRemoving:Connect(function(object)
        state.entityContextCache[model] = nil
        state.entityRigCache[model] = nil
        if object:IsA("Humanoid") and object.Health <= 0 then
            state.markAuraDead(model)
        elseif object:IsA("Motor6D") or object:IsA("Animator") then
            task.defer(checkDeath)
        end
    end))

    checkDeath()
end

local function findAuraModel(instance)
    -- Prefer the complete model directly parented to Last Stop's entity container.
    -- This prevents a body part such as Dress.GuardPolice.Torso becoming a target.
    local lastStopRoot = state.getLastStopEntityRoot(instance)
    if lastStopRoot then
        return lastStopRoot
    end

    local current = instance
    local hostilePart = nil
    local classifiedModel = nil
    local healthModel = nil
    local highestModel = nil

    while current and current ~= Workspace do
        if current:IsA("Model") and getRootPart(current) then
            highestModel = current
            local context = state.getLastStopEntityContext(current)
            if not hasAny(context, friendlyWords) then
                local hasHumanoid = current:FindFirstChildWhichIsA("Humanoid", true) ~= nil
                local hasHealth = getTargetHealth(current) ~= nil
                local kind = classifyAura(current)
                if (hasHumanoid or hasHealth) and not healthModel then
                    healthModel = current
                elseif kind and not classifiedModel then
                    classifiedModel = current
                end
            end
        elseif current:IsA("BasePart") then
            local context = getContextName(current)
            if hasAny(context, zombieWords) or hasAny(context, bossWords) then
                hostilePart = current
            end
        end
        current = current.Parent
    end

    if highestModel then
        local context = state.getLastStopEntityContext(highestModel)
        if hasAny(context, zombieWords) or hasAny(context, bossWords) then
            return highestModel
        end
    end
    return healthModel or classifiedModel or hostilePart
end

local function registerAuraCandidate(instance)
    local model = findAuraModel(instance)
    if not model or isPlayerCharacter(model) or state.deadAuraBlacklist[model] then
        return
    end

    state.bindAuraDeathSignals(model)
    if isTargetDead(model) then
        auraCandidates[model] = nil
        return
    end

    local context = state.getLastStopEntityContext(model)
    if hasAny(context, friendlyWords) then
        auraCandidates[model] = nil
        return
    end

    local kind = classifyAura(model)
    if kind then
        auraCandidates[model] = kind
        return
    end

    local hasHumanoid = model:FindFirstChildWhichIsA("Humanoid", true) ~= nil
    local hasHealth = getTargetHealth(model) ~= nil
    local isNpcContainer = hasAny(context, npcContainerWords) or state.isLastStopEntityRoot(model)
    if hasHumanoid or hasHealth or isNpcContainer then
        auraCandidates[model] = "unknown"
    else
        auraCandidates[model] = nil
    end
end

local function queueAuraRegistration(instance)
    local model = findAuraModel(instance)
    if not model and (instance:IsA("Model") or instance:IsA("BasePart")) then
        model = instance
    end

    if not model or auraRegistrationPending[model] then
        return
    end

    auraRegistrationPending[model] = true
    task.delay(0.15, function()
        auraRegistrationPending[model] = nil
        if state.running and model.Parent then
            registerAuraCandidate(model)
        end
    end)
end

local function getNearestAuraTarget(characterRoot)
    local bestModel = nil
    local bestRoot = nil
    local bestKind = nil
    local bestDistance = state.auraRange
    state.auraUnverifiedCount = 0

    for model in pairs(auraCandidates) do
        if not model or not model.Parent then
            auraCandidates[model] = nil
        else
            local root = getRootPart(model)
            local context = state.getLastStopEntityContext(model)

            if not root or isPlayerCharacter(model) or isTargetDead(model)
                or hasAny(context, friendlyWords) then
                auraCandidates[model] = nil
            else
                local kind = auraCandidates[model]
                if kind == "unknown" or not kind then
                    local classified = classifyAura(model)
                    if classified then
                        kind = classified
                    elseif state.auraAllNPCs then
                        kind = "unknown"
                    end
                end

                if kind then
                    auraCandidates[model] = kind
                    local shouldTarget = kind == "zombie"
                        or (kind == "boss" and state.auraBosses)
                        or (kind == "unknown" and state.auraAllNPCs)

                    if shouldTarget then
                        if not state.hasTargetAliveSignal(model) then
                            -- Unknown custom rigs without any observable health/alive
                            -- state are unsafe to attack: they may be lingering corpses.
                            state.auraUnverifiedCount = state.auraUnverifiedCount + 1
                        else
                            local distance = (root.Position - characterRoot.Position).Magnitude
                            if distance <= bestDistance then
                                bestDistance = distance
                                bestModel = model
                                bestRoot = root
                                bestKind = kind
                            end
                        end
                    end
                else
                    auraCandidates[model] = "unknown"
                end
            end
        end
    end

    return bestModel, bestRoot, bestKind, bestDistance
end

local function faceAuraTarget(character, targetRoot)
    if not state.auraFace or not character or not targetRoot then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart or not root then
        return
    end

    local targetPosition = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
    if (targetPosition - root.Position).Magnitude > 0.1 then
        pcall(function()
            root.CFrame = CFrame.lookAt(root.Position, targetPosition)
        end)
    end
end

local function aimAuraCamera(targetRoot)
    if not state.auraAimCamera or not targetRoot then
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    local cameraPosition = camera.CFrame.Position
    local direction = targetRoot.Position - cameraPosition
    if direction.Magnitude < 0.1 then
        return
    end

    pcall(function()
        local desired = CFrame.lookAt(cameraPosition, targetRoot.Position, camera.CFrame.UpVector)
        camera.CFrame = camera.CFrame:Lerp(desired, 0.35)
    end)
end

local function getMarkerColor(kind, instance)
    if kind == "boss" then
        return Color3.fromRGB(255, 75, 85)
    elseif kind == "zombie" then
        return Color3.fromRGB(255, 145, 75)
    elseif kind == "player" then
        return Color3.fromRGB(90, 170, 255)
    end

    local name = string.lower(state.getItemIdentityText(instance))
    if hasAny(name, {"key", "cure", "quest", "potion"}) then
        return Color3.fromRGB(190, 125, 255)
    elseif hasAny(name, {"ammo", "weapon", "gun", "rifle", "pistol"}) then
        return Color3.fromRGB(255, 175, 80)
    elseif hasAny(name, {"fuel", "gas", "wheel", "tire", "battery"}) then
        return Color3.fromRGB(90, 205, 235)
    elseif hasAny(name, {"med", "bandage", "food", "water"}) then
        return Color3.fromRGB(105, 225, 145)
    end

    return Color3.fromRGB(245, 215, 100)
end

local function isEnabled(kind)
    if kind == "loot" then
        return state.loot
    elseif kind == "zombie" then
        return state.zombies
    elseif kind == "boss" then
        return state.bosses
    elseif kind == "player" then
        return state.players
    end
    return false
end

local function createMarker(instance, kind, displayName)
    local root = getRootPart(instance)
    if not root then
        return nil
    end

    local color = getMarkerColor(kind, instance)
    local adornee = instance:IsA("Model") and instance or root

    local highlight = make("Highlight", {
        Name = "LST_ESP_Highlight",
        Adornee = adornee,
        FillColor = color,
        OutlineColor = color,
        FillTransparency = 0.78,
        OutlineTransparency = 0.08,
        DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
        Enabled = true,
    }, Workspace)

    local billboard = make("BillboardGui", {
        Name = "LST_ESP_Label",
        Adornee = root,
        Size = UDim2.new(0, 190, 0, 28),
        StudsOffset = Vector3.new(0, 2.8, 0),
        AlwaysOnTop = true,
        LightInfluence = 0,
        MaxDistance = state.maxDistance,
        Enabled = true,
    }, Workspace)

    local label = make("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = displayName,
        TextColor3 = color,
        TextStrokeColor3 = Color3.fromRGB(10, 10, 10),
        TextStrokeTransparency = 0.2,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, billboard)

    return {
        highlight = highlight,
        billboard = billboard,
        label = label,
        root = root,
        kind = kind,
        displayName = displayName,
    }
end

local function updateMarker(instance, marker, cameraPosition)
    if not instance or not instance.Parent then
        return false
    end

    local root = getRootPart(instance)
    if not root or not root.Parent then
        return false
    end

    marker.root = root
    marker.billboard.Adornee = root
    marker.highlight.Adornee = instance:IsA("Model") and instance or root

    local distance = (root.Position - cameraPosition).Magnitude
    local visible = isEnabled(marker.kind) and distance <= state.maxDistance

    marker.highlight.Enabled = visible
    marker.billboard.Enabled = visible
    marker.billboard.MaxDistance = state.maxDistance

    if state.distance then
        marker.label.Text = string.format("%s  [%.0fm]", marker.displayName, distance)
    else
        marker.label.Text = marker.displayName
    end

    return true
end

-- Build an event-driven NPC cache once, then update it as NPC models spawn/despawn.
for _, instance in ipairs(Workspace:GetDescendants()) do
    if instance:IsA("Model") then
        registerAuraCandidate(instance)
    elseif instance:IsA("BasePart") and not instance:FindFirstAncestorOfClass("Model") then
        registerAuraCandidate(instance)
    end
end

track(Workspace.DescendantAdded:Connect(queueAuraRegistration))
track(Workspace.DescendantRemoving:Connect(function(instance)
    if instance:IsA("Model") or instance:IsA("BasePart") then
        auraCandidates[instance] = nil
        auraRegistrationPending[instance] = nil
    end
    if instance:IsA("Model") then
        local modelConnections = state.auraDeathConnections[instance]
        if modelConnections then
            for _, connection in ipairs(modelConnections) do
                pcall(function() connection:Disconnect() end)
            end
            state.auraDeathConnections[instance] = nil
        end
        state.deadAuraBlacklist[instance] = nil
        targetHealthValueCache[instance] = nil
        targetHealthScanAt[instance] = nil
    end
end))

state.deadRailsToolRemoteCache = state.deadRailsToolRemoteCache or {}
state.getDeadRailsToolRemote = function(remoteName)
    if game.GameId == 10759337137 then
        return nil
    end
    local cached = state.deadRailsToolRemoteCache[remoteName]
    if cached and cached.Parent then return cached end

    local remotes = state.replicatedStorage:FindFirstChild("Remotes")
    local toolFolder = remotes and remotes:FindFirstChild("Tool")
    local candidate = toolFolder and toolFolder:FindFirstChild(remoteName)
    if candidate and candidate:IsA("RemoteEvent") then
        state.deadRailsToolRemoteCache[remoteName] = candidate
        return candidate
    end

    -- Fallback only to a unique exact-name match, never a partial remote name.
    -- Throttle negative scans because Kill Aura can ask for this adapter every tick.
    local lastScan = state.deadRailsToolRemoteScanAt[remoteName] or -math.huge
    if lastScan > 0 and os.clock() - lastScan < 3 then
        return nil
    end
    state.deadRailsToolRemoteScanAt[remoteName] = os.clock()
    local matches = {}
    for _, object in ipairs(state.replicatedStorage:GetDescendants()) do
        if object:IsA("RemoteEvent") and object.Name == remoteName then
            table.insert(matches, object)
            if #matches > 1 then break end
        end
    end
    if #matches == 1 then
        state.deadRailsToolRemoteCache[remoteName] = matches[1]
        return matches[1]
    end
    return nil
end

state.getDirectRuntimeItemsFolder = function()
    if game.GameId == 10759337137 then return nil end
    local direct = Workspace:FindFirstChild("RuntimeItems")
    if direct and (direct:IsA("Folder") or direct:IsA("Model")) then
        return direct
    end
    local cached = state.cachedRuntimeItemsFolder
    if cached and cached.Parent then return cached end
    return nil
end

state.rapidToolResetAvailable = function(tool)
    if not state.rapidToolResetMelee or not tool or not tool.Parent
        or not tool:FindFirstChild("MeleeWeaponConfiguration", true) then
        return false
    end
    return state.getDeadRailsToolRemote("DropTool") ~= nil
        and state.getDeadRailsToolRemote("PickUpTool") ~= nil
        and state.getDirectRuntimeItemsFolder() ~= nil
end

state.startRapidToolResetSwing = function(tool, targetRoot, characterRoot)
    if state.rapidMeleeBusy then return false, "Weapon reset busy" end
    if not state.rapidToolResetAvailable(tool) then return false, "DropTool/PickUpTool API unavailable" end
    if not targetRoot or not targetRoot.Parent or not characterRoot then return false, "Target unavailable" end
    local distance = (targetRoot.Position - characterRoot.Position).Magnitude
    if distance > 10 then return false, "Tool-reset reference only targets within about 10 studs" end

    local dropRemote = state.getDeadRailsToolRemote("DropTool")
    local pickupRemote = state.getDeadRailsToolRemote("PickUpTool")
    local runtimeItems = state.getDirectRuntimeItemsFolder()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if not dropRemote or not pickupRemote or not runtimeItems or not humanoid or not backpack then
        return false, "Tool-reset prerequisites missing"
    end

    state.rapidMeleeBusy = true
    task.spawn(function()
        local success, err = pcall(function()
            local weaponName = tool.Name
            if tool.Parent ~= character then
                local inBackpack = backpack:FindFirstChild(weaponName)
                if inBackpack and inBackpack:IsA("Tool") then
                    humanoid:EquipTool(inBackpack)
                    task.wait(0.05)
                    tool = character:FindFirstChild(weaponName) or inBackpack
                else
                    error("Melee tool is not equipped")
                end
            end

            dropRemote:FireServer(tool)
            local runtimeItem = nil
            local deadline = os.clock() + 0.65
            repeat
                runtimeItem = runtimeItems:FindFirstChild(weaponName)
                if runtimeItem then break end
                task.wait(0.025)
            until os.clock() >= deadline

            if not runtimeItem then
                local recovered = backpack:FindFirstChild(weaponName) or character:FindFirstChild(weaponName)
                if recovered and recovered.Parent == backpack then
                    humanoid:EquipTool(recovered)
                end
                error("Dropped tool did not appear in RuntimeItems")
            end

            local recoveredTool = nil
            for attempt = 1, 5 do
                if not runtimeItem.Parent then break end
                pickupRemote:FireServer(runtimeItem)
                task.wait(0.05)
                recoveredTool = backpack:FindFirstChild(weaponName)
                if recoveredTool then break end
            end

            deadline = os.clock() + 0.55
            while not recoveredTool and os.clock() < deadline do
                recoveredTool = backpack:FindFirstChild(weaponName)
                task.wait(0.025)
            end
            if not recoveredTool then
                -- One final bounded pickup attempt; never loop indefinitely.
                runtimeItem = runtimeItems:FindFirstChild(weaponName)
                if runtimeItem then
                    for _ = 1, 3 do
                        pickupRemote:FireServer(runtimeItem)
                        task.wait(0.06)
                        recoveredTool = backpack:FindFirstChild(weaponName)
                        if recoveredTool then break end
                    end
                end
            end
            if not recoveredTool then
                error("Weapon pickup was not confirmed; check RuntimeItems")
            end

            humanoid:EquipTool(recoveredTool)
            task.wait(0.04)
            local equipped = character:FindFirstChild(weaponName) or recoveredTool
            local swingEvent = equipped:FindFirstChild("SwingEvent", true)
            if not swingEvent or not swingEvent:IsA("RemoteEvent") then
                error("SwingEvent missing after tool pickup")
            end

            local direction = (targetRoot.Position - characterRoot.Position)
            if direction.Magnitude < 0.001 then
                direction = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.LookVector or characterRoot.CFrame.LookVector
            else
                direction = direction.Unit
            end
            swingEvent:FireServer(direction)
            auraAttackAttempts = auraAttackAttempts + 1
            state.currentAuraApi = "DropTool/PickUpTool -> SwingEvent"
            currentAuraInput = "tool-reset swing"
            currentAuraStatus = "Rapid tool-reset swing -> " .. targetRoot.Parent.Name
        end)
        if not success then
            state.currentAuraApi = "Tool-reset failed"
            currentAuraStatus = "Tool-reset: " .. tostring(err):sub(1, 48)
        end
        state.rapidMeleeBusy = false
    end)
    return true, "Tool-reset swing queued"
end

local function runKillAura()
    local trackedTarget = nil
    local trackedHealth = nil
    local lastEquipAttempt = 0
    local cachedAuraTarget = nil
    local cachedAuraKind = nil
    local nextAuraScanAt = 0

    while state.running do
        local stepOk, stepError = pcall(function()
            if not state.killAura then
                combatTargetActive = false
                releaseAuraInput()
                currentAuraStatus = "Off"
                state.currentAuraApi = "Idle (toggle off)"
                currentAuraTargetName = "--"
                state.currentAuraTargetInstance = nil
                currentAuraWeapon = "--"
                trackedTarget = nil
                trackedHealth = nil
                cachedAuraTarget = nil
                cachedAuraKind = nil
                nextAuraScanAt = 0
                return
            end

            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
            local meleeReady, weaponName, meleeTool = getMeleeReady(character)
            currentAuraWeapon = weaponName or "Not detected"

            if not humanoid or humanoid.Health <= 0 or not characterRoot then
                combatTargetActive = false
                currentAuraStatus = "Waiting for respawn"
                currentAuraTargetName = "--"
                state.currentAuraTargetInstance = nil
                releaseAuraInput()
                trackedTarget = nil
                trackedHealth = nil
                cachedAuraTarget = nil
                cachedAuraKind = nil
                nextAuraScanAt = 0
                return
            end

            if state.autoEquipMelee and os.clock() - lastEquipAttempt >= 0.75 then
                local equippedTool = getEquippedMeleeTool(character)
                if not equippedTool and not getCachedMeleeVisual(character) then
                    lastEquipAttempt = os.clock()
                    local bestTool = getBestMeleeTool(character)
                    if bestTool and bestTool.Parent ~= character then
                        pcall(function()
                            humanoid:EquipTool(bestTool)
                        end)
                        task.wait(0.12)
                        meleeReady, weaponName, meleeTool = getMeleeReady(character)
                        currentAuraWeapon = weaponName or "Not detected"
                    end
                end
            end

            local now = os.clock()
            local shouldRescanAura = now >= nextAuraScanAt
                or (cachedAuraTarget ~= nil and (not cachedAuraTarget.Parent or isTargetDead(cachedAuraTarget)))
            if shouldRescanAura then
                local foundTarget, foundRoot, foundKind = getNearestAuraTarget(characterRoot)
                cachedAuraTarget = foundTarget
                cachedAuraKind = foundKind
                nextAuraScanAt = now + 0.08
            end
            local target = cachedAuraTarget
            local targetRoot = target and getRootPart(target) or nil
            local targetKind = cachedAuraKind
            local distance = targetRoot and (targetRoot.Position - characterRoot.Position).Magnitude or math.huge
            if target and (not targetRoot or distance > state.auraRange) then
                cachedAuraTarget = nil
                cachedAuraKind = nil
                nextAuraScanAt = 0
                target = nil
                targetRoot = nil
            end
            local meleeRemote, meleeApiName, meleeApiKind = state.resolveMeleeRemote(meleeTool)
            local nativeMeleeAvailable = meleeRemote ~= nil and meleeTool ~= nil
            local rapidAdapterAvailable = state.rapidToolResetAvailable(meleeTool)
            state.currentAuraApi = nativeMeleeAvailable and meleeApiName
                or (rapidAdapterAvailable and "DropTool/PickUpTool + SwingEvent available")
                or (game.GameId == 10759337137
                    and "Last Stop: normal Swing input; no verified melee remote"
                    or (meleeTool and "No compatible native remote; input fallback" or "No Tool object; input fallback"))
            if not target or not targetRoot then
                combatTargetActive = false
                releaseAuraInput()
                currentAuraTargetName = "--"
                state.currentAuraTargetInstance = nil
                trackedTarget = nil
                trackedHealth = nil
                cachedAuraTarget = nil
                cachedAuraKind = nil

                -- Native auto-swing does not need a locally selected NPC. The
                -- server performs its own melee hitbox check, as in the public
                -- Dead Rails reference. This is not a promise of extra hit range.
                if nativeMeleeAvailable and meleeReady and meleeTool
                    and os.clock() - lastAuraAttack >= state.auraInterval then
                    local sent, mode = state.sendNativeMelee(meleeTool, nil, characterRoot)
                    if sent then
                        lastAuraAttack = os.clock()
                        currentAuraStatus = "Native auto-swing (camera direction)"
                        state.currentAuraApi = mode or meleeApiName
                    else
                        currentAuraStatus = tostring(mode or "Native swing failed")
                    end
                elseif state.auraUnverifiedCount > 0 then
                    currentAuraStatus = string.format("Skipped %d NPCs without a live-health signal", state.auraUnverifiedCount)
                else
                    currentAuraStatus = state.auraAllNPCs and "No NPC in range" or "No recognized hostile in range"
                end
                return
            end

            currentAuraTargetName = target.Name
            state.currentAuraTargetInstance = target

            if isTargetDead(target) then
                combatTargetActive = false
                auraCandidates[target] = nil
                releaseAuraInput()
                trackedTarget = nil
                trackedHealth = nil
                cachedAuraTarget = nil
                cachedAuraKind = nil
                nextAuraScanAt = 0
                currentAuraStatus = "Target eliminated"
                return
            end

            local healthNow = getTargetHealth(target)
            if trackedTarget ~= target then
                releaseAuraInput()
                trackedTarget = target
                trackedHealth = healthNow
            elseif healthNow ~= nil and trackedHealth ~= nil then
                if healthNow < trackedHealth then
                    auraConfirmedHits = auraConfirmedHits + 1
                end
                trackedHealth = healthNow
            end

            if not meleeReady then
                combatTargetActive = false
                releaseAuraInput()
                currentAuraStatus = "No melee weapon / Swing prompt"
                return
            end

            if not nativeMeleeAvailable and not rapidAdapterAvailable and distance > state.auraHitRange then
                combatTargetActive = false
                releaseAuraInput()
                state.currentAuraApi = "Input fallback only"
                currentAuraStatus = string.format(
                    "No game melee remote; click fallback limited to %.1f studs", state.auraHitRange
                )
                return
            end

            combatTargetActive = true

            if rapidAdapterAvailable and not nativeMeleeAvailable then
                if distance > 10 then
                    currentAuraStatus = "Tool-reset adapter range: about 10 studs"
                    return
                end
                if not state.rapidMeleeBusy and os.clock() - lastAuraAttack >= math.max(state.auraInterval, 0.12) then
                    local started, message = state.startRapidToolResetSwing(meleeTool, targetRoot, characterRoot)
                    if started then
                        lastAuraAttack = os.clock()
                        currentAuraStatus = "Rapid tool-reset swing -> " .. targetKind
                    else
                        currentAuraStatus = tostring(message or "Tool-reset swing unavailable")
                    end
                elseif state.rapidMeleeBusy then
                    currentAuraStatus = "Rapid tool-reset swing in progress"
                end
                return
            end

            -- Native requests carry a target direction, so no camera or character
            -- movement is required. Facing/camera options remain optional for fallback.
            if state.auraFace then
                faceAuraTarget(character, targetRoot)
            end
            if state.auraAimCamera then
                aimAuraCamera(targetRoot)
            end

            if not nativeMeleeAvailable and isPointerOverToolkit() then
                releaseAuraInput()
                currentAuraStatus = "Move cursor off toolkit (fallback)"
            elseif os.clock() - lastAuraAttack >= state.auraInterval then
                local sent, attackMode = beginAuraAttack(meleeTool, targetRoot, characterRoot)
                if sent then
                    lastAuraAttack = os.clock()
                    currentAuraStatus = string.format("%s -> %s (%.1f studs)",
                        nativeMeleeAvailable and "Remote swing" or "Click swing", targetKind, distance)
                    state.currentAuraApi = attackMode or state.currentAuraApi
                else
                    currentAuraStatus = tostring(attackMode or "Melee request failed")
                end
            else
                currentAuraStatus = string.format("Targeting %s (%.1f studs)", target.Name, distance)
            end
        end)

        if not stepOk then
            releaseAuraInput()
            combatTargetActive = false
            currentAuraStatus = "Aura error: " .. tostring(stepError):sub(1, 45)
        end
        task.wait(state.killAura and 0.01 or 0.10)
    end

    releaseAuraInput()
end

task.spawn(runKillAura)


-- Firearm assist: uses the game's normal click-to-shoot input and refuses to fire
-- unless a raycast reaches the selected hostile model before hitting scenery.
local gunNameWords = {
    "revolver", "shotgun", "rifle", "pistol", "sniper", "smg",
    "submachine", "carbine", "musket", "firearm", "crossbow", "handgun",
    "double barrel", "blunderbuss", "machine gun", "flamethrower",
    "ak47", "ak-47", "m4", "m16", "mp5", "uzi", "deagle", "desert eagle", "gun",
    "mauser", "elephant_rifle", "bolt_action_rifle", "firework_gun", "flintlock",
    "springfield", "sawed_off_shotgun", "revolver_rifle", "navy_revolver"
}

local function isGunTool(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end

    local okType, weaponType = pcall(function()
        return tool:GetAttribute("WeaponType")
    end)
    if okType and type(weaponType) == "string" then
        local lowered = string.lower(weaponType)
        if string.find(lowered, "ranged", 1, true) or string.find(lowered, "gun", 1, true) then
            return true
        end
    end

    local okGun, isGun = pcall(function()
        return tool:GetAttribute("IsGun") or tool:GetAttribute("IsRanged")
    end)
    if okGun and isGun == true then
        return true
    end

    local name = state.getItemIdentityText(tool)
    if hasAny(name, gunNameWords) then
        return true
    end

    return false
end

local function getEquippedGun(character)
    if not character then
        return nil
    end
    for _, child in ipairs(character:GetChildren()) do
        if isGunTool(child) then
            return child
        end
    end

    -- Some custom hotbar systems render the held firearm as a character model
    -- instead of parenting a Roblox Tool directly to the character.
    for _, object in ipairs(character:GetDescendants()) do
        if (object:IsA("Model") or object:IsA("BasePart"))
            and hasAny(state.getItemIdentityText(object), gunNameWords)
            and not object:FindFirstAncestorOfClass("Tool") then
            return object
        end
    end

    -- Last Stop can expose the selected item through its HUD rather than a
    -- descriptive Tool.Name. If a Shoot prompt is visible and exactly one Tool
    -- is equipped, use that Tool for ordinary input-based aiming/shooting.
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local shootPromptVisible = false
    if playerGui then
        for _, object in ipairs(playerGui:GetDescendants()) do
            if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
                local ok, text = pcall(function() return object.Text end)
                if ok and type(text) == "string" and string.find(string.lower(text), "shoot", 1, true) then
                    shootPromptVisible = true
                    break
                end
            end
        end
    end
    if shootPromptVisible then
        local onlyTool = nil
        local toolCount = 0
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") then
                toolCount = toolCount + 1
                onlyTool = child
            end
        end
        if toolCount == 1 then
            return onlyTool
        end
    end
    return nil
end

local function getGunAimPart(model)
    local head = model and model:FindFirstChild("Head", true)
    if head and head:IsA("BasePart") then
        return head
    end
    return getRootPart(model)
end

local function hasGunLineOfSight(character, target, aimPart)
    local camera = Workspace.CurrentCamera
    if not camera or not target or not aimPart then
        return false
    end

    local origin = camera.CFrame.Position
    local direction = aimPart.Position - origin
    if direction.Magnitude <= 0.1 then
        return false
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character}
    params.IgnoreWater = true

    local result = Workspace:Raycast(origin, direction, params)
    return result ~= nil and result.Instance ~= nil and result.Instance:IsDescendantOf(target)
end

local function findVisibleGunAimPart(character, target)
    local names = {"Head", "UpperTorso", "Torso", "HumanoidRootPart", "RootPart", "Root"}
    for _, partName in ipairs(names) do
        local part = target:FindFirstChild(partName, true)
        if part and part:IsA("BasePart") and hasGunLineOfSight(character, target, part) then
            return part
        end
    end

    local root = getRootPart(target)
    if root and hasGunLineOfSight(character, target, root) then
        return root
    end
    return nil
end

local function findNearestGunTarget(character, characterRoot)
    local bestModel = nil
    local bestPart = nil
    local bestDistance = state.gunRange
    local blockedModel = nil
    local blockedDistance = state.gunRange

    for model, kind in pairs(auraCandidates) do
        if not model or not model.Parent then
            auraCandidates[model] = nil
        elseif not isPlayerCharacter(model) and not isTargetDead(model) and state.hasTargetAliveSignal(model) then
            local context = getContextName(model)
            if not hasAny(context, friendlyWords) then
                if kind == "unknown" or not kind then
                    kind = classifyAura(model)
                    if not kind and state.auraAllNPCs then
                        kind = "unknown"
                    end
                end

                local allowed = kind == "zombie"
                    or (kind == "boss" and state.auraBosses)
                    or (kind == "unknown" and state.auraAllNPCs)

                if allowed then
                    local root = getRootPart(model)
                    if root then
                        local distance = (root.Position - characterRoot.Position).Magnitude
                        if distance <= state.gunRange then
                            local aimPart = nil
                            if state.gunWallCheck then
                                aimPart = findVisibleGunAimPart(character, model)
                            else
                                aimPart = getGunAimPart(model) or root
                            end

                            if aimPart then
                                if distance < bestDistance then
                                    bestModel = model
                                    bestPart = aimPart
                                    bestDistance = distance
                                end
                            elseif state.gunWallCheck and distance < blockedDistance then
                                blockedModel = model
                                blockedDistance = distance
                            end
                        end
                    end
                end
            end
        end
    end

    return bestModel, bestPart, bestDistance, blockedModel
end

local function aimGunAt(targetPart)
    local camera = Workspace.CurrentCamera
    if not camera or not targetPart then
        return false
    end

    local cameraPosition = camera.CFrame.Position
    local direction = targetPart.Position - cameraPosition
    if direction.Magnitude <= 0.1 then
        return false
    end

    local ok = pcall(function()
        local desired = CFrame.lookAt(cameraPosition, targetPart.Position, camera.CFrame.UpVector)
        camera.CFrame = camera.CFrame:Lerp(desired, 0.55)
    end)
    return ok
end

state.getDeadRailsShootRemote = function()
    if game.GameId == 10759337137 then
        return nil
    end
    if state.cachedDeadRailsShootRemote and state.cachedDeadRailsShootRemote.Parent then
        return state.cachedDeadRailsShootRemote
    end
    local remotes = state.replicatedStorage:FindFirstChild("Remotes")
    local weaponFolder = remotes and remotes:FindFirstChild("Weapon")
    local shootRemote = weaponFolder and weaponFolder:FindFirstChild("Shoot")
    if shootRemote and shootRemote:IsA("RemoteEvent") then
        state.cachedDeadRailsShootRemote = shootRemote
        return shootRemote
    end
    return nil
end

local function fireGunClick(targetPart, targetModel, gun, character)
    if not targetPart or not targetModel then
        return false
    end

    if state.gunWallCheck and not hasGunLineOfSight(character, targetModel, targetPart) then
        state.currentGunApi = "Blocked by wall"
        return false
    end

    -- Dead Rails' public source uses Remotes.Weapon.Shoot with a server timestamp,
    -- equipped Tool, hit CFrame, and Humanoid hit map. Use only if that exact API exists.
    local shootRemote = state.getDeadRailsShootRemote()
    local targetHumanoid = targetModel:FindFirstChildWhichIsA("Humanoid", true)
    if shootRemote and gun and gun:IsA("Tool") and targetHumanoid then
        local targetRoot = getRootPart(targetModel) or targetPart
        local hitCFrame = targetRoot.CFrame * CFrame.Angles(-1.794655442237854, 0.22748638689517975, 2.360928773880005)
        local hitMap = { ["4"] = targetHumanoid, ["2"] = targetHumanoid }
        local remoteOk = pcall(function()
            shootRemote:FireServer(Workspace:GetServerTimeNow(), gun, hitCFrame, hitMap)
        end)
        if remoteOk then
            state.currentGunApi = "Remotes.Weapon.Shoot"
            return true
        end
        state.currentGunApi = "Remote failed; input fallback"
    end

    local camera = Workspace.CurrentCamera
    if not camera or not virtualInput then
        state.currentGunApi = "No compatible shoot API / input"
        return false
    end

    local point, onScreen = camera:WorldToScreenPoint(targetPart.Position)
    if not onScreen or isScreenPointOverToolkit(point.X, point.Y) then
        return false
    end

    local previousMouse = nil
    pcall(function()
        previousMouse = UserInputService:GetMouseLocation()
    end)

    local downOk = pcall(function()
        virtualInput:SendMouseMoveEvent(point.X, point.Y, game)
        virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, true, game, 0)
    end)
    if not downOk then
        return false
    end

    task.wait(0.025)
    local upOk = pcall(function()
        virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
    end)
    if not upOk then
        pcall(function()
            virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
        end)
        return false
    end
    if previousMouse then
        pcall(function()
            virtualInput:SendMouseMoveEvent(previousMouse.X, previousMouse.Y, game)
        end)
    end

    state.currentGunApi = "Input fallback"
    return true
end

local function getGunAmmoCount(gun)
    if not gun then return nil end
    local names = {"Ammo", "CurrentAmmo", "AmmoCount", "LoadedAmmo", "Clip", "Magazine", "Bullets"}
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return gun:GetAttribute(name) end)
        if ok and type(value) == "number" then return value end
    end
    for _, object in ipairs(gun:GetDescendants()) do
        if object:IsA("IntValue") or object:IsA("NumberValue") then
            local lower = string.lower(object.Name)
            if hasAny(lower, {"ammo", "clip", "magazine", "bullet"}) then
                return tonumber(object.Value)
            end
        end
    end
    return nil
end

state.tryLastStopAutoReload = function(gun)
    if not state.gunAutoReload or not gun then return false end
    local ammo = getGunAmmoCount(gun)
    if ammo == nil or ammo > 0 or os.clock() - state.lastGunReloadAt < 1.5 then
        return false
    end

    if not virtualInput then
        state.currentGunApi = "R reload input unavailable"
        return false
    end

    local ok = pcall(function()
        virtualInput:SendKeyEvent(true, Enum.KeyCode.R, false, game)
        task.wait(0.04)
        virtualInput:SendKeyEvent(false, Enum.KeyCode.R, false, game)
    end)
    if ok then
        state.lastGunReloadAt = os.clock()
        state.currentGunApi = "Last Stop R reload input"
        gunStatus = "Reload key sent"
        return true
    end
    state.currentGunApi = "R reload input failed"
    return false
end

local function runGunAssist()
    local trackedGunTarget = nil
    local trackedGunHealth = nil

    while state.running do
        local ok, err = pcall(function()
            gunTargetActive = false
            if not state.gunAimAssist and not state.gunAutoShoot then
                gunStatus = "Off"
                state.currentGunApi = "Idle (toggle off)"
                gunTargetName = "--"
                trackedGunTarget = nil
                trackedGunHealth = nil
                return
            end

            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
            local gun = getEquippedGun(character)

            if not humanoid or humanoid.Health <= 0 or not characterRoot then
                gunStatus = "Waiting for respawn"
                gunTargetName = "--"
                return
            end
            if not gun then
                gunStatus = "Equip a firearm"
                gunTargetName = "--"
                state.currentGunApi = "No firearm"
                return
            end

            if state.gunAutoReload and state.tryLastStopAutoReload(gun) then
                return
            end

            local target, aimPart, distance, blocked = findNearestGunTarget(character, characterRoot)
            if not target or not aimPart then
                trackedGunTarget = nil
                trackedGunHealth = nil
                if blocked then
                    gunTargetName = blocked.Name
                    gunStatus = "Blocked by wall: " .. blocked.Name
                    if os.clock() - lastGunBlockedAt >= 0.5 then
                        gunBlockedShots = gunBlockedShots + 1
                        lastGunBlockedAt = os.clock()
                    end
                else
                    gunTargetName = "--"
                    gunStatus = "No visible hostile in range"
                end
                return
            end

            gunTargetActive = state.gunAimAssist or state.gunAutoShoot
            gunTargetName = target.Name
            local targetHealth = getTargetHealth(target)
            if trackedGunTarget ~= target then
                trackedGunTarget = target
                trackedGunHealth = targetHealth
            elseif targetHealth ~= nil and trackedGunHealth ~= nil then
                if targetHealth < trackedGunHealth then
                    gunConfirmedHits = gunConfirmedHits + 1
                end
                trackedGunHealth = targetHealth
            end

            if state.gunAimAssist or state.gunAutoShoot then
                aimGunAt(aimPart)
            end

            -- Re-check after aiming so an intervening wall never receives a shot.
            if state.gunAutoShoot then
                if state.gunWallCheck and not hasGunLineOfSight(character, target, aimPart) then
                    gunStatus = "Shot blocked: line of sight lost"
                    if os.clock() - lastGunBlockedAt >= 0.5 then
                        gunBlockedShots = gunBlockedShots + 1
                        lastGunBlockedAt = os.clock()
                    end
                elseif os.clock() - lastGunShot >= state.gunFireInterval then
                    local fired = fireGunClick(aimPart, target, gun, character)
                    if fired then
                        lastGunShot = os.clock()
                        gunShots = gunShots + 1
                        gunStatus = string.format("Sent shot input to %s (%.0f studs)", target.Name, distance)
                    else
                        gunStatus = "Aim ready; click input unavailable"
                    end
                else
                    gunStatus = string.format("Aiming at %s (%.0f studs)", target.Name, distance)
                end
            else
                gunStatus = string.format("Aiming at %s (%.0f studs)", target.Name, distance)
            end
        end)

        if not ok then
            gunTargetActive = false
            gunStatus = "Gun assist error: " .. tostring(err):sub(1, 42)
        end
        task.wait(0.05)
    end
    gunTargetActive = false
end

task.spawn(runGunAssist)

-- Auto-loot uses the game's visible pickup interactions (ProximityPrompts,
-- ClickDetectors, and Last Stop's F / Pick Up key). It does not guess remotes.
local lootNameWords = {
    "gascan", "gas can", "gasoline", "fuel", "coal", "wood", "scrap",
    "duct tape", "tape", "spring", "metal pipe", "pipe", "ammo", "bullet",
    "bandage", "medkit", "apple", "coke", "chocolate", "cake", "food",
    "water", "rope", "battery", "shovel", "sword", "knife", "axe", "machete",
    "revolver", "shotgun", "rifle", "pistol", "flashlight", "lantern", "candle",
    "cure", "potion", "carved bust", "statue", "valuable", "scrap metal",
    "engine part", "fuse", "canister", "crate", "box", "supply", "lootbox",
    "globe", "artifact", "antique", "cash", "ticket", "coin", "gold", "silver",
    "jewelry", "watch", "medallion", "quest item", "medical", "meds",
    "bond", "money bag", "money_bag", "snake oil", "snake_oil", "ammo_",
    "mauser", "crossbow", "elephant rifle", "bolt action rifle", "blunderbuss",
    "firework gun", "flintlock", "springfield", "sawed off shotgun", "revolver rifle",
    "navy revolver", "tutoitem", "tuto item", "lootitem", "loot item", "worlditem", "world item"
}
local pickupActionWords = {"grab", "pick up", "pickup", "collect", "take"}
state.lootNeverWords = {
    "wheel", "tire", "tyre", "rim", "hubcap", "loot building", "lootbuilding",
    "building", "bus", "vehicle", "truck", "garage", "chassis", "car", "van",
    "house", "terminal"
}
state.lootVehicleAncestorWords = {"bus", "vehicle", "truck", "garage", "chassis", "car", "van"}

state.hasLootWord = function(text, words)
    text = string.lower(text or "")
    for _, word in ipairs(words) do
        local escaped = string.gsub(word, "([^%w])", "%%%1")
        if string.find(text, "%f[%w]" .. escaped .. "%f[%W]") then
            return true
        end
    end
    return false
end

state.isExcludedLootCandidate = function(candidate, promptObjectText)
    if not candidate then
        return true
    end

    local candidateName = string.lower(candidate.Name)
    local promptName = string.lower(promptObjectText or "")
    local contextName = getContextName(candidate)
    if hasAny(contextName, {"wheel", "tire", "tyre", "rim", "hubcap"})
        or hasAny(candidateName, {"wheel", "tire", "tyre", "rim", "hubcap", "bus", "vehicle", "truck", "garage", "chassis", "building"})
        or hasAny(promptName, {"wheel", "tire", "tyre", "rim", "hubcap", "bus", "vehicle", "truck", "garage", "chassis", "building", "house", "terminal"})
        or state.hasLootWord(candidateName, state.lootNeverWords)
        or state.hasLootWord(promptName, {"wheel", "tire", "tyre", "rim", "hubcap", "bus", "vehicle", "truck", "car", "van"}) then
        return true
    end

    -- Some Last Stop world items are GUID-named. Inspect their child names too,
    -- so a GUID-named wheel/tire cannot bypass the explicit vehicle exclusions.
    if candidate:IsA("Model") or candidate:IsA("Tool") then
        local inspected = 0
        for _, descendant in ipairs(candidate:GetDescendants()) do
            local childName = string.lower(descendant.Name)
            if hasAny(childName, {"wheel", "tire", "tyre", "rim", "hubcap", "bus", "vehicle", "truck", "chassis", "building", "garage"}) then
                return true
            end
            inspected = inspected + 1
            if inspected >= 180 then break end
        end
        local boundsOk, _, boundsSize = pcall(function()
            return candidate:GetBoundingBox()
        end)
        if boundsOk and typeof(boundsSize) == "Vector3"
            and (boundsSize.X > 36 or boundsSize.Y > 36 or boundsSize.Z > 36) then
            return true
        end
    end

    local ancestor = candidate.Parent
    for _ = 1, 7 do
        if not ancestor or ancestor == Workspace then
            break
        end
        if hasAny(string.lower(ancestor.Name), {"bus", "vehicle", "truck", "garage", "chassis"})
            or state.hasLootWord(ancestor.Name, state.lootVehicleAncestorWords) then
            return true
        end
        ancestor = ancestor.Parent
    end
    return false
end

local function isInsideLootFolder(instance)
    local parent = instance and instance.Parent
    for _ = 1, 5 do
        if not parent then
            break
        end
        local name = string.lower(parent.Name)
        if name == "loot" or name == "items" or name == "drops"
            or name == "pickups" or name == "worlditems" or name == "looseitems"
            or name == "runtimeitems" or name == "item_container" or name == "itemcontainer" then
            return true
        end
        parent = parent.Parent
    end
    return false
end

local function isLootName(instance)
    local name = string.lower(instance.Name)
    local context = getContextName(instance)
    if state.hasLootWord(name, lootNameWords) or state.hasLootWord(context, lootNameWords)
        or hasAny(context, {"ammo_", "money_bag", "snake_oil"}) then
        return true
    end

    local ok, tags = pcall(function()
        return CollectionService:GetTags(instance)
    end)
    if ok then
        for _, tag in ipairs(tags) do
            if hasAny(string.lower(tag), {"pickup", "loot", "collectible", "worlditem"}) then
                return true
            end
        end
    end
    return false
end

state.isLootCategoryEnabled = function(context)
    context = string.lower(context or "")
    if hasAny(context, {"money_bag", "money bag", "cash bag"}) then
        return state.autoCollectMoney
    elseif hasAny(context, {"bond"}) then
        return state.autoCollectBonds
    elseif hasAny(context, {"ammo_", "ammo", "bullet", "cartridge"}) then
        return state.autoCollectAmmo
    elseif hasAny(context, gunNameWords) then
        return state.autoCollectGuns
    elseif hasAny(context, {"snake_oil", "snake oil", "bandage", "medkit", "medical", "meds"}) then
        return state.autoCollectMeds
    end
    return true
end

local function findNamedWorkspaceContainer(containerName, cacheKey, scanKey)
    local cached = state[cacheKey]
    if cached and cached.Parent then
        return cached
    end
    local lastScan = state[scanKey] or -math.huge
    if lastScan > 0 and os.clock() - lastScan < 3 then
        return nil
    end
    state[scanKey] = os.clock()

    local direct = Workspace:FindFirstChild(containerName)
    if direct and (direct:IsA("Folder") or direct:IsA("Model")) then
        state[cacheKey] = direct
        return direct
    end

    local matches = {}
    for _, object in ipairs(Workspace:GetDescendants()) do
        if object.Name == containerName and (object:IsA("Folder") or object:IsA("Model")) then
            table.insert(matches, object)
            if #matches > 1 then break end
        end
    end
    if #matches == 1 then
        state[cacheKey] = matches[1]
        return matches[1]
    end
    return nil
end

local function getObjectModelsFolder()
    if game.GameId == 10759337137 then return nil end
    return findNamedWorkspaceContainer("ObjectModels", "cachedObjectModelsFolder", "objectModelsScanAt")
end

local function getRuntimeItemsFolder()
    if game.GameId == 10759337137 then return nil end
    return findNamedWorkspaceContainer("RuntimeItems", "cachedRuntimeItemsFolder", "runtimeItemsScanAt")
end

state.getItemContainerFolder = function()
    return findNamedWorkspaceContainer("ITEM_CONTAINER", "cachedItemContainer", "itemContainerScanAt")
end

state.getTopLevelItemContainerObject = function(instance)
    local container = state.getItemContainerFolder()
    if not container or not instance then
        return nil
    end
    local current = instance
    while current and current ~= container do
        if current.Parent == container
            and (current:IsA("Model") or current:IsA("Tool") or current:IsA("BasePart")) then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function findServerEntityOwner(object)
    local current = object
    for _ = 1, 12 do
        if not current or current == Workspace then
            break
        end
        local ok, value = pcall(function()
            return current:GetAttribute("serverEntity")
        end)
        if ok and value ~= nil then
            return current, value
        end
        current = current.Parent
    end
    return nil, nil
end

local function getLootInteraction(instance)
    local prompt = nil
    local clickDetector = nil
    for _, object in ipairs(instance:GetDescendants()) do
        if object:IsA("ProximityPrompt") and object.Enabled then
            local action = string.lower((object.ActionText or "") .. " " .. (object.ObjectText or ""))
            if hasAny(action, pickupActionWords) then
                prompt = object
                break
            end
        elseif object:IsA("ClickDetector") then
            clickDetector = object
        end
    end
    return prompt, clickDetector
end

local function isPlayerInventoryObject(instance)
    local character = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if character and instance:IsDescendantOf(character) then
        return true
    end
    if backpack and instance:IsDescendantOf(backpack) then
        return true
    end
    return false
end

local function getLootCandidate(instance)
    local candidate = nil
    local fromPickupPrompt = false
    local promptObjectText = ""

    if instance:IsA("ProximityPrompt") then
        local actionText = string.lower(instance.ActionText or "")
        promptObjectText = string.lower(instance.ObjectText or "")
        local action = actionText .. " " .. promptObjectText
        if not hasAny(action, pickupActionWords) then
            return nil
        end
        fromPickupPrompt = true
        local current = instance.Parent
        local nearestPart = nil
        while current and current ~= Workspace do
            if current:IsA("Model") or current:IsA("Tool") then
                candidate = current
                break
            elseif current:IsA("BasePart") and not nearestPart then
                nearestPart = current
            end
            current = current.Parent
        end
        candidate = candidate or nearestPart
    elseif instance:IsA("Tool") or instance:IsA("Model") then
        candidate = instance
    elseif instance:IsA("BasePart") then
        candidate = instance:FindFirstAncestorOfClass("Model") or instance
    else
        return nil
    end

    local itemContainerRoot = state.getTopLevelItemContainerObject(instance)
    local isLastStopItem = itemContainerRoot ~= nil
    local featureGrab = false
    if itemContainerRoot then
        candidate = itemContainerRoot
        pcall(function() featureGrab = itemContainerRoot:GetAttribute("Feature_Grab") == true end)
    end

    if not candidate or not candidate.Parent or not candidate:IsDescendantOf(Workspace)
        or isPlayerInventoryObject(candidate) or isPlayerCharacter(candidate)
        or state.lootRejected[candidate] then
        return nil
    end

    local identityText = state.getItemIdentityText(candidate)
    if state.isExcludedLootCandidate(candidate, (promptObjectText or "") .. " " .. identityText) then
        return nil
    end

    local context = getContextName(candidate) .. " " .. identityText
    if hasAny(context, friendlyWords) or not state.isLootCategoryEnabled(context) then
        return nil
    end

    -- Last Stop's diagnostic confirms direct ITEM_CONTAINER Tools carry
    -- Feature_Grab=true. Prefer that explicit game attribute over GUID/name
    -- heuristics; it is the strongest available pickup eligibility signal.
    if isLastStopItem then
        if featureGrab then return candidate end
        if candidate:IsA("Tool") then return nil end
        return candidate
    end
    if classifyAura(candidate) then return nil end

    local namedLoot = isLootName(candidate) or state.hasLootWord(promptObjectText, lootNameWords)
    local objectModels = getObjectModelsFolder()
    local serverOwner, serverEntity = findServerEntityOwner(candidate)
    local deadRailsItem = objectModels and candidate:IsDescendantOf(objectModels) and serverEntity ~= nil
    if deadRailsItem then
        local itemContext = getContextName(serverOwner or candidate)
        if hasAny(itemContext, {"tutoitem", "worlditem", "lootitem", "pickup", "bond", "ammo", "bandage", "snake_oil", "money_bag"}) then
            namedLoot = true
        end
    end
    local insideLootFolder = isInsideLootFolder(candidate)
    if fromPickupPrompt then
        if not namedLoot and not insideLootFolder then
            return nil
        end
    elseif not namedLoot and not insideLootFolder then
        return nil
    end

    return candidate
end

local function queueLootRegistration(instance)
    if not instance:IsA("Model") and not instance:IsA("Tool") and not instance:IsA("BasePart")
        and not instance:IsA("ProximityPrompt") and not instance:IsA("ClickDetector") then
        return
    end

    local promptObjectText = ""
    local fromPickupPrompt = instance:IsA("ProximityPrompt")
    if fromPickupPrompt then
        promptObjectText = string.lower(instance.ObjectText or "")
    end

    local candidate = getLootCandidate(instance)
    if not candidate and instance:IsA("ClickDetector") then
        local current = instance.Parent
        while current and current ~= Workspace do
            if current:IsA("Model") or current:IsA("BasePart") or current:IsA("Tool") then
                candidate = getLootCandidate(current)
                break
            end
            current = current.Parent
        end
    end
    if not candidate or state.lootRejected[candidate] or lootRegistrationPending[candidate] then
        return
    end

    lootRegistrationPending[candidate] = true
    task.delay(0.12, function()
        lootRegistrationPending[candidate] = nil
        if state.running and candidate.Parent and candidate:IsDescendantOf(Workspace) then
            -- Re-run the strict allow/deny checks. A prompt may identify an item
            -- by ObjectText even when its parent model has a generic name.
            local valid = getLootCandidate(candidate)
            if not valid and fromPickupPrompt and instance.Parent
                and not state.isExcludedLootCandidate(candidate, promptObjectText)
                and not isPlayerInventoryObject(candidate) and not isPlayerCharacter(candidate)
                and not hasAny(getContextName(candidate), friendlyWords)
                and not classifyAura(candidate)
                and (state.hasLootWord(promptObjectText, lootNameWords) or isInsideLootFolder(candidate)) then
                valid = candidate
            end
            if valid then
                lootCandidates[valid] = true
                lootInteractionCache[valid] = nil
            end
        end
    end)
end

for _, instance in ipairs(Workspace:GetDescendants()) do
    if instance:IsA("Model") or instance:IsA("Tool") or instance:IsA("ProximityPrompt")
        or (instance:IsA("BasePart") and not instance:FindFirstAncestorOfClass("Model")
            and not instance:FindFirstAncestorWhichIsA("Tool")) then
        local candidate = getLootCandidate(instance)
        if candidate then
            lootCandidates[candidate] = true
        end
    end
end

track(Workspace.DescendantAdded:Connect(queueLootRegistration))
track(Workspace.DescendantRemoving:Connect(function(instance)
    if lootCandidates[instance] then
        lootCandidates[instance] = nil
        lootInteractionCache[instance] = nil
        lootLastAttempt[instance] = nil
    end
    state.lootRejected[instance] = nil
    lootFailedAttempts[instance] = nil

    local parent = instance.Parent
    while parent and parent ~= Workspace do
        if lootCandidates[parent] then
            lootInteractionCache[parent] = nil
            break
        end
        parent = parent.Parent
    end
end))

local function getInventoryItemCount()
    local count = 0
    local character = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")

    if character then
        for _, object in ipairs(character:GetChildren()) do
            if object:IsA("Tool") then
                count = count + 1
            end
        end
    end
    if backpack then
        for _, object in ipairs(backpack:GetChildren()) do
            if object:IsA("Tool") then
                count = count + 1
            end
        end
    end
    return count
end

local function getCachedLootInteraction(candidate)
    local cached = lootInteractionCache[candidate]
    local now = os.clock()
    if cached and now - cached.at < 2
        and (not cached.prompt or (cached.prompt.Parent and cached.prompt.Enabled))
        and (not cached.clickDetector or cached.clickDetector.Parent) then
        return cached.prompt, cached.clickDetector
    end

    local prompt, clickDetector = getLootInteraction(candidate)
    lootInteractionCache[candidate] = {
        prompt = prompt,
        clickDetector = clickDetector,
        at = now,
    }
    return prompt, clickDetector
end

local function findNearestLoot(origin, maxDistance)
    local bestObject = nil
    local bestRoot = nil
    local bestPrompt = nil
    local bestClickDetector = nil
    local bestDistance = maxDistance
    local now = os.clock()
    local count = 0
    local inRangeCount = 0
    local coolingDown = false

    for candidate in pairs(lootCandidates) do
        if not candidate or not candidate.Parent or not candidate:IsDescendantOf(Workspace)
            or state.isExcludedLootCandidate(candidate, "") or state.lootRejected[candidate] then
            lootCandidates[candidate] = nil
            lootInteractionCache[candidate] = nil
            lootLastAttempt[candidate] = nil
        elseif isPlayerInventoryObject(candidate) then
            lootCandidates[candidate] = nil
            lootInteractionCache[candidate] = nil
        else
            local root = getRootPart(candidate)
            if root and root.Parent then
                local distance = (root.Position - origin).Magnitude
                count = count + 1
                if distance <= maxDistance then
                    inRangeCount = inRangeCount + 1
                    local lastAttempt = lootLastAttempt[candidate] or 0
                    if now - lastAttempt >= 1.25 then
                        local prompt, clickDetector = getCachedLootInteraction(candidate)
                        if distance <= bestDistance then
                            bestObject = candidate
                            bestRoot = root
                            bestPrompt = prompt
                            bestClickDetector = clickDetector
                            bestDistance = distance
                        end
                    else
                        coolingDown = true
                    end
                end
            end
        end
    end

    lootCandidateCount = count
    lootInRangeCount = inRangeCount
    state.lastLootInRangeCount = inRangeCount
    return bestObject, bestRoot, bestDistance, bestPrompt, bestClickDetector, coolingDown
end

local function getLootPickupRange(prompt, clickDetector)
    if prompt and prompt.Parent then
        local ok, maxDistance = pcall(function()
            return prompt.MaxActivationDistance
        end)
        if ok and type(maxDistance) == "number" and maxDistance > 0 then
            return math.max(3, math.min(maxDistance - 0.5, 12))
        end
    end

    if clickDetector and clickDetector.Parent then
        local ok, maxDistance = pcall(function()
            return clickDetector.MaxActivationDistance
        end)
        if ok and type(maxDistance) == "number" and maxDistance > 0 then
            return math.max(6, math.min(maxDistance - 1, 15))
        end
    end

    return 8
end

local busCache = nil
local busRootCache = nil
local busSeatCache = nil
local busCacheAt = 0

local function findNearestBus(origin)
    if os.clock() - busCacheAt < 3 then
        if busCache and busCache.Parent and busCache:IsDescendantOf(Workspace)
            and busRootCache and busRootCache.Parent and busRootCache:IsDescendantOf(Workspace) then
            return busCache, busRootCache, busSeatCache
        elseif not busCache then
            return nil, nil, nil
        end
    end

    local bestBus = nil
    local bestRoot = nil
    local bestSeat = nil
    local bestScore = -math.huge

    for _, instance in ipairs(Workspace:GetDescendants()) do
        if instance:IsA("Model") then
            local name = string.lower(instance.Name)
            local seat = instance:FindFirstChildWhichIsA("VehicleSeat", true)
                or instance:FindFirstChildWhichIsA("Seat", true)
            local context = getContextName(instance)
            local isBusStop = hasAny(name, {"busstop", "bus stop", "busstation", "bus station"})
            local isBus = not isBusStop and (
                string.find(name, "bus", 1, true) ~= nil
                or (seat ~= nil and hasAny(context, {"bus", "playerbus", "team bus"}))
                or instance:GetAttribute("IsBus") == true
            )
            if isBus then
                local root = seat or getRootPart(instance)
                if root and not isPlayerCharacter(instance) then
                    local distance = (root.Position - origin).Magnitude
                    local score = 1000 / (distance + 1)
                    local ownerId = instance:GetAttribute("OwnerUserId")
                        or instance:GetAttribute("OwnerId")
                    if tonumber(ownerId) == LocalPlayer.UserId then
                        score = score + 100000
                    end
                    if string.find(name, string.lower(LocalPlayer.Name), 1, true) then
                        score = score + 50000
                    end
                    if score > bestScore then
                        bestScore = score
                        bestBus = instance
                        bestRoot = root
                        bestSeat = seat
                    end
                end
            end
        end
    end

    busCache = bestBus
    busRootCache = bestRoot
    busSeatCache = bestSeat
    busCacheAt = os.clock()
    return bestBus, bestRoot, bestSeat
end

local function getBusReturnPosition(bus, busRoot, seat)
    local anchor = seat or busRoot or getRootPart(bus)
    if not anchor then
        return nil
    end
    -- Stop beside the bus instead of trying to path into its collision geometry.
    return anchor.Position + anchor.CFrame.RightVector * 6 + Vector3.new(0, 1.5, 0)
end

local function teleportRootTo(root, destination, lookAtPosition)
    if not root or not root.Parent or typeof(destination) ~= "Vector3" then
        return false
    end

    local originalCFrame = root.CFrame
    local lookPosition = lookAtPosition
    if not lookPosition or (lookPosition - destination).Magnitude < 0.1 then
        lookPosition = destination + root.CFrame.LookVector
    end

    local ok = pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        root.CFrame = CFrame.lookAt(destination, lookPosition)
    end)
    if not ok then
        return false
    end

    task.wait(0.14)
    local arrived = root.Parent ~= nil and (root.Position - destination).Magnitude <= 10
    if not arrived and root.Parent then
        -- If the server rejects/corrects the teleport, restore the previous
        -- position rather than leaving the character at a partial correction.
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            root.CFrame = originalCFrame
        end)
    end
    return arrived
end

local function teleportNearLoot(root, target, targetRoot, pickupRange)
    if not root or not targetRoot or not targetRoot.Parent then
        return false
    end

    local away = root.Position - targetRoot.Position
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then
        local right = targetRoot.CFrame.RightVector
        away = Vector3.new(right.X, 0, right.Z)
    end
    if away.Magnitude < 0.1 then
        away = Vector3.new(1, 0, 0)
    end

    local boundsSize = targetRoot.Size
    if target and target:IsA("Model") then
        local ok, _, modelSize = pcall(function()
            return target:GetBoundingBox()
        end)
        if ok and typeof(modelSize) == "Vector3" then
            boundsSize = modelSize
        end
    end

    local horizontalRadius = math.max(boundsSize.X, boundsSize.Z) * 0.5
    local maxOffset = math.max(2.5, pickupRange - 1.25)
    local desiredOffset = math.max(3.0, horizontalRadius + 1.0)
    local offset = math.min(desiredOffset, maxOffset)
    if maxOffset < 2.5 then return false end

    local baseDirection = away.Unit
    local directions = {
        baseDirection,
        Vector3.new(-baseDirection.Z, 0, baseDirection.X),
        Vector3.new(baseDirection.Z, 0, -baseDirection.X),
        -baseDirection,
    }

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {LocalPlayer.Character, target}
    rayParams.IgnoreWater = true

    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = {LocalPlayer.Character, target}
    overlapParams.MaxParts = 40

    for _, direction in ipairs(directions) do
        local horizontalPosition = targetRoot.Position + direction * offset
        local destination = Vector3.new(horizontalPosition.X, targetRoot.Position.Y + 3.0, horizontalPosition.Z)
        local groundOrigin = Vector3.new(horizontalPosition.X, targetRoot.Position.Y + 14, horizontalPosition.Z)
        local groundHit = Workspace:Raycast(groundOrigin, Vector3.new(0, -60, 0), rayParams)
        if groundHit then
            destination = Vector3.new(horizontalPosition.X, groundHit.Position.Y + 3.0, horizontalPosition.Z)
        end

        local overlapOk, blockingParts = pcall(function()
            return Workspace:GetPartBoundsInBox(CFrame.new(destination), Vector3.new(2.4, 4.5, 2.4), overlapParams)
        end)
        if overlapOk then
            local blocked = false
            for _, part in ipairs(blockingParts) do
                if part:IsA("BasePart") and part.CanCollide then
                    blocked = true
                    break
                end
            end
            if not blocked then
                return teleportRootTo(root, destination, targetRoot.Position)
            end
        end
    end

    -- No clear landing point near this object; skip it rather than teleporting
    -- the player inside geometry and trapping them.
    return false
end

local function aimLootCamera(root)
    local camera = Workspace.CurrentCamera
    if not camera or not root then
        return
    end

    local cameraPosition = camera.CFrame.Position
    if (root.Position - cameraPosition).Magnitude < 0.1 then
        return
    end

    pcall(function()
        local desired = CFrame.lookAt(cameraPosition, root.Position, camera.CFrame.UpVector)
        camera.CFrame = camera.CFrame:Lerp(desired, 0.45)
    end)
end

local function clickWorldObject(root)
    local camera = Workspace.CurrentCamera
    if not camera or not virtualInput or not root then
        return false
    end

    pcall(function()
        local cameraPosition = camera.CFrame.Position
        camera.CFrame = CFrame.lookAt(cameraPosition, root.Position, camera.CFrame.UpVector)
    end)
    task.wait(0.04)
    local point, onScreen = camera:WorldToScreenPoint(root.Position)
    if not onScreen or isScreenPointOverToolkit(point.X, point.Y) then
        return false
    end

    local previousMouse = nil
    pcall(function()
        previousMouse = UserInputService:GetMouseLocation()
    end)

    local pressOk = pcall(function()
        virtualInput:SendMouseMoveEvent(point.X, point.Y, game)
        virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, true, game, 0)
    end)
    if not pressOk then
        if previousMouse then
            pcall(function()
                virtualInput:SendMouseMoveEvent(previousMouse.X, previousMouse.Y, game)
            end)
        end
        return false
    end

    task.wait(0.06)
    local releaseOk = pcall(function()
        virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
    end)
    if not releaseOk then
        releaseOk = pcall(function()
            virtualInput:SendMouseButtonEvent(point.X, point.Y, 0, false, game, 0)
        end)
    end

    if previousMouse then
        local currentMouse = nil
        pcall(function()
            currentMouse = UserInputService:GetMouseLocation()
        end)
        if currentMouse and (currentMouse - Vector2.new(point.X, point.Y)).Magnitude <= 8 then
            pcall(function()
                virtualInput:SendMouseMoveEvent(previousMouse.X, previousMouse.Y, game)
            end)
        end
    end
    return releaseOk
end

state.getDeadRailsLootRemote = function(remoteName)
    if game.GameId == 10759337137 then
        return nil
    end
    local cached = state.cachedDeadRailsLootRemotes[remoteName]
    if cached and cached.Parent then
        return cached
    end

    local shared = state.replicatedStorage:FindFirstChild("Shared")
    local universe = shared and shared:FindFirstChild("Universe")
    local network = universe and universe:FindFirstChild("Network")
    local events = network and network:FindFirstChild("RemoteEvent")
    local candidate = events and events:FindFirstChild(remoteName)

    if not (candidate and candidate:IsA("RemoteEvent")) then
        local legacyNetwork = shared and shared:FindFirstChild("Network")
        local legacyEvents = legacyNetwork and legacyNetwork:FindFirstChild("RemoteEvent")
        candidate = legacyEvents and legacyEvents:FindFirstChild(remoteName)
    end

    if candidate and candidate:IsA("RemoteEvent") then
        state.cachedDeadRailsLootRemotes[remoteName] = candidate
        return candidate
    end

    -- Some games keep the same Dead Rails remote names under a different folder.
    -- Only accept a unique exact-name match; never guess by a partial name.
    local lastScan = state.deadRailsRemoteScanAt[remoteName] or -math.huge
    if lastScan > 0 and os.clock() - lastScan < 3 then
        return nil
    end
    state.deadRailsRemoteScanAt[remoteName] = os.clock()
    local matches = {}
    for _, object in ipairs(state.replicatedStorage:GetDescendants()) do
        if object:IsA("RemoteEvent") and object.Name == remoteName then
            table.insert(matches, object)
            if #matches > 1 then
                break
            end
        end
    end
    if #matches == 1 then
        state.cachedDeadRailsLootRemotes[remoteName] = matches[1]
        return matches[1]
    elseif #matches > 1 then
        state.currentLootApi = "Ambiguous " .. remoteName .. " remotes"
    end
    return nil
end

state.tryDeadRailsRuntimeToolPickup = function(object)
    if not object or not object.Parent or state.isExcludedLootCandidate(object, "") then
        return false
    end
    local runtimeItems = getRuntimeItemsFolder()
    if not runtimeItems or not object:IsDescendantOf(runtimeItems) then
        return false
    end
    local pickupRemote = state.getDeadRailsToolRemote("PickUpTool")
    if not pickupRemote then
        state.currentLootApi = "PickUpTool remote not found"
        return false
    end

    local runtimeItem = object
    while runtimeItem.Parent and runtimeItem.Parent ~= runtimeItems do
        runtimeItem = runtimeItem.Parent
    end
    local beforeCount = getInventoryItemCount()
    for attempt = 1, 4 do
        if not runtimeItem.Parent then
            state.currentLootApi = "RuntimeItems.PickUpTool (confirmed)"
            return true
        end
        local ok = pcall(function()
            pickupRemote:FireServer(runtimeItem)
        end)
        if not ok then
            state.currentLootApi = "PickUpTool remote call failed"
            return false
        end
        state.currentLootApi = "RuntimeItems.PickUpTool (attempt " .. attempt .. "/4)"
        task.wait(0.1)
        if not runtimeItem.Parent or isPlayerInventoryObject(runtimeItem)
            or getInventoryItemCount() > beforeCount then
            state.currentLootApi = "RuntimeItems.PickUpTool (confirmed)"
            return true
        end
    end
    state.currentLootApi = "RuntimeItems.PickUpTool (unconfirmed)"
    return false
end

local function storeAllRuntimeItems()
    if game.GameId == 10759337137 then
        local lastStopStore = state.getLastStopServiceRemote("ItemService", "RF", "StoreItem")
        if lastStopStore and lastStopStore:IsA("RemoteFunction") then
            return false, "Last Stop StoreItem found; arguments not verified, not invoked"
        end
        return false, "Last Stop ItemService.StoreItem not found"
    end

    local runtimeItems = getRuntimeItemsFolder()
    if not runtimeItems then
        return false, "RuntimeItems folder not found"
    end
    local storeRemote = state.getDeadRailsLootRemote("Store")
    if not storeRemote then
        return false, "Store remote not found"
    end

    local sent = 0
    for _, item in ipairs(runtimeItems:GetChildren()) do
        local _, serverEntity = findServerEntityOwner(item)
        if serverEntity ~= nil then
            local ok = pcall(function()
                storeRemote:FireServer(serverEntity)
            end)
            if ok then
                sent = sent + 1
            end
            task.wait(0.04)
        end
    end
    return sent > 0, string.format("Store requests sent: %d", sent)
end

state.tryDeadRailsServerPickup = function(object)
    if not object or not object.Parent or state.isExcludedLootCandidate(object, "") then
        return false
    end

    local objectModels = getObjectModelsFolder()
    if not objectModels or not object:IsDescendantOf(objectModels) then
        return false
    end

    local owner, serverEntity = findServerEntityOwner(object)
    if serverEntity == nil then
        return false
    end

    local itemContext = string.lower((owner and owner.Name or object.Name) .. " " .. getContextName(owner or object))
    local isWeaponPickup = (owner and owner:IsA("Tool")) or hasAny(itemContext, gunNameWords)
    local remoteName = isWeaponPickup and "Pickup" or "Actionable"
    local remote = state.getDeadRailsLootRemote(remoteName)
    if not remote then
        state.currentLootApi = "No unique " .. remoteName .. " remote"
        return false
    end

    local beforeCount = getInventoryItemCount()
    for attempt = 1, 3 do
        if not object.Parent then
            state.currentLootApi = "ObjectModels." .. remoteName .. " (confirmed)"
            return true
        end
        local ok = pcall(function()
            remote:FireServer(serverEntity)
        end)
        if not ok then
            state.currentLootApi = remoteName .. " remote call failed"
            return false
        end
        state.currentLootApi = "ObjectModels." .. remoteName .. " (attempt " .. attempt .. "/3)"
        task.wait(0.12)
        local itemContainer = state.getItemContainerFolder()
        if not object.Parent or isPlayerInventoryObject(object)
            or (itemContainer and not object:IsDescendantOf(itemContainer))
            or getInventoryItemCount() > beforeCount then
            state.currentLootApi = "ObjectModels." .. remoteName .. " (confirmed)"
            return true
        end
    end
    state.currentLootApi = "ObjectModels." .. remoteName .. " (unconfirmed)"
    return false
end

state.pressPickupKey = function()
    if virtualInput then
        local downOk = pcall(function() virtualInput:SendKeyEvent(true, Enum.KeyCode.F, false, game) end)
        if not downOk then return false end
        task.wait(0.08)
        local upOk = pcall(function() virtualInput:SendKeyEvent(false, Enum.KeyCode.F, false, game) end)
        return upOk
    end
    local keyDown = env.keypress or keypress
    local keyUp = env.keyrelease or keyrelease
    if type(keyDown) == "function" and type(keyUp) == "function" then
        local downOk = pcall(keyDown, 0x46)
        task.wait(0.08)
        local upOk = pcall(keyUp, 0x46)
        return downOk and upOk
    end
    return false
end

local function collectLootObject(object, root, prompt, clickDetector)
    if not object or not object.Parent then return false end
    local attempted = false

    if prompt and prompt.Parent and prompt.Enabled then
        if type(fireproximityprompt) == "function" then
            local ok = pcall(fireproximityprompt, prompt)
            attempted = attempted or ok
            task.wait(0.08)
            if not object.Parent or isPlayerInventoryObject(object) then return true end
        end
        if prompt.Parent and prompt.Enabled then
            local began = pcall(function() prompt:InputHoldBegin() end)
            if began then
                attempted = true
                local holdDuration = 0
                pcall(function() holdDuration = prompt.HoldDuration end)
                task.wait(math.max(0.05, math.min(holdDuration, 5.0)))
                local ended = pcall(function() prompt:InputHoldEnd() end)
                attempted = attempted or ended
                task.wait(0.08)
                if not object.Parent or isPlayerInventoryObject(object) then return true end
            end
        end
    end

    if clickDetector and clickDetector.Parent and type(fireclickdetector) == "function" then
        local ok = pcall(fireclickdetector, clickDetector)
        attempted = attempted or ok
        task.wait(0.08)
        if not object.Parent or isPlayerInventoryObject(object) then return true end
    end

    if game.GameId == 10759337137 then
        -- The visible Last Stop prompt says F / Pick Up. Left mouse is a
        -- separate Grab action, so use the actual pickup key instead of clicking.
        if root and root.Parent then aimLootCamera(root); task.wait(0.05) end
        return attempted or state.pressPickupKey()
    end
    return attempted or clickWorldObject(root)
end

state.summarizeObservedPayload = function(...)
    local values = {}
    for index = 1, math.min(select("#", ...), 8) do
        local value = select(index, ...)
        local kind = typeof(value)
        local summary
        if kind == "Instance" then
            local ok, fullName = pcall(function() return value:GetFullName() end)
            summary = ok and (value.ClassName .. ":" .. fullName) or value.ClassName
        elseif type(value) == "table" then
            local keys = {}
            local count = 0
            for key, item in pairs(value) do
                table.insert(keys, tostring(key) .. "=" .. type(item))
                count = count + 1
                if count >= 8 then break end
            end
            summary = "table{" .. table.concat(keys, ",") .. "}"
        else
            summary = tostring(value)
        end
        table.insert(values, tostring(index) .. ":" .. kind .. "=" .. tostring(summary):sub(1, 110))
    end
    return #values > 0 and table.concat(values, " | ") or "(no arguments)"
end

state.getLastStopServiceRemote = function(serviceName, groupName, remoteName)
    local clientSource = state.replicatedStorage:FindFirstChild("ClientSource")
    local mutual = clientSource and clientSource:FindFirstChild("Mutual")
    local packages = mutual and mutual:FindFirstChild("Packages")
    local knit = packages and packages:FindFirstChild("Knit")
    local services = knit and knit:FindFirstChild("Services")
    local service = services and services:FindFirstChild(serviceName)
    local group = service and service:FindFirstChild(groupName)
    return group and group:FindFirstChild(remoteName) or nil
end

state.connectLastStopTelemetry = function(serviceName, groupName, remoteName, stateKey)
    local clientSource = state.replicatedStorage:FindFirstChild("ClientSource")
    local mutual = clientSource and clientSource:FindFirstChild("Mutual")
    local packages = mutual and mutual:FindFirstChild("Packages")
    local knit = packages and packages:FindFirstChild("Knit")
    local services = knit and knit:FindFirstChild("Services")
    local service = services and services:FindFirstChild(serviceName)
    local group = service and service:FindFirstChild(groupName)
    local remote = group and group:FindFirstChild(remoteName)
    if remote and remote:IsA("RemoteEvent") then
        track(remote.OnClientEvent:Connect(function(...)
            state[stateKey] = state.summarizeObservedPayload(...)
            if serviceName == "MethodService" and remoteName == "MethodCalled" then
                local itemName = select(1, ...)
                local methodName = select(2, ...)
                if type(itemName) == "string" and type(methodName) == "string"
                    and string.lower(methodName) == "oncollected" then
                    state.lastCollectedMethodName = itemName
                    state.lastCollectedMethodAt = os.clock()
                end
            elseif serviceName == "DamageService" and remoteName == "DamageDealt" then
                local hitPosition = select(3, ...)
                if typeof(hitPosition) == "Vector3" then
                    state.lastDamagePosition = hitPosition
                    state.lastDamageEventAt = os.clock()
                end
            elseif serviceName == "DamageService" and remoteName == "EntityKilled" then
                local entityType = select(1, ...)
                if type(entityType) == "string" then
                    state.lastEntityKilledType = entityType
                    state.lastEntityKilledAt = os.clock()
                end
            end
        end))
    end
end

state.connectLastStopTelemetry("DamageService", "RE", "DamageDealt", "lastDamageEventSummary")
state.connectLastStopTelemetry("DamageService", "RE", "EntityKilled", "lastEntityKilledSummary")
state.connectLastStopTelemetry("ProjectileService", "RE", "ProjectileHit", "lastProjectileEventSummary")
state.connectLastStopTelemetry("MethodService", "RE", "MethodCalled", "lastMethodCalledSummary")
state.connectLastStopTelemetry("ItemService", "RE", "InventoryChanged", "lastInventoryChangedSummary")

local function buildRuntimeDiagnostics()
    local lines = {}
    local function add(value)
        table.insert(lines, tostring(value))
    end
    local function addContainerSample(label, container)
        add(label .. ": " .. (container and container:GetFullName() or "not found"))
        if not container then return end
        local shown = 0
        for _, child in ipairs(container:GetChildren()) do
            local _, entityId = findServerEntityOwner(child)
            local displayName = state.getItemDisplayName(child)
            local tooltip = ""
            if child:IsA("Tool") then pcall(function() tooltip = child.ToolTip end) end
            local childSummary = {}
            for _, sub in ipairs(child:GetChildren()) do
                table.insert(childSummary, sub.Name .. ":" .. sub.ClassName)
                if #childSummary >= 8 then break end
            end
            local descendantSummary = {}
            local descOk, childDescendants = pcall(function() return child:GetDescendants() end)
            if descOk then
                for _, sub in ipairs(childDescendants) do
                    local extra = sub.Name .. ":" .. sub.ClassName
                    if sub:IsA("StringValue") then extra = extra .. "=" .. tostring(sub.Value):sub(1, 24) end
                    if sub:IsA("TextLabel") or sub:IsA("TextButton") then
                        local textOk, textValue = pcall(function() return sub.Text end)
                        if textOk and type(textValue) == "string" and textValue ~= "" then
                            extra = extra .. "=\"" .. textValue:gsub("[%c]", " "):sub(1, 32) .. "\""
                        end
                    end
                    table.insert(descendantSummary, extra)
                    if #descendantSummary >= 24 then break end
                end
            end
            local attributes = {}
            local attrOk, attrValues = pcall(function() return child:GetAttributes() end)
            if attrOk and type(attrValues) == "table" then
                for key, value in pairs(attrValues) do
                    table.insert(attributes, tostring(key) .. "=" .. tostring(value):sub(1, 32))
                    if #attributes >= 8 then break end
                end
            end
            local part = getRootPart(child)
            local featureGrab = false
            pcall(function() featureGrab = child:GetAttribute("Feature_Grab") == true end)
            add(string.format("  %s | %s | display=%s | Feature_Grab=%s | tooltip=%s | root=%s | serverEntity=%s | children=%s | attrs=%s",
                child.Name, child.ClassName, displayName, tostring(featureGrab), tostring(tooltip),
                part and (part.Name .. ":" .. tostring(part.Size)) or "nil", tostring(entityId),
                table.concat(childSummary, ","), table.concat(attributes, ",")))
            if #descendantSummary > 0 then add("    descendants=" .. table.concat(descendantSummary, ",")) end
            shown = shown + 1
            if shown >= 25 then break end
        end
    end

    add("LAST STOP TOOLKIT DIAGNOSTICS / V10.5")
    add("PlaceId=" .. tostring(game.PlaceId) .. " GameId=" .. tostring(game.GameId))
    add("Last Stop universe match=" .. tostring(game.GameId == 10759337137))
    add("JobId=" .. tostring(game.JobId))
    add("Melee state=" .. tostring(state.killAura) .. " API=" .. tostring(state.currentAuraApi))
    add("Loot state=" .. tostring(state.autoLoot) .. " API=" .. tostring(state.currentLootApi))
    add(string.format("Loot scan: direct=%d Feature_Grab=%d registered=%d inRange=%d",
        state.lastLootDirectCount, state.lastLootFeatureGrabCount,
        state.lastLootRegisteredCount, state.lastLootInRangeCount))
    add("Last OnCollected=" .. tostring(state.lastCollectedMethodName)
        .. " age=" .. string.format("%.2f", math.max(0, os.clock() - state.lastCollectedMethodAt)))
    add("Last EntityKilled=" .. tostring(state.lastEntityKilledType)
        .. " age=" .. string.format("%.2f", math.max(0, os.clock() - state.lastEntityKilledAt)))
    add("Last Damage position=" .. tostring(state.lastDamagePosition)
        .. " age=" .. string.format("%.2f", math.max(0, os.clock() - state.lastDamageEventAt)))
    add("Gun aim=" .. tostring(state.gunAimAssist) .. " shoot=" .. tostring(state.gunAutoShoot))

    local character = LocalPlayer.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    add("Character tools:")
    if character then
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") then
                add("  Character/" .. child.Name .. " | Identity=" .. state.getItemIdentityText(child)
                    .. " | MeleeConfig=" .. tostring(child:FindFirstChild("MeleeWeaponConfiguration", true) ~= nil)
                    .. " | SwingEvent=" .. tostring(child:FindFirstChild("SwingEvent", true) ~= nil))
            end
        end
    end
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") then
                add("  Backpack/" .. child.Name .. " | Identity=" .. state.getItemIdentityText(child)
                    .. " | MeleeConfig=" .. tostring(child:FindFirstChild("MeleeWeaponConfiguration", true) ~= nil)
                    .. " | SwingEvent=" .. tostring(child:FindFirstChild("SwingEvent", true) ~= nil))
            end
        end
    end

    add("Relevant ReplicatedStorage remotes:")
    local remoteCount = 0
    for _, object in ipairs(state.replicatedStorage:GetDescendants()) do
        if object:IsA("RemoteEvent") or object:IsA("RemoteFunction") then
            local lower = string.lower(object.Name)
            if hasAny(lower, {"swing", "melee", "attack", "hit", "damage", "shoot", "fire", "reload", "pickup", "drop", "action", "store", "loot", "interact", "weapon", "entity", "npc", "health", "state", "death", "died", "spawn", "collect", "grab", "equip", "inventory", "projectile", "item"}) then
                add("  " .. object.ClassName .. " " .. object:GetFullName())
                remoteCount = remoteCount + 1
                if remoteCount >= 100 then break end
            end
        end
    end
    if remoteCount == 0 then add("  none matched") end

    add("Workspace top-level:")
    for index, child in ipairs(Workspace:GetChildren()) do
        add("  " .. child.Name .. " | " .. child.ClassName)
        if index >= 60 then break end
    end
    addContainerSample("ObjectModels (Dead Rails reference)", getObjectModelsFolder())
    addContainerSample("RuntimeItems (Dead Rails reference)", getRuntimeItemsFolder())
    addContainerSample("ITEM_CONTAINER (Last Stop)", state.getItemContainerFolder())

    local entityContainer = state.getLastStopEntityContainer()
    add("ENTITY_CONTAINER (Last Stop): " .. (entityContainer and entityContainer:GetFullName() or "not found"))
    if entityContainer then
        local shownEntities = 0
        for _, entity in ipairs(entityContainer:GetChildren()) do
            if entity:IsA("Model") then
                local motors, ballSockets, animators, tracks = state.getEntityRigEvidence(entity)
                local root = getRootPart(entity)
                local context = state.getLastStopEntityContext(entity)
                local labels = {}
                for _, word in ipairs({"guard", "vampire", "zombie", "bandit", "skeleton", "fred", "anubis", "dracula", "boss", "corpse", "ragdoll"}) do
                    if hasAny(context, {word}) then table.insert(labels, word) end
                end
                add(string.format("  %s | root=%s | parts=%d | Motor6D=%d | BallSocket=%d | Animator=%d | Tracks=%d | labels=%s",
                    entity.Name, root and root.Name or "nil", #entity:GetDescendants(), motors, ballSockets,
                    animators, tracks, table.concat(labels, ",")))
                shownEntities = shownEntities + 1
                if shownEntities >= 20 then break end
            end
        end
        if shownEntities == 0 then add("  no direct Model children") end
    end

    local clientSource = state.replicatedStorage:FindFirstChild("ClientSource")
    local mutual = clientSource and clientSource:FindFirstChild("Mutual")
    local packages = mutual and mutual:FindFirstChild("Packages")
    local knit = packages and packages:FindFirstChild("Knit")
    local services = knit and knit:FindFirstChild("Services")
    add("Last Stop Knit services: " .. (services and services:GetFullName() or "not found"))
    if services then
        local serviceCount = 0
        for _, service in ipairs(services:GetChildren()) do
            local re = service:FindFirstChild("RE")
            local rf = service:FindFirstChild("RF")
            if re or rf then
                local names = {}
                for _, group in ipairs({re, rf}) do
                    if group then
                        for _, remote in ipairs(group:GetChildren()) do
                            table.insert(names, group.Name .. "." .. remote.Name .. "(" .. remote.ClassName .. ")")
                        end
                    end
                end
                add("  " .. service.Name .. " | " .. table.concat(names, ", "))
                serviceCount = serviceCount + 1
                if serviceCount >= 40 then break end
            end
        end
    end
    add("Observed DamageDealt payload: " .. tostring(state.lastDamageEventSummary))
    add("Observed EntityKilled payload: " .. tostring(state.lastEntityKilledSummary))
    add("Observed MethodCalled payload: " .. tostring(state.lastMethodCalledSummary))
    add("Observed InventoryChanged payload: " .. tostring(state.lastInventoryChangedSummary))
    add("Observed ProjectileHit payload: " .. tostring(state.lastProjectileEventSummary))

    add("Pickup prompts:")
    local promptCount = 0
    for _, object in ipairs(Workspace:GetDescendants()) do
        if object:IsA("ProximityPrompt") then
            add(string.format("  %s | action=%s | object=%s | enabled=%s",
                object:GetFullName(), tostring(object.ActionText), tostring(object.ObjectText), tostring(object.Enabled)))
            promptCount = promptCount + 1
            if promptCount >= 40 then break end
        end
    end
    if promptCount == 0 then add("  none found") end

    add("NPC sample:")
    local npcCount = 0
    for model, kind in pairs(auraCandidates) do
        if model and model.Parent then
            local entityName = model:GetAttribute("EntityName")
            local bounty = model:GetAttribute("Bounty")
            local health = getTargetHealth(model)
            local motors, ballSockets, animators, tracks = state.getEntityRigEvidence(model)
            add(string.format("  %s | kind=%s | EntityName=%s | Bounty=%s | health=%s | Motor6D=%d | BallSocket=%d | Animator=%d | Tracks=%d",
                model:GetFullName(), tostring(kind), tostring(entityName), tostring(bounty), tostring(health),
                motors, ballSockets, animators, tracks))
            npcCount = npcCount + 1
            if npcCount >= 30 then break end
        end
    end
    if npcCount == 0 then add("  no aura candidates registered") end
    return table.concat(lines, "\n")
end

local function copyRuntimeDiagnostics()
    local report = buildRuntimeDiagnostics()
    local clipboard = env.setclipboard or env.toclipboard or env.writeclipboard
    if type(clipboard) == "function" then
        local ok = pcall(clipboard, report)
        if ok then
            return true, "Diagnostics copied to clipboard"
        end
    end
    print(report)
    return false, "Clipboard unavailable; diagnostics printed to executor console"
end

state.refreshLastStopLootCandidates = function()
    local container = state.getItemContainerFolder()
    if not container then
        state.lastLootDirectCount = 0
        state.lastLootFeatureGrabCount = 0
        state.lastLootRegisteredCount = 0
        return 0
    end

    local directCount, featureGrabCount, registeredCount = 0, 0, 0
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") or child:IsA("Model") or child:IsA("BasePart") then
            directCount = directCount + 1
            local featureGrab = false
            pcall(function() featureGrab = child:GetAttribute("Feature_Grab") == true end)
            if featureGrab then featureGrabCount = featureGrabCount + 1 end

            local candidate = getLootCandidate(child)
            local itemContext = getContextName(child) .. " " .. state.getItemIdentityText(child)
            if not candidate and featureGrab and not state.lootRejected[child]
                and not isPlayerInventoryObject(child) and not isPlayerCharacter(child)
                and not hasAny(itemContext, friendlyWords)
                and state.isLootCategoryEnabled(itemContext)
                and not state.isExcludedLootCandidate(child, "") then
                -- Feature_Grab is the observed Last Stop pickup flag. This
                -- fallback bypasses GUID/name filters, but retains category and safety exclusions.
                candidate = child
            end
            if candidate and not state.lootRejected[candidate] then
                lootCandidates[candidate] = true
                registeredCount = registeredCount + 1
            end
        end
    end

    state.lastLootDirectCount = directCount
    state.lastLootFeatureGrabCount = featureGrabCount
    state.lastLootRegisteredCount = registeredCount
    return registeredCount
end

local function runAutoLoot()
    local waitingAtBusForManualUnload = false
    local lastContainerRefresh = 0

    while state.running do
        local ok, err = pcall(function()
            if state.autoEmergencyReturn and not state.manualReturnRequested then
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                if humanoid and humanoid.MaxHealth > 0
                    and humanoid.Health / humanoid.MaxHealth <= 0.35 then
                    state.manualReturnRequested = true
                    lootStatus = "Emergency return triggered by low health"
                end
            end
            if state.manualReturnRequested then
                state.manualReturnRequested = false
                local character = LocalPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                if root then
                    local bus, busRoot, seat = findNearestBus(root.Position)
                    local destination = bus and getBusReturnPosition(bus, busRoot, seat) or nil
                    if bus and destination then
                        lootCurrentTarget = bus.Name
                        local returned = teleportRootTo(root, destination, busRoot.Position)
                        lootStatus = returned and "Emergency returned to bus" or "Emergency bus teleport rejected"
                        if returned then
                            lootTeleports = lootTeleports + 1
                        end
                    else
                        lootCurrentTarget = "--"
                        lootStatus = "Emergency return: bus not detected"
                    end
                else
                    lootCurrentTarget = "--"
                    lootStatus = "Emergency return: character unavailable"
                end
                task.wait(0.5)
                return
            end

            if state.manualDiagnosticsRequested then
                state.manualDiagnosticsRequested = false
                local copied, message = copyRuntimeDiagnostics()
                lootStatus = message
                task.wait(0.25)
                return
            end

            if state.manualStoreRequested then
                state.manualStoreRequested = false
                local character = LocalPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                local bus, busRoot
                if root then
                    bus, busRoot = findNearestBus(root.Position)
                end
                if not root or not bus or not busRoot or (busRoot.Position - root.Position).Magnitude > 35 then
                    lootStatus = "Store requires you to stand near the bus"
                else
                    local stored, message = storeAllRuntimeItems()
                    lootStatus = message
                end
                task.wait(0.35)
                return
            end

            if not state.autoLoot then
                lootStatus = "Off"
                state.currentLootApi = "Idle (toggle off)"
                lootCurrentTarget = "--"
                waitingAtBusForManualUnload = false
                task.wait(0.25)
                return
            end

            if game.GameId == 10759337137 and state.autoLoot and os.clock() - lastContainerRefresh >= 0.5 then
                lastContainerRefresh = os.clock()
                state.refreshLastStopLootCandidates()
            end

            if (state.killAura and combatTargetActive) or ((state.gunAimAssist or state.gunAutoShoot) and gunTargetActive) then
                lootStatus = "Paused for combat"
                lootCurrentTarget = state.killAura and currentAuraTargetName or gunTargetName
                task.wait(0.2)
                return
            end

            state.currentLootApi = "Last Stop ITEM_CONTAINER / F Pick Up"
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not humanoid or humanoid.Health <= 0 or not root then
                lootStatus = "Waiting for respawn"
                task.wait(0.3)
                return
            end

            local inventoryCount = getInventoryItemCount()
            if waitingAtBusForManualUnload and not state.autoReturnBus then
                waitingAtBusForManualUnload = false
            end
            if waitingAtBusForManualUnload and state.autoReturnBus then
                if inventoryCount >= state.lootReturnThreshold then
                    lootStatus = "At bus - unload inventory manually"
                    lootCurrentTarget = "Bus"
                    task.wait(1)
                    return
                end
                waitingAtBusForManualUnload = false
                lootCollectedSinceReturn = 0
            end

            local shouldReturn = state.autoReturnBus and inventoryCount >= state.lootReturnThreshold
            local target, targetRoot, distance, prompt, clickDetector, lootCoolingDown
            if not shouldReturn then
                target, targetRoot, distance, prompt, clickDetector, lootCoolingDown = findNearestLoot(root.Position, state.lootRange)
            end
            if not target and not lootCoolingDown and state.autoReturnBus and lootCollectedSinceReturn > 0 then
                shouldReturn = true
            end

            if target and targetRoot then
                lootCurrentTarget = state.getItemDisplayName(target)
                state.currentLootApi = "Last Stop ITEM_CONTAINER / F Pick Up"
                local pickupRange = getLootPickupRange(prompt, clickDetector)

                -- Dead Rails remote adapters are intentionally disabled in the
                -- Last Stop universe. They remain only as optional references for
                -- other games; Last Stop uses ITEM_CONTAINER and the visible F pickup input.
                local directCollected = false
                if game.GameId ~= 10759337137 then
                    if distance <= 30 then
                        directCollected = state.tryDeadRailsServerPickup(target)
                    end
                    if not directCollected and distance <= 10 then
                        directCollected = state.tryDeadRailsRuntimeToolPickup(target)
                    end
                end
                if directCollected or not target.Parent then
                    lootCollected = lootCollected + 1
                    lootCollectedSinceReturn = lootCollectedSinceReturn + 1
                    lootFailedAttempts[target] = nil
                    lootLastAttempt[target] = os.clock() + 999999
                    state.lootRejected[target] = true
                    lootCandidates[target] = nil
                    lootInteractionCache[target] = nil
                    lootStatus = "Direct pickup confirmed: " .. state.getItemDisplayName(target)
                    task.wait(0.12)
                    return
                end

                if distance > pickupRange then
                    lootStatus = "Teleporting to " .. state.getItemDisplayName(target)
                    local teleported = teleportNearLoot(root, target, targetRoot, pickupRange)
                    if teleported then
                        lootTeleports = lootTeleports + 1
                        task.wait(0.08)
                        distance = (targetRoot.Position - root.Position).Magnitude
                    else
                        local failures = math.min(2, (lootFailedAttempts[target] or 0) + 1)
                        lootFailedAttempts[target] = failures
                        lootLastAttempt[target] = os.clock() + (failures >= 2 and 15 or 8)
                        lootStatus = "Teleport rejected; skipping " .. target.Name
                        task.wait(0.25)
                        return
                    end
                end

                if target.Parent and distance <= pickupRange + 0.75 then
                    if not prompt and (not clickDetector or type(fireclickdetector) ~= "function") then
                        aimLootCamera(targetRoot)
                        task.wait(0.05)
                    end

                    lootAttempts = lootAttempts + 1
                    local beforeCount = getInventoryItemCount()
                    local beforeCollectedMethodAt = state.lastCollectedMethodAt
                    local targetDisplayName = state.getItemDisplayName(target)
                    local targetIdentity = state.getItemIdentityText(target)
                    local interacted = collectLootObject(target, targetRoot, prompt, clickDetector)
                    task.wait(0.4)

                    local afterCount = getInventoryItemCount()
                    local movedToInventory = isPlayerInventoryObject(target)
                    local itemContainer = state.getItemContainerFolder()
                    local movedOutOfWorldItems = itemContainer and not target:IsDescendantOf(itemContainer)
                    local methodName = string.lower(state.lastCollectedMethodName or "")
                    local targetNameText = string.lower(targetDisplayName .. " " .. targetIdentity)
                    local methodConfirmed = state.lastCollectedMethodAt > beforeCollectedMethodAt
                        and state.lastCollectedMethodAt >= os.clock() - 1.0
                        and methodName ~= ""
                        and (string.find(targetNameText, methodName, 1, true) ~= nil
                            or string.find(methodName, string.lower(targetDisplayName), 1, true) ~= nil)
                    local collected = not target.Parent or movedToInventory or movedOutOfWorldItems
                        or afterCount > beforeCount or methodConfirmed
                    if collected then
                        lootCollected = lootCollected + 1
                        lootCollectedSinceReturn = lootCollectedSinceReturn + 1
                        lootFailedAttempts[target] = nil
                        lootLastAttempt[target] = os.clock() + 999999
                        state.lootRejected[target] = true
                        lootCandidates[target] = nil
                        lootInteractionCache[target] = nil
                        lootStatus = methodConfirmed and ("Collected " .. state.lastCollectedMethodName .. " (OnCollected)") or ("Collected " .. state.getItemDisplayName(target))
                    else
                        local failures = math.min(2, (lootFailedAttempts[target] or 0) + 1)
                        lootFailedAttempts[target] = failures
                        lootLastAttempt[target] = os.clock() + (failures >= 2 and 15 or 3)
                        if failures >= 2 then
                            lootStatus = "Pickup failed twice; cooldown " .. state.getItemDisplayName(target)
                        elseif not interacted then
                            lootStatus = "No F pickup input; retrying " .. state.getItemDisplayName(target)
                        else
                            lootStatus = "Pickup unconfirmed; retrying " .. state.getItemDisplayName(target)
                        end
                    end
                else
                    local failures = math.min(2, (lootFailedAttempts[target] or 0) + 1)
                    lootFailedAttempts[target] = failures
                    lootLastAttempt[target] = os.clock() + (failures >= 2 and 15 or 8)
                    lootStatus = "Outside safe pickup range; skipped target"
                end

            elseif lootCoolingDown and not shouldReturn then
                lootStatus = "Waiting for pickup retry"
                state.currentLootApi = "ITEM_CONTAINER scanned; waiting for retry"
                task.wait(0.2)

            elseif state.autoReturnBus and shouldReturn then
                local bus, busRoot, seat = findNearestBus(root.Position)
                local destination = bus and getBusReturnPosition(bus, busRoot, seat) or nil
                if bus and destination then
                    lootCurrentTarget = bus.Name
                    local busDistance = (destination - root.Position).Magnitude
                    if busDistance > 8 then
                        lootStatus = string.format("Teleporting to bus (%.0f studs)", busDistance)
                        local teleported = teleportRootTo(root, destination, busRoot.Position)
                        if teleported then
                            lootTeleports = lootTeleports + 1
                            lootCollectedSinceReturn = 0
                            waitingAtBusForManualUnload = shouldReturn
                            lootStatus = shouldReturn and "At bus - unload inventory manually" or "Returned to bus"
                            if state.autoStoreAtBus then
                                local stored, storeMessage = storeAllRuntimeItems()
                                lootStatus = lootStatus .. " | " .. storeMessage
                            end
                        else
                            lootStatus = "Bus teleport rejected by server"
                        end
                        task.wait(0.5)
                    else
                        lootCollectedSinceReturn = 0
                        waitingAtBusForManualUnload = shouldReturn
                        lootStatus = shouldReturn and "At bus - unload inventory manually" or "At bus - sweep complete"
                        if state.autoStoreAtBus then
                            local stored, storeMessage = storeAllRuntimeItems()
                            lootStatus = lootStatus .. " | " .. storeMessage
                        end
                        task.wait(0.8)
                    end
                else
                    lootStatus = "Bus not detected"
                    lootCurrentTarget = "--"
                    task.wait(0.8)
                end
            else
                lootStatus = "No eligible item in ITEM_CONTAINER radius"
                state.currentLootApi = string.format("ITEM_CONTAINER candidates=%d inRange=%d", lootCandidateCount, lootInRangeCount)
                lootCurrentTarget = "--"
                task.wait(0.45)
            end
        end)

        if not ok then
            lootStatus = "Loot error: " .. tostring(err):sub(1, 48)
            task.wait(0.3)
        end
        task.wait(0.08)
    end
end

task.spawn(runAutoLoot)

local function cacheNoClipPart(object)
    if not object or not object:IsA("BasePart") then
        return
    end

    if noClipCache[object] == nil then
        noClipCache[object] = object.CanCollide
    end
    if object.CanCollide then
        pcall(function()
            object.CanCollide = false
        end)
    end
end

local function primeNoClip()
    if not state.noClip then
        return
    end
    local character = LocalPlayer.Character
    if not character then
        return
    end
    for _, object in ipairs(character:GetDescendants()) do
        cacheNoClipPart(object)
    end
end

primeNoClipCallback = primeNoClip

local function applyNoClip()
    if not state.noClip then
        if next(noClipCache) then
            restoreNoClip()
        end
        return
    end

    for part in pairs(noClipCache) do
        if not part or not part.Parent then
            noClipCache[part] = nil
        elseif part.CanCollide then
            pcall(function()
                part.CanCollide = false
            end)
        end
    end
end

local function bindCharacterNoClip(character)
    if characterPartAddedConnection then
        pcall(function() characterPartAddedConnection:Disconnect() end)
        characterPartAddedConnection = nil
    end
    if characterPartRemovingConnection then
        pcall(function() characterPartRemovingConnection:Disconnect() end)
        characterPartRemovingConnection = nil
    end

    restoreNoClip()
    if not character then
        return
    end

    characterPartAddedConnection = character.DescendantAdded:Connect(function(object)
        if state.running and state.noClip then
            cacheNoClipPart(object)
        end
    end)
    characterPartRemovingConnection = character.DescendantRemoving:Connect(function(object)
        local oldValue = noClipCache[object]
        if oldValue ~= nil then
            pcall(function()
                object.CanCollide = oldValue
            end)
            noClipCache[object] = nil
        end
    end)

    if state.noClip then
        primeNoClip()
    end
end

local function applyWalkSpeed()
    if not state.walkSpeed then
        if next(originalWalkSpeeds) then
            restoreWalkSpeed()
        end
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return
    end

    if originalWalkSpeeds[humanoid] == nil then
        originalWalkSpeeds[humanoid] = humanoid.WalkSpeed
    end

    if humanoid.WalkSpeed ~= state.walkSpeedValue then
        pcall(function()
            humanoid.WalkSpeed = state.walkSpeedValue
        end)
    end
end

track(RunService.Stepped:Connect(function()
    if state.running and state.noClip then
        applyNoClip()
    elseif next(noClipCache) then
        restoreNoClip()
    end
end))

track(LocalPlayer.CharacterAdded:Connect(function(character)
    combatTargetActive = false
    gunTargetActive = false
    releaseAuraInput()
    restoreWalkSpeed()
    bindCharacterNoClip(character)
end))

if LocalPlayer.Character then
    bindCharacterNoClip(LocalPlayer.Character)
end

task.spawn(function()
    while state.running do
        if state.walkSpeed then
            applyWalkSpeed()
        elseif next(originalWalkSpeeds) then
            restoreWalkSpeed()
        end
        task.wait(0.15)
    end
    restoreWalkSpeed()
end)

local function scanWorld()
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    local cameraPosition = camera.CFrame.Position
    local seen = {}
    local count = 0

    for _, instance in ipairs(Workspace:GetDescendants()) do
        if instance:IsA("Model") or instance:IsA("BasePart") or instance:IsA("Tool") then
            local shouldSkip = false

            if instance:IsA("BasePart") then
                if instance:FindFirstAncestorOfClass("Model")
                    or instance:FindFirstAncestorWhichIsA("Tool") then
                    shouldSkip = true
                end
            elseif instance:IsA("Model") then
                if instance:FindFirstAncestorOfClass("Model") then
                    shouldSkip = true
                end
            end

            if not shouldSkip and not isPlayerCharacter(instance) then
                local kind = classify(instance)
                if kind and isEnabled(kind) then
                    local root = getRootPart(instance)
                    if root and (root.Position - cameraPosition).Magnitude <= state.maxDistance then
                        seen[instance] = true
                        count = count + 1

                        local displayName = kind == "loot"
                            and state.getItemDisplayName(instance) or instance.Name
                        if not markers[instance] then
                            local marker = createMarker(instance, kind, displayName)
                            if marker then markers[instance] = marker end
                        else
                            markers[instance].kind = kind
                            markers[instance].displayName = displayName
                        end
                    end
                end
            end
        end
    end

    if state.players then
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character then
                local character = player.Character
                local root = getRootPart(character)
                if root and (root.Position - cameraPosition).Magnitude <= state.maxDistance then
                    seen[character] = true
                    count = count + 1
                    if not markers[character] then
                        local marker = createMarker(character, "player", player.Name)
                        if marker then
                            markers[character] = marker
                        end
                    else
                        markers[character].displayName = player.Name
                    end
                end
            end
        end
    end

    for instance in pairs(markers) do
        if not seen[instance] then
            destroyMarker(instance)
        end
    end

    lastScanCount = count
    if statusLabel then
        statusLabel.Text = string.format("Tracking %d objects  |  RightShift: hide menu", count)
    end
end

local function updateHud()
    if not hudFrame or not hudLabel then
        return
    end

    hudFrame.Visible = state.hud
    if not state.hud then
        return
    end

    local healthText = "HP --/--"
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        healthText = string.format("HP %.0f/%.0f", humanoid.Health, humanoid.MaxHealth)
    end

    local visibleLootCandidates = 0
    for candidate in pairs(lootCandidates) do
        if candidate and candidate.Parent and candidate:IsDescendantOf(Workspace) then
            visibleLootCandidates = visibleLootCandidates + 1
        end
    end
    lootCandidateCount = visibleLootCandidates

    hudLabel.Text = string.format(
        "%s  |  Players %d\nESP: %d  |  NPCs: %d\nMelee: %s  |  Weapon: %s\nMelee API: %s  |  Hits: %d  |  Requests: %d\nGun: %s  |  Target: %s\nGun API: %s  |  Inputs: %d  |  Hits: %d  |  Blocked: %d\nLoot: %s  |  Looted: %d  |  TPs: %d\nLoot API: %s\nAttempts: %d  |  Target: %s  |  Candidates: %d",
        healthText,
        #Players:GetPlayers(),
        lastScanCount,
        (function()
            local count = 0
            for _ in pairs(auraCandidates) do
                count = count + 1
            end
            return count
        end)(),
        currentAuraStatus,
        currentAuraWeapon,
        state.currentAuraApi,
        auraConfirmedHits,
        auraAttackAttempts,
        gunStatus,
        gunTargetName,
        state.currentGunApi,
        gunShots,
        gunConfirmedHits,
        gunBlockedShots,
        lootStatus,
        lootCollected,
        lootTeleports,
        state.currentLootApi,
        lootAttempts,
        lootCurrentTarget,
        lootCandidateCount
    )
end

-- Keep newly-added visual effects disabled while performance mode is active.
track(Workspace.DescendantAdded:Connect(function(object)
    if state.performance then
        disableEffect(object)
    end
end))
track(Lighting.DescendantAdded:Connect(function(object)
    if state.performance then
        disableEffect(object)
    end
end))

-- Keep existing markers' distance labels and visibility responsive between scans.
task.spawn(function()
    while state.running do
        local camera = Workspace.CurrentCamera
        if camera then
            local cameraPosition = camera.CFrame.Position
            for instance, marker in pairs(markers) do
                if not updateMarker(instance, marker, cameraPosition) then
                    destroyMarker(instance)
                end
            end
        end
        updateHud()
        task.wait(0.2)
    end
end)

-- World scanning is deliberately throttled to avoid a full descendant scan every frame.
task.spawn(function()
    while state.running do
        local ok, err = pcall(scanWorld)
        if not ok and statusLabel then
            statusLabel.Text = "Scan hiccup: " .. tostring(err):sub(1, 55)
        end
        task.wait(state.scanInterval)
    end
end)

updateHud()
if statusLabel then
    statusLabel.Text = "Ready  |  RightShift: hide menu"
end
