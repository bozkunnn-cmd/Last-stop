--[[
    LAST STOP [BETA] - ROADSIDE TOOLKIT
    Client-side survival toolkit.

    Included:
      * Loot / pickup ESP (name + distance)
      * Zombie ESP and boss ESP
      * Teammate ESP (off by default)
      * Configurable NPC melee auto-attack with broad hostile detection
      * Local no-clip and walk-speed controls with restoration on unload
      * Dedicated unload button and local health / player-count / aura HUD
      * Reversible low-effects mode
      * Draggable, collapsible UI
      * RightShift toggles the menu

    The aura excludes player characters and known friendly NPCs. It uses
    target-screen click pulses, executor click helpers, or Tool:Activate().
    No guessed RemoteEvent calls or server-side damage edits are included.
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
        env = getgenv()
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
    auraRange = 16,
    auraInterval = 0.45,
    noClip = false,
    walkSpeed = false,
    walkSpeedValue = 28,
    maxDistance = 1000,
    scanInterval = 2.0,
}

local connections = {}
local markers = {}
local auraCandidates = {}
local auraRegistrationPending = {}
local currentAuraStatus = "Off"
local lastAuraAttack = 0
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

    local ok, coreGui = pcall(function()
        return game:GetService("CoreGui")
    end)
    if ok and coreGui then
        return coreGui
    end

    return LocalPlayer:WaitForChild("PlayerGui")
end

local guiParent = getGuiParent()
gui = make("ScreenGui", {
    Name = "LastStopRoadsideToolkit",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)

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
    Text = "CLIENT-SIDE SURVIVAL TOOLKIT",
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

    toggleRefreshers[key] = refresh
    refresh()

    track(row.MouseButton1Click:Connect(function()
        if key == "performance" then
            setPerformanceMode(not state.performance)
        else
            state[key] = not state[key]
            if key == "noClip" and not state.noClip then
                restoreNoClip()
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
        Text = "Kill aura range",
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
        state.auraRange = math.max(6, state.auraRange - 2)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.auraRange = math.min(70, state.auraRange + 2)
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
        Text = "Attack delay",
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
        state.auraInterval = math.max(0.20, math.floor((state.auraInterval - 0.05) * 100 + 0.5) / 100)
        refresh()
    end))
    track(plus.MouseButton1Click:Connect(function()
        state.auraInterval = math.min(1.50, math.floor((state.auraInterval + 0.05) * 100 + 0.5) / 100)
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
addToggle("Zombie / enemy kill aura", "killAura", "Repeated attack taps against detected hostile NPCs")
addToggle("Include bosses", "auraBosses", "Includes Fred, Anubis, Dracula, Crystalus and Juggernaut")
addToggle("Target unknown NPCs", "auraAllNPCs", "Fallback detection; known friendly NPCs are excluded")
addToggle("Auto-equip melee", "autoEquipMelee", "Equips an available melee tool when none is equipped")
addToggle("Auto-face target", "auraFace", "Turns your character toward the nearest valid target")
addAuraRangeControl()
addAttackDelayControl()

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
    Size = UDim2.new(0, 300, 0, 48),
    Position = UDim2.new(1, -315, 0, 18),
    BackgroundColor3 = palette.background,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Visible = state.hud,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 8)}, hudFrame)
make("UIStroke", {Color = palette.border, Thickness = 1, Transparency = 0.2}, hudFrame)

hudLabel = make("TextLabel", {
    Position = UDim2.new(0, 10, 0, 0),
    Size = UDim2.new(1, -20, 1, 0),
    BackgroundTransparency = 1,
    Text = "HP --/--  |  Players --\nESP markers: 0",
    TextColor3 = palette.text,
    Font = Enum.Font.GothamSemibold,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
}, hudFrame)

-- Dragging.
local dragging = false
local dragStart
local frameStart

track(topBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        frameStart = mainFrame.Position

        track(input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end))
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
    "trooper", "hostile"
}

local friendlyWords = {
    "shopkeeper", "doctor", "lumberjack", "trader", "merchant", "vendor",
    "blacksmith", "quest giver", "questgiver"
}

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
    for _ = 1, 4 do
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

    if instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid")
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
    local model
    if instance:IsA("Model") then
        model = instance
    else
        model = instance:FindFirstAncestorOfClass("Model")
    end

    if not model then
        return false
    end

    return Players:GetPlayerFromCharacter(model) ~= nil
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

        local preferred = instance:FindFirstChild("HumanoidRootPart")
            or instance:FindFirstChild("Torso")
            or instance:FindFirstChild("UpperTorso")
            or instance:FindFirstChild("Head")

        if preferred and preferred:IsA("BasePart") then
            return preferred
        end

        return instance:FindFirstChildWhichIsA("BasePart", true)
    end

    return nil
end

