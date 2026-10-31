--[[
    LAST STOP [BETA] - ROADSIDE TOOLKIT v6
    Client-side survival toolkit.

    Included:
      * Loot / pickup ESP (name + distance)
      * Zombie ESP and boss ESP
      * Teammate ESP (off by default)
      * 360-degree hostile target acquisition with optional auto-approach
      * Auto-loot pickup routing and return-to-bus navigation
      * Local no-clip and walk-speed controls with restoration on unload
      * Dedicated unload button and local health / player-count / aura HUD
      * Reversible low-effects mode
      * Draggable, collapsible UI
      * RightShift toggles the menu

    The aura excludes player characters and known friendly NPCs. It supports
    named custom NPC models without Humanoids, recognizes Last Stop's visible
    Swing prompt, and holds native mouse input once within normal melee reach.
    The aura range is an acquisition/chase radius, not a server-side hitbox edit.
    Auto-loot uses visible pickup interactions and pathfinding; no guessed remotes.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
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
    auraFace = true,
    auraAimCamera = true,
    auraApproach = true,
    auraHitRange = 6.5,
    auraRange = 120,
    auraInterval = 0.02,
    autoLoot = false,
    autoReturnBus = true,
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
local lootLastAttempt = setmetatable({}, {__mode = "k"})
local lootMovementToken = 0
local activeAutomationHumanoid = nil
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
    lootMovementToken = lootMovementToken + 1
    if characterPartAddedConnection then
        pcall(function() characterPartAddedConnection:Disconnect() end)
        characterPartAddedConnection = nil
    end
    if characterPartRemovingConnection then
        pcall(function() characterPartRemovingConnection:Disconnect() end)
        characterPartRemovingConnection = nil
    end
    if activeAutomationHumanoid then
        pcall(function()
            activeAutomationHumanoid:Move(Vector3.zero, false)
        end)
        activeAutomationHumanoid = nil
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
    table.clear(auraCandidates)
    table.clear(auraRegistrationPending)
    table.clear(lootCandidates)
    table.clear(lootRegistrationPending)
    table.clear(lootInteractionCache)
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
    Text = "CLIENT-SIDE SURVIVAL TOOLKIT  /  V6",
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
        Text = "Aura target / chase range",
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
        Text = "Fallback click interval",
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
        state.auraInterval = math.max(0.02, math.floor((state.auraInterval - 0.01) * 100 + 0.5) / 100)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.auraInterval = math.min(1.50, math.floor((state.auraInterval + 0.01) * 100 + 0.5) / 100)
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
addToggle("Zombie / enemy kill aura", "killAura", "Holds the native Swing input against nearby hostile NPCs")
addToggle("Include bosses", "auraBosses", "Includes Fred, Anubis, Dracula, Crystalus and Juggernaut")
addToggle("Target unknown NPCs", "auraAllNPCs", "Fallback detection; known friendly NPCs are excluded")
addToggle("Auto-equip melee", "autoEquipMelee", "Equips an available melee tool when none is equipped")
addToggle("Auto-face target", "auraFace", "Turns your character toward the nearest valid target")
addToggle("Aim camera at target", "auraAimCamera", "Turns the view toward targets outside your current aim")
addToggle("Auto-approach targets", "auraApproach", "Moves into melee reach; range is target acquisition, not hitbox reach")
addAuraRangeControl()
addAttackDelayControl()

addSection("Automation")
addToggle("Auto loot nearby items", "autoLoot", "Walks to eligible pickups and collects them")
addToggle("Return to bus when done", "autoReturnBus", "Returns after a loot sweep or when the tool-count threshold is reached")
addLootRangeControl()
addLootReturnThresholdControl()

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
    Size = UDim2.new(0, 410, 0, 112),
    Position = UDim2.new(1, -425, 0, 18),
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
    Text = "HP --/--  |  Players --\nESP: 0  |  NPCs: 0  |  Aura: Off\nWeapon: --  |  Target: --\nHits: 0  |  Inputs: 0  |  Loot: Off\nLooted: 0  |  Attempts: 0  |  Target: --",
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
    "loot", "pickup", "drop", "item", "fuel", "gas can", "gasoline", "wood",
    "scrap", "ammo", "bullet", "med", "bandage", "food", "water", "wheel",
    "tire", "battery", "weapon", "gun", "rifle", "pistol", "revolver", "shotgun",
    "key", "cure", "potion", "cash", "ticket", "crate", "material", "metal",
    "coal", "pipe", "armor", "vest", "flashlight", "fuse", "engine", "canister"
}

local lootFolderWords = {"loot", "drops", "pickups", "worlditems", "items"}

local function hasAny(text, words)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

local function getContextName(instance)
    local names = {string.lower(instance.Name)}
    local parent = instance.Parent
    for _ = 1, 7 do
        if not parent then
            break
        end
        table.insert(names, string.lower(parent.Name))
        parent = parent.Parent
    end
    return table.concat(names, " ")
end

local function classify(instance)
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
    local context = getContextName(instance)
    if hasAny(context, friendlyWords) then
        return nil
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
        if handle and handle:IsA("BasePart") then
            return handle
        end
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
    "scythe", "sledgehammer", "chainsaw", "pipe"
}

