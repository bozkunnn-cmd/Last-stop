--[[
    LAST STOP [BETA] - ROADSIDE TOOLKIT
    Client-side survival toolkit.

    Included:
      * Loot / pickup ESP (name + distance)
      * Zombie ESP and boss ESP
      * Teammate ESP (off by default)
      * Optional NPC-only melee auto-attack (off by default)
      * Local health / player-count / aura-status HUD
      * Reversible low-effects mode
      * Draggable, collapsible UI
      * RightShift toggles the menu

    The aura only targets detected NPC models, excludes player characters,
    and uses held mouse input when available (Tool:Activate() fallback).
    No custom RemoteEvent calls or server-side damage edits are included.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
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
    auraFace = true,
    auraRange = 12,
    auraInterval = 0.45,
    maxDistance = 1000,
    scanInterval = 2.0,
}

local connections = {}
local markers = {}
local auraCandidates = {}
local auraRegistrationPending = {}
local currentAuraStatus = "Off"
local auraInputHeld = false
local lastAuraAttack = 0
local visualCache = {}
local gui
local mainFrame
local statusLabel
local hudFrame
local hudLabel
local lastScanCount = 0
local originalGlobalShadows = Lighting.GlobalShadows

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
        state.auraRange = math.min(24, state.auraRange + 2)
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
addToggle("Zombie kill aura", "killAura", "Auto-activates an equipped melee weapon near hostile NPCs")
addToggle("Include bosses", "auraBosses", "Off by default; enable when you want to fight bosses")
addToggle("Auto-face target", "auraFace", "Turns your character toward the nearest valid target")
addAuraRangeControl()

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

track(UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        gui.Enabled = not gui.Enabled
    end
end))

local bossWords = {
    "boss", "fred", "anubis", "dracula", "nightmare", "vampire lord", "overlord"
}

local zombieWords = {
    "zombie", "undead", "infected", "ghoul", "skeleton", "vampire",
    "crawler", "walker", "bloater", "brute", "bandit", "raider",
    "sniper", "alien", "mutant", "monster", "enemy"
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
    for _ = 1, 2 do
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
        "club", "crowbar", "pickaxe", "hammer", "melee"
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

local mousePress = env.mouse1press
local mouseRelease = env.mouse1release
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

local function setAuraAttackHeld(held)
    if held and isPointerOverToolkit() then
        if auraInputHeld then
            setAuraAttackHeld(false)
        end
        return false
    end

    if auraInputHeld == held then
        return true
    end

    if type(mousePress) == "function" and type(mouseRelease) == "function" then
        local ok = pcall(function()
            if held then
                mousePress()
            else
                mouseRelease()
            end
        end)
        if ok then
            auraInputHeld = held
            return true
        end
    end

    if virtualInput then
        local mousePosition = UserInputService:GetMouseLocation()
        local ok = pcall(function()
            virtualInput:SendMouseButtonEvent(
                mousePosition.X,
                mousePosition.Y,
                0,
                held,
                game,
                0
            )
        end)
        if ok then
            auraInputHeld = held
            return true
        end
    end

    return false
end

local function registerAuraCandidate(instance)
    if not instance or not instance:IsA("Model") then
        return
    end
    if instance:FindFirstAncestorOfClass("Model") or isPlayerCharacter(instance) then
        return
    end

    local humanoid = instance:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return
    end

    local kind = classify(instance)
    if kind == "zombie" or kind == "boss" then
        auraCandidates[instance] = kind
    else
        auraCandidates[instance] = nil
    end
end

local function queueAuraRegistration(instance)
    local model
    if instance:IsA("Model") then
        model = instance
    else
        model = instance:FindFirstAncestorOfClass("Model")
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

    for model, kind in pairs(auraCandidates) do
        if not model or not model.Parent then
            auraCandidates[model] = nil
        else
            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local root = getRootPart(model)

            if not humanoid or humanoid.Health <= 0 then
                auraCandidates[model] = nil
            elseif root and not isPlayerCharacter(model)
                and (kind == "zombie" or (kind == "boss" and state.auraBosses)) then
                local distance = (root.Position - characterRoot.Position).Magnitude
                if distance <= bestDistance then
                    bestDistance = distance
                    bestModel = model
                    bestRoot = root
                    bestKind = kind
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
                setAuraAttackHeld(false)
                currentAuraStatus = "Waiting for respawn"
            elseif not meleeTool then
                setAuraAttackHeld(false)
                currentAuraStatus = "Equip a melee weapon"
            else
                local target, targetRoot, targetKind, distance = getNearestAuraTarget(characterRoot)
                if target and targetRoot then
                    faceAuraTarget(character, targetRoot)
                    local inputHeld = setAuraAttackHeld(true)

                    if not inputHeld and os.clock() - lastAuraAttack >= state.auraInterval then
                        local ok, err = pcall(function()
                            meleeTool:Activate()
                        end)
                        if ok then
                            lastAuraAttack = os.clock()
                        else
                            currentAuraStatus = "Attack failed: " .. tostring(err):sub(1, 30)
                        end
                    end

                    if inputHeld then
                        currentAuraStatus = string.format("%s: %s (%.0f)", targetKind, target.Name, distance)
                    else
                        currentAuraStatus = string.format("Tap mode: %s (%.0f)", target.Name, distance)
                    end
                else
                    setAuraAttackHeld(false)
                    currentAuraStatus = "No hostile in range"
                end
            end
        else
            setAuraAttackHeld(false)
            currentAuraStatus = "Off"
        end

        task.wait(0.1)
    end

    setAuraAttackHeld(false)
end

task.spawn(runKillAura)

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
        "%s  |  Players %d\nESP: %d  |  Aura: %s",
        healthText,
        #Players:GetPlayers(),
        lastScanCount,
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