local function isMeleeTool(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end

    local toolName = string.lower(tool.Name)
    if tool:GetAttribute("IsMelee") == true then
        return true
    end

    return hasAny(toolName, {
        "shovel", "sword", "knife", "axe", "machete", "bat", "spear",
        "club", "crowbar", "pickaxe", "hammer", "melee", "katana",
        "scythe", "sledgehammer", "chainsaw", "pipe"
    })
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

local function isPointerOverToolkit()
    local mousePosition = UserInputService:GetMouseLocation()

    local function containsPoint(frame)
        if not frame or not frame.Visible then
            return false
        end
        local position = frame.AbsolutePosition
        local size = frame.AbsoluteSize
        return mousePosition.X >= position.X
            and mousePosition.X <= position.X + size.X
            and mousePosition.Y >= position.Y
            and mousePosition.Y <= position.Y + size.Y
    end

    if gui and gui.Enabled and (containsPoint(mainFrame) or containsPoint(hudFrame)) then
        return true
    end

    return false
end

local function performAuraAttack(tool, targetRoot)
    if not tool or not targetRoot or isPointerOverToolkit() then
        return false
    end

    local camera = Workspace.CurrentCamera
    if virtualInput and camera then
        local screenPosition, onScreen = camera:WorldToScreenPoint(targetRoot.Position)
        if onScreen then
            pcall(function()
                virtualInput:SendMouseMoveEvent(screenPosition.X, screenPosition.Y, game)
            end)

            local ok = pcall(function()
                virtualInput:SendMouseButtonEvent(screenPosition.X, screenPosition.Y, 0, true, game, 0)
                task.wait(0.04)
                virtualInput:SendMouseButtonEvent(screenPosition.X, screenPosition.Y, 0, false, game, 0)
            end)
            if ok then
                return true
            end
        end
    end

    local activated = pcall(function()
        tool:Activate()
    end)
    if activated then
        return true
    end

    if type(mouseClick) == "function" then
        local ok = pcall(mouseClick)
        if ok then
            return true
        end
    end

    if type(mousePress) == "function" and type(mouseRelease) == "function" then
        local ok = pcall(function()
            mousePress()
            task.wait(0.04)
            mouseRelease()
        end)
        if ok then
            return true
        end
    end

    return false
end

local function findAuraModel(instance)
    local current = instance

    while current and current ~= Workspace do
        if current:IsA("Model") then
            local humanoid = current:FindFirstChildOfClass("Humanoid")
            if humanoid and getRootPart(current) then
                return current
            end
        end
        current = current.Parent
    end

    return nil
end

local function registerAuraCandidate(instance)
    local model = findAuraModel(instance)
    if not model or isPlayerCharacter(model) then
        return
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return
    end

    local context = getContextName(model)
    if hasAny(context, friendlyWords) then
        auraCandidates[model] = nil
        return
    end

    auraCandidates[model] = classifyAura(model) or "unknown"
end

local function queueAuraRegistration(instance)
    local model = findAuraModel(instance)
    if not model and instance:IsA("Model") then
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
            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local root = getRootPart(model)
            local context = getContextName(model)

            if not humanoid or humanoid.Health <= 0 or isPlayerCharacter(model)
                or hasAny(context, friendlyWords) then
                auraCandidates[model] = nil
            elseif root then
                local kind = classifyAura(model)
                if not kind and state.auraAllNPCs then
                    kind = "unknown"
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
    end
end

track(Workspace.DescendantAdded:Connect(queueAuraRegistration))
track(Workspace.DescendantRemoving:Connect(function(instance)
    if instance:IsA("Model") then
        auraCandidates[instance] = nil
        auraRegistrationPending[instance] = nil
    end
end))

local function runKillAura()
    while state.running do
        if state.killAura then
            local character = LocalPlayer.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local characterRoot = character and character:FindFirstChild("HumanoidRootPart")
            local meleeTool = getEquippedMeleeTool(character)

            if not humanoid or humanoid.Health <= 0 or not characterRoot then
                currentAuraStatus = "Waiting for respawn"
            else
                if not meleeTool and state.autoEquipMelee then
                    local bestTool = getBestMeleeTool(character)
                    if bestTool then
                        pcall(function()
                            humanoid:EquipTool(bestTool)
                        end)
                        task.wait(0.12)
                        meleeTool = getEquippedMeleeTool(character)
                    end
                end

                if not meleeTool then
                    currentAuraStatus = "Equip or find a melee weapon"
                else
                    local target, targetRoot, targetKind, distance = getNearestAuraTarget(characterRoot)
                    if target and targetRoot then
                        faceAuraTarget(character, targetRoot)
                        if os.clock() - lastAuraAttack >= state.auraInterval then
                            local sent = performAuraAttack(meleeTool, targetRoot)
                            if sent then
                                lastAuraAttack = os.clock()
                                currentAuraStatus = string.format("%s: %s (%.0f)", targetKind, target.Name, distance)
                            else
                                currentAuraStatus = "Attack input unavailable"
                            end
                        else
                            currentAuraStatus = string.format("Target: %s (%.0f)", target.Name, distance)
                        end
                    else
                        currentAuraStatus = state.auraAllNPCs and "No NPC in range" or "No recognized hostile in range"
                    end
                end
            end
        else
            currentAuraStatus = "Off"
        end

        task.wait(0.08)
    end
end

task.spawn(runKillAura)

local function applyNoClip()
    if not state.noClip then
        if next(noClipCache) then
            restoreNoClip()
        end
        return
    end

    local character = LocalPlayer.Character
    if not character then
        return
    end

    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("BasePart") then
            if noClipCache[object] == nil then
                noClipCache[object] = object.CanCollide
            end
            if object.CanCollide then
                object.CanCollide = false
            end
        end
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

track(LocalPlayer.CharacterAdded:Connect(function()
    restoreNoClip()
    restoreWalkSpeed()
end))

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
        "%s  |  Players %d\nESP: %d  |  NPC cache: %d  |  Aura: %s",
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
        currentAuraStatus
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