local function isMeleeTool(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end

    local toolName = string.lower(tool.Name)
    local ok, isMelee = pcall(function()
        return tool:GetAttribute("IsMelee")
    end)
    if ok and isMelee == true then
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

    local name = string.lower(tool.Name)
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
            local name = string.lower(object.Name)
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
        return true, (uiWeaponName or "Melee") .. " (Swing prompt)", nil
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

local function beginAuraAttack(tool, targetRoot)
    if not targetRoot or isPointerOverToolkit() then
        return false
    end

    if attackInputHeld then
        return true
    end

    local camera = Workspace.CurrentCamera
    if virtualInput and camera then
        local screenPosition, onScreen = camera:WorldToScreenPoint(targetRoot.Position)
        if onScreen and isScreenPointOverToolkit(screenPosition.X, screenPosition.Y) then
            return false
        end
        if onScreen then
            local ok = pcall(function()
                virtualInput:SendMouseMoveEvent(screenPosition.X, screenPosition.Y, game)
                virtualInput:SendMouseButtonEvent(screenPosition.X, screenPosition.Y, 0, true, game, 0)
            end)
            if ok then
                attackInputHeld = true
                attackInputKind = "virtual hold"
                attackInputPosition = Vector2.new(screenPosition.X, screenPosition.Y)
                currentAuraInput = "held click"
                auraAttackAttempts = auraAttackAttempts + 1
                return true
            end
        end
    end

    if type(mousePress) == "function" and type(mouseRelease) == "function" then
        local ok = pcall(mousePress)
        if ok then
            attackInputHeld = true
            attackInputKind = "executor hold"
            currentAuraInput = "held mouse1"
            auraAttackAttempts = auraAttackAttempts + 1
            return true
        end
    end

    -- Last-resort compatibility path for executors that expose click-only input.
    if type(mouseClick) == "function" then
        local ok = pcall(mouseClick)
        if ok then
            currentAuraInput = "click fallback"
            auraAttackAttempts = auraAttackAttempts + 1
            lastAuraAttack = os.clock()
            return true
        end
    end

    if tool then
        local ok = pcall(function()
            tool:Activate()
        end)
        if ok then
            currentAuraInput = "Tool:Activate fallback"
            auraAttackAttempts = auraAttackAttempts + 1
            lastAuraAttack = os.clock()
            return true
        end
    end

    return false
end

local function updateHeldAuraAim(targetRoot)
    if not attackInputHeld or attackInputKind ~= "virtual hold" or not virtualInput or not targetRoot then
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    local point, onScreen = camera:WorldToScreenPoint(targetRoot.Position)
    if not onScreen or isScreenPointOverToolkit(point.X, point.Y) then
        releaseAuraInput()
        return
    end

    local ok = pcall(function()
        virtualInput:SendMouseMoveEvent(point.X, point.Y, game)
    end)
    if ok then
        attackInputPosition = Vector2.new(point.X, point.Y)
    end
end

local targetHealthValueCache = setmetatable({}, {__mode = "k"})
local targetHealthScanAt = setmetatable({}, {__mode = "k"})

local function getTargetHealth(model)
    local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
    if humanoid then
        return humanoid.Health
    end

    local attributeNames = {"Health", "HP", "CurrentHealth", "CurrentHP", "health", "hp"}
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
        return cachedValue.Value
    end
    if cachedValue == false and os.clock() - (targetHealthScanAt[model] or 0) < 1 then
        return nil
    end

    targetHealthScanAt[model] = os.clock()
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("NumberValue") or object:IsA("IntValue") then
            local name = string.lower(object.Name)
            if hasAny(name, {"health", "hp", "currenthealth", "currenthp"}) then
                targetHealthValueCache[model] = object
                return object.Value
            end
        end
    end

    targetHealthValueCache[model] = false
    return nil
end

local function isTargetDead(model)
    local deadAttribute = nil
    pcall(function()
        deadAttribute = model:GetAttribute("Dead")
    end)
    if deadAttribute == true then
        return true
    end

    local deadValue = model:FindFirstChild("Dead", true)
    if deadValue and deadValue:IsA("BoolValue") and deadValue.Value then
        return true
    end

    local health = getTargetHealth(model)
    return health ~= nil and health <= 0
end

local function findAuraModel(instance)
    local current = instance
    local hostilePart = nil

    while current and current ~= Workspace do
        if current:IsA("Model") and getRootPart(current) then
            local context = getContextName(current)
            if not hasAny(context, friendlyWords) then
                local kind = classifyAura(current)
                if kind then
                    return current
                end

                local hasHumanoid = current:FindFirstChildWhichIsA("Humanoid", true) ~= nil
                local isNpcContainer = hasAny(context, npcContainerWords)
                if hasHumanoid or isNpcContainer or getTargetHealth(current) ~= nil then
                    return current
                end
            end
        elseif current:IsA("BasePart") then
            local context = getContextName(current)
            if hasAny(context, zombieWords) or hasAny(context, bossWords)
                or hasAny(context, npcContainerWords) then
                hostilePart = current
            end
        end
        current = current.Parent
    end

    return hostilePart
end

local function registerAuraCandidate(instance)
    local model = findAuraModel(instance)
    if not model or isPlayerCharacter(model) then
        return
    end

    local context = getContextName(model)
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
    local isNpcContainer = hasAny(context, npcContainerWords)
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

    for model in pairs(auraCandidates) do
        if not model or not model.Parent then
            auraCandidates[model] = nil
        else
            local root = getRootPart(model)
            local context = getContextName(model)

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
                        local distance = (root.Position - characterRoot.Position).Magnitude
                        if distance <= bestDistance then
                            bestDistance = distance
                            bestModel = model
                            bestRoot = root
                            bestKind = kind
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

    local name = string.lower(instance.Name)
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
end))

local function runKillAura()
    local trackedTarget = nil
    local trackedHealth = nil
    local approachTarget = nil
    local lastApproachMove = 0
    local lastEquipAttempt = 0

    while state.running do
        local stepOk, stepError = pcall(function()
        if state.killAura then
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
            local meleeReady, weaponName, meleeTool = getMeleeReady(character)

            currentAuraWeapon = weaponName or "Not detected"

            if not humanoid or humanoid.Health <= 0 or not characterRoot then
                combatTargetActive = false
                currentAuraStatus = "Waiting for respawn"
                currentAuraTargetName = "--"
                releaseAuraInput()
                trackedTarget = nil
                trackedHealth = nil
            else
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

                local target, targetRoot, targetKind, distance = getNearestAuraTarget(characterRoot)
                if target and targetRoot then
                    combatTargetActive = true
                    currentAuraTargetName = target.Name
                    local targetDistance = (targetRoot.Position - characterRoot.Position).Magnitude
                    if activeAutomationHumanoid == humanoid then
                        lootMovementToken = lootMovementToken + 1
                        if not state.auraApproach or targetDistance <= state.auraHitRange then
                            pcall(function()
                                humanoid:MoveTo(characterRoot.Position)
                            end)
                        end
                        activeAutomationHumanoid = nil
                    end
                    faceAuraTarget(character, targetRoot)
                    aimAuraCamera(targetRoot)
                    updateHeldAuraAim(targetRoot)

                    if trackedTarget ~= target then
                        releaseAuraInput()
                        end

                    local healthNow = getTargetHealth(target)
                    if trackedTarget ~= target then
                        trackedTarget = target
                        trackedHealth = healthNow
                    elseif healthNow ~= nil and trackedHealth ~= nil then
                        if healthNow < trackedHealth then
                            auraConfirmedHits = auraConfirmedHits + 1
                        end
                        trackedHealth = healthNow
                    end

                    if distance > state.auraHitRange and state.auraApproach then
                        releaseAuraInput()
                        currentAuraInput = "approaching"
                        currentAuraStatus = string.format("Chasing %s (%.0f / %.0f)", target.Name, distance, state.auraRange)
                        if not humanoid.SeatPart and (approachTarget ~= target or os.clock() - lastApproachMove >= 0.25) then
                            pcall(function()
                                humanoid:MoveTo(targetRoot.Position)
                            end)
                            approachTarget = target
                            lastApproachMove = os.clock()
                        end
                    elseif distance > state.auraHitRange then
                        releaseAuraInput()
                        if approachTarget then
                            pcall(function()
                                humanoid:MoveTo(characterRoot.Position)
                            end)
                            approachTarget = nil
                        end
                        currentAuraStatus = string.format("Out of melee reach (%.1f studs)", distance)
                    elseif meleeReady then
                            if approachTarget then
                            pcall(function()
                                humanoid:MoveTo(characterRoot.Position)
                            end)
                            approachTarget = nil
                        end
                        if isPointerOverToolkit() then
                            releaseAuraInput()
                            currentAuraStatus = "Move cursor off toolkit"
                        elseif not attackInputHeld and os.clock() - lastAuraAttack >= state.auraInterval then
                            local sent = beginAuraAttack(meleeTool, targetRoot)
                            if sent then
                                lastAuraAttack = os.clock()
                                currentAuraStatus = string.format("Swinging %s (%.1f studs)", targetKind, distance)
                            else
                                currentAuraStatus = "Swing input unavailable"
                            end
                        else
                            currentAuraStatus = string.format("Holding on %s (%.1f studs)", target.Name, distance)
                        end
                    else
                        releaseAuraInput()
                        currentAuraStatus = "No Swing prompt; equip the Shovel"
                    end
                else
                    combatTargetActive = false
                    releaseAuraInput()
                    if approachTarget then
                        pcall(function()
                            humanoid:MoveTo(characterRoot.Position)
                        end)
                        approachTarget = nil
                    end
                    currentAuraTargetName = "--"
                    trackedTarget = nil
                    trackedHealth = nil
                    currentAuraStatus = state.auraAllNPCs and "No NPC in range" or "No recognized hostile in range"
                end
            end
        else
            combatTargetActive = false
            releaseAuraInput()
            if approachTarget then
                local character = LocalPlayer.Character
                local root = character and character:FindFirstChild("HumanoidRootPart")
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                if humanoid and root then
                    pcall(function()
                        humanoid:MoveTo(root.Position)
                    end)
                end
                approachTarget = nil
            end
            currentAuraStatus = "Off"
            currentAuraTargetName = "--"
            currentAuraWeapon = "--"
        end

        end)
        if not stepOk then
            releaseAuraInput()
            combatTargetActive = false
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if humanoid and root then
                pcall(function() humanoid:MoveTo(root.Position) end)
            end
            approachTarget = nil
            currentAuraStatus = "Aura error: " .. tostring(stepError):sub(1, 45)
        end
        task.wait(0.04)
    end

    releaseAuraInput()
end

task.spawn(runKillAura)

-- Auto-loot uses the game's visible pickup interactions (prompts, click detectors,
-- or the documented click-to-grab action). It does not guess or invoke game remotes.
local lootNameWords = {
    "gascan", "gas can", "gasoline", "fuel", "coal", "wood", "scrap",
    "duct tape", "tape", "spring", "metal pipe", "pipe", "ammo", "bullet",
    "bandage", "medkit", "apple", "coke", "chocolate", "cake", "food",
    "water", "rope", "wheel", "tire", "battery", "shovel", "sword",
    "knife", "axe", "machete", "revolver", "shotgun", "rifle", "pistol",
    "flashlight", "lantern", "candle", "cure", "potion", "carved bust",
    "statue", "valuable", "scrap metal", "engine part", "fuse", "canister",
    "crate", "box", "supply", "lootbox", "globe", "artifact", "antique",
    "cash", "ticket", "coin", "gold", "silver", "jewelry", "watch", "medallion",
    "quest item", "medical", "meds"
}
local pickupActionWords = {"grab", "pick up", "pickup", "collect", "take"}

local function isInsideLootFolder(instance)
    local parent = instance and instance.Parent
    for _ = 1, 5 do
        if not parent then
            break
        end
        local name = string.lower(parent.Name)
        if name == "loot" or name == "items" or name == "drops"
            or name == "pickups" or name == "worlditems" or name == "looseitems" then
            return true
        end
        parent = parent.Parent
    end
    return false
end

local function isLootName(instance)
    local name = string.lower(instance.Name)
    if hasAny(name, lootNameWords) then
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

    if instance:IsA("ProximityPrompt") then
        local action = string.lower((instance.ActionText or "") .. " " .. (instance.ObjectText or ""))
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

    if not candidate or not candidate.Parent or not candidate:IsDescendantOf(Workspace)
        or isPlayerInventoryObject(candidate) or isPlayerCharacter(candidate) then
        return nil
    end

    local name = string.lower(candidate.Name)
    if hasAny(name, {"bus", "vehicle", "building", "house", "terminal"}) and not isLootName(candidate) then
        return nil
    end

    local context = getContextName(candidate)
    if hasAny(context, friendlyWords) or classifyAura(candidate) then
        return nil
    end

    local ancestor = candidate.Parent
    for _ = 1, 5 do
        if not ancestor then
            break
        end
        if hasAny(string.lower(ancestor.Name), {"bus", "vehicle"}) then
            return nil
        end
        ancestor = ancestor.Parent
    end

    if not fromPickupPrompt and not isLootName(candidate) and not isInsideLootFolder(candidate) then
        return nil
    end

    return candidate
end

local function queueLootRegistration(instance)
    if not instance:IsA("Model") and not instance:IsA("Tool") and not instance:IsA("BasePart")
        and not instance:IsA("ProximityPrompt") and not instance:IsA("ClickDetector") then
        return
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
    if not candidate or lootRegistrationPending[candidate] then
        return
    end

    lootRegistrationPending[candidate] = true
    task.delay(0.12, function()
        lootRegistrationPending[candidate] = nil
        if state.running and candidate.Parent and candidate:IsDescendantOf(Workspace) then
            local valid = getLootCandidate(candidate)
            if not valid then
                local prompt, clickDetector = getLootInteraction(candidate)
                if prompt or clickDetector then
                    valid = candidate
                end
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
    local coolingDown = false

    for candidate in pairs(lootCandidates) do
        if not candidate or not candidate.Parent or not candidate:IsDescendantOf(Workspace) then
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
                if distance <= maxDistance then
                    count = count + 1
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

local function moveAutomationTo(humanoid, root, destination, token, requireBusReturn, arrivalDistance)
    if not humanoid or not root or not destination then
        return false
    end

    arrivalDistance = math.max(3, arrivalDistance or 7)
    activeAutomationHumanoid = humanoid
    local pathOk, path = pcall(function()
        return PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentCanClimb = true,
            WaypointSpacing = 5,
        })
    end)

    local computed = false
    if pathOk and path then
        computed = pcall(function()
            path:ComputeAsync(root.Position, destination)
        end)
    end

    if computed and pathOk and path and path.Status == Enum.PathStatus.Success then
        for _, waypoint in ipairs(path:GetWaypoints()) do
            if not state.running or not state.autoLoot or token ~= lootMovementToken
                or (requireBusReturn and not state.autoReturnBus)
                or (state.killAura and combatTargetActive) then
                return false
            end
            if (root.Position - destination).Magnitude <= arrivalDistance then
                return true
            end
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                humanoid.Jump = true
            end

            local finished = false
            local reached = false
            local connection = humanoid.MoveToFinished:Connect(function(success)
                finished = true
                reached = success
            end)
            humanoid:MoveTo(waypoint.Position)
            local deadline = os.clock() + 4
            while state.running and state.autoLoot and token == lootMovementToken
                and not (requireBusReturn and not state.autoReturnBus)
                and not (state.killAura and combatTargetActive)
                and not finished and os.clock() < deadline do
                task.wait(0.05)
            end
            connection:Disconnect()
            if not finished or not reached then
                break
            end
        end

        if (root.Position - destination).Magnitude <= arrivalDistance then
            return true
        end
    end

    -- Fallback for simple open areas or games whose navmesh does not include the pickup.
    if state.running and state.autoLoot and token == lootMovementToken
        and not (requireBusReturn and not state.autoReturnBus)
        and not (state.killAura and combatTargetActive) then
        humanoid:MoveTo(destination)
        local deadline = os.clock() + 7
        while state.running and state.autoLoot and token == lootMovementToken
            and not (requireBusReturn and not state.autoReturnBus)
            and not (state.killAura and combatTargetActive)
            and os.clock() < deadline do
            if (root.Position - destination).Magnitude <= arrivalDistance then
                return true
            end
            task.wait(0.1)
        end
    end

    return (root.Position - destination).Magnitude <= arrivalDistance
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

local function collectLootObject(object, root, prompt, clickDetector)
    if not object or not object.Parent then
        return false
    end

    if prompt and prompt.Parent and prompt.Enabled then
        if type(fireproximityprompt) == "function" then
            local ok = pcall(fireproximityprompt, prompt)
            if ok then
                return true
            end
        end
        local oldDuration = prompt.HoldDuration
        local began = pcall(function()
            prompt:InputHoldBegin()
        end)
        if not began then
            return false
        end
        task.wait(math.max(0.05, math.min(oldDuration, 1.0)))
        local ended = pcall(function()
            prompt:InputHoldEnd()
        end)
        return ended
    end

    if clickDetector and clickDetector.Parent and type(fireclickdetector) == "function" then
        local ok = pcall(fireclickdetector, clickDetector)
        if ok then
            return true
        end
    end

    return clickWorldObject(root)
end

local function runAutoLoot()
    while state.running do
        local ok, err = pcall(function()
            if not state.autoLoot then
                lootStatus = "Off"
                lootCurrentTarget = "--"
                lootMovementToken = lootMovementToken + 1
                if activeAutomationHumanoid then
                    pcall(function()
                        activeAutomationHumanoid:Move(Vector3.zero, false)
                    end)
                    activeAutomationHumanoid = nil
                end
                task.wait(0.25)
                return
            end

            if state.killAura and combatTargetActive then
                lootMovementToken = lootMovementToken + 1
                activeAutomationHumanoid = nil
                lootStatus = "Paused for combat"
                lootCurrentTarget = currentAuraTargetName
                task.wait(0.2)
                return
            end

            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")

            if not humanoid or humanoid.Health <= 0 or not root then
                lootStatus = "Waiting for respawn"
                task.wait(0.3)
                return
            end

            local inventoryCount = getInventoryItemCount()
            local shouldReturn = state.autoReturnBus and inventoryCount >= state.lootReturnThreshold
            local target, targetRoot, distance, prompt, clickDetector, lootCoolingDown

            if not shouldReturn then
                target, targetRoot, distance, prompt, clickDetector, lootCoolingDown = findNearestLoot(root.Position, state.lootRange)
            end

            if target and targetRoot then
                lootCurrentTarget = target.Name
                local pickupRange = getLootPickupRange(prompt, clickDetector)
                if distance > pickupRange then
                    lootStatus = string.format("Approaching %s (%.0f studs)", target.Name, distance)
                    lootMovementToken = lootMovementToken + 1
                    local token = lootMovementToken
                    local moved = moveAutomationTo(humanoid, root, targetRoot.Position, token, false, pickupRange)
                    if not moved and target.Parent and not (state.killAura and combatTargetActive) then
                        lootLastAttempt[target] = os.clock()
                        lootStatus = "Path blocked: " .. target.Name
                    end
                else
                    lootStatus = "Picking up " .. target.Name
                    if not prompt and (not clickDetector or type(fireclickdetector) ~= "function") then
                        aimLootCamera(targetRoot)
                    end
                    lootAttempts = lootAttempts + 1
                    local beforeCount = getInventoryItemCount()
                    local interacted = collectLootObject(target, targetRoot, prompt, clickDetector)
                    lootLastAttempt[target] = interacted and os.clock() or (os.clock() - 1.0)
                    task.wait(0.35)
                    local afterCount = getInventoryItemCount()
                    local movedToInventory = isPlayerInventoryObject(target)
                    if not target.Parent or movedToInventory or afterCount > beforeCount then
                        lootCollected = lootCollected + 1
                        lootCollectedSinceReturn = lootCollectedSinceReturn + 1
                        lootStatus = "Collected " .. target.Name
                    elseif not interacted then
                        lootStatus = "No pickup input: " .. target.Name
                    else
                        lootStatus = "Pickup not confirmed: " .. target.Name
                    end
                end
            elseif lootCoolingDown then
                lootStatus = "Waiting to retry pickup"
                task.wait(0.2)
            elseif state.autoReturnBus and (shouldReturn or lootCollectedSinceReturn > 0) then
                local bus, busRoot, seat = findNearestBus(root.Position)
                local destination = bus and getBusReturnPosition(bus, busRoot, seat) or nil
                if bus and destination then
                    lootCurrentTarget = bus.Name
                    local busDistance = (destination - root.Position).Magnitude
                    if busDistance > 8 then
                        lootStatus = string.format("Returning to bus (%.0f studs)", busDistance)
                        lootMovementToken = lootMovementToken + 1
                        local token = lootMovementToken
                        local moved = moveAutomationTo(humanoid, root, destination, token, true)
                        if not moved and not (state.killAura and combatTargetActive) then
                            if not state.autoReturnBus then
                                pcall(function() humanoid:MoveTo(root.Position) end)
                                activeAutomationHumanoid = nil
                                lootStatus = "Return cancelled"
                            else
                                lootStatus = "Could not reach bus"
                            end
                        end
                    else
                        lootCollectedSinceReturn = 0
                        if shouldReturn then
                            lootStatus = "At bus - unload inventory manually"
                        else
                            lootStatus = "At bus - sweep complete"
                        end
                        pcall(function()
                            humanoid:MoveTo(root.Position)
                        end)
                        task.wait(0.8)
                    end
                else
                    lootStatus = "Bus not detected"
                    lootCurrentTarget = "--"
                    task.wait(0.8)
                end
            else
                lootStatus = "No loot in radius"
                lootCurrentTarget = "--"
                task.wait(0.45)
            end
        end)

        if not ok then
            lootMovementToken = lootMovementToken + 1
            if not (state.killAura and combatTargetActive) then
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local root = character and character:FindFirstChild("HumanoidRootPart")
                if humanoid and root then
                    pcall(function() humanoid:MoveTo(root.Position) end)
                end
                activeAutomationHumanoid = nil
            end
            lootStatus = "Loot error: " .. tostring(err):sub(1, 48)
            task.wait(0.3)
        end
        task.wait(0.08)
    end

    if activeAutomationHumanoid then
        pcall(function()
            activeAutomationHumanoid:Move(Vector3.zero, false)
        end)
        activeAutomationHumanoid = nil
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
    lootMovementToken = lootMovementToken + 1
    activeAutomationHumanoid = nil
    combatTargetActive = false
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

                        if not markers[instance] then
                            local displayName = instance.Name
                            local marker = createMarker(instance, kind, displayName)
                            if marker then
                                markers[instance] = marker
                            end
                        else
                            markers[instance].kind = kind
                            markers[instance].displayName = instance.Name
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

    hudLabel.Text = string.format(
        "%s  |  Players %d\nESP: %d  |  NPCs: %d  |  Aura: %s\nWeapon: %s  |  Target: %s\nHP drops: %d  |  Input sessions: %d  |  %s\nLoot: %s\nLooted: %d  |  Attempts: %d  |  Target: %s  |  Candidates: %d",
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
        currentAuraTargetName,
        auraConfirmedHits,
        auraAttackAttempts,
        currentAuraInput,
        lootStatus,
        lootCollected,
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
