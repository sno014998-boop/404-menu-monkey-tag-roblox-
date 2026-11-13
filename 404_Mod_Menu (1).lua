--[[
    404 MOD MENU  -  Monkey Tag (MTN) client mod menu
    ---------------------------------------------------------------
    WHERE TO PUT IT
      Put this as a LocalScript in  StarterPlayer > StarterPlayerScripts
      (next to the existing "MTN" LocalScript) in YOUR copy of the game.

    GODMODE needs the second file, 404_GodmodeServer.lua, as a Script in
    ServerScriptService (the server decides tags, a client can't change that).

    TOUCH TELEPORT: tap floor / wall to teleport (air is ignored).
    PLAYER TRACKER: live roster by room + join / leave / room-switch log.

    SPIN MODS: head spinning with X / Y / Z axis toggles and a speed amount.

    TROLL TAGGED PLAYERS (Tag Mods): when a tagged player gets within the trigger distance
    and is closing in, you teleport behind them (outside their tag reach, and not through
    walls). 0.7s cooldown. Works with Teleport Lag Bypass.

    PLAYER HIGHLIGHTER (Visual Mods): outline + nametag with game name, Roblox @username,
    distance, TAGGED / UNTAGGED status and their monkey colour. Only shows players in your
    room (the game only sends poses inside a room).

    CAMERA MODS: Freecam (camera flies with its own on-screen joystick; your body AND head stay frozen, others see no change) and Third
    Person (camera behind your head, distance adjustable). Both only move YOUR camera. A red
    stand-in head / torso shows where your avatar is. One camera mode at a time.

    COPY MODS: "Copy Player Movement" + a player list right under the button. Pick a
    player, turn it ON, and your avatar copies their head, both hands and body, sent
    through Remotes.Pose so everyone in the room sees it. Poses come from
    Avatars.packets (what the game already received for that player).
      Follow Player ON  : your rig is glued INSIDE their body (Side Distance 0) and follows.
      Follow Player OFF : you stay where you are and just copy the motion.
    Only players in YOUR room can be copied (the game only relays poses inside a room).
    Finger curls are not copied (the game keeps those local).
    Turning Copy off (or Follow off) teleports you back to where you started.
    TELEPORT LAG BYPASS (World Mods): stops the game pulling you back after a far teleport.
    It ignores the server's MovementCorrection (WalkSim.correct), undoes any sudden >60 stud
    snap-back, holds you at the destination for 0.3s and shortens the tap cooldown.

    SPAZ MODS jitter the head / body / hands that get sent to other players.
    Head spaz does not shake your own camera.

    HOW IT WORKS (read from your .rbxl)
      The game does not use Humanoid physics. It runs its own controller,
      ReplicatedFirst-free module  StarterPlayerScripts.MTN.WalkSim , and sends
      head / left hand / right hand / body to the server (Remotes.Pose), which
      relays it to everybody. So this menu hooks WalkSim.step: whatever the
      controller says after our changes is what the camera uses AND what other
      players receive.

    CONTROLS
      Open / close menu : "404" button (top centre)  or  RightShift
      Fly               : in-game move joystick (or WASD). You fly where your
                          face / camera points: stick forward = forward,
                          stick back = backwards.
      Floating Pad      : on-screen up/down arrows (right side) or E / Q
      Hand Joysticks    : two on-screen sticks, each with hand lift ^ v buttons. PC keys: left hand T F G H,
                          right hand I J K L. Aim the camera to aim the hands.

    NOTES
      * Needs the default "walksim" movement (not "classic") and non-VR.
      * Rainbow / flicker uses the game's own "color" action, so everyone sees it.
        The game's server also writes that colour to the DataStore on every
        change (SetAsync), so expect DataStore throttle warnings in the server
        output while it runs. Turning the toggle off restores your old colour.
]]

----------------------------------------------------------------------
-- SETTINGS
----------------------------------------------------------------------
local SYNC_COLOR_TO_SERVER = true   -- true = other players see rainbow / flicker
local COLOR_SYNC_INTERVAL  = 0.2    -- seconds between colour updates sent to the server
local HAND_LIFT_SPEED      = 6      -- studs / second the hand lift buttons move a hand
local BASE_FLY_SPEED       = 30     -- studs / second before the speed multiplier
local HAND_REACH           = 7      -- max studs a hand joystick pushes a hand out
local PAD_SPEED            = 9      -- studs / second the floating pad lifts
local PAD_SIZE             = 9
local TOGGLE_KEY           = Enum.KeyCode.RightShift

----------------------------------------------------------------------
-- SERVICES / GAME MODULES
----------------------------------------------------------------------
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local GuiService         = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LP            = Players.LocalPlayer
local PlayerGui     = LP:WaitForChild("PlayerGui")
local PlayerScripts = LP:WaitForChild("PlayerScripts")
local MTN           = ReplicatedStorage:WaitForChild("MTN")
local Config        = require(MTN:WaitForChild("Config"))
local Remotes       = MTN:WaitForChild("Remotes")
local WalkSim       = require(PlayerScripts:WaitForChild("MTN"):WaitForChild("WalkSim"))
-- Avatars.packets[userId] = latest pose (head / left / right CFrames) the game received
-- for every other player in your room. Copy Player Movement reads it.
local Avatars
do
    local ok, mod = pcall(function()
        return require(PlayerScripts:WaitForChild("MTN"):WaitForChild("Avatars", 10))
    end)
    if ok then Avatars = mod end
end

----------------------------------------------------------------------
-- STATE
----------------------------------------------------------------------
local S = {
    fly = false, noclip = false, speed = false,
    longArms = false, hands = false, highlight = false,
    rainbow = false, flicker = false, pad = false, god = false, tp = false, tracker = false,
    spazHead = false, spazBody = false, spazHands = false, spazAmt = 1,
    spinHead = false, spinX = false, spinY = true, spinZ = false, spinSpeed = 1,
    speedMult = 3, armScale = 2.5,
    tpBypass = false,
    troll = false, trollRange = 14, trollBehind = 6,
    esp = false, espTags = true, espStatus = true, espColor = true,
    freecam = false, third = false, thirdDist = 12, freecamSpeed = 40,
    copy = false, copyTarget = nil, copyFollow = true, copyDist = 0,
    menuOpen = true,
}

-- Copy Player Movement runtime
local copyAnchor = nil        -- fixed offset used when "Follow Player" is OFF
local copyReturn = nil        -- where you were when copy+follow started (restored on stop)
local lastEnd, lastRig = nil, nil   -- rig position at the end of the last step (pull-back guard)
local tpHold = nil            -- teleport lag bypass: briefly freezes the rig at the destination
local copyHandsMade = false   -- we created self.hands ourselves (undo on stop)
local copyLastPose, copyLastAt = nil, 0

-- Returns head / left / right / body CFrames of the copied player, already shifted
-- to where YOUR avatar should be, or nil if no fresh pose is available.
local function getCopyData(rig)
    if not (S.copy and S.copyTarget and Avatars and Avatars.packets) then return nil end
    local pk = Avatars.packets[S.copyTarget]
    if type(pk) ~= "table" or typeof(pk.head) ~= "CFrame" or typeof(pk.left) ~= "CFrame" or typeof(pk.right) ~= "CFrame" then
        return nil
    end
    if pk ~= copyLastPose then copyLastPose = pk; copyLastAt = os.clock() end
    if os.clock() - copyLastAt > 3 then return nil end -- target stopped sending (left room?)

    -- body of the target: the game anchors their HumanoidRootPart to the relayed body
    local body
    local tp = Players:GetPlayerByUserId(S.copyTarget)
    local hrp = tp and tp.Character and tp.Character:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") and (hrp.Position - pk.head.Position).Magnitude < 6 then
        body = hrp.CFrame
    else
        local _, yaw = pk.head:ToOrientation()
        body = CFrame.new(pk.head.Position - Vector3.new(0, 1, 0)) * CFrame.Angles(0, yaw, 0)
    end

    local off
    if S.copyFollow then
        off = body.RightVector * S.copyDist            -- 0 = inside their body, >0 = beside them
    else
        if not copyAnchor then                          -- copy in place: keep my spot
            local myHead = rig and typeof(rig.head) == "CFrame" and rig.head.Position or pk.head.Position
            copyAnchor = myHead - pk.head.Position
        end
        off = copyAnchor
    end
    return {
        head = pk.head + off, left = pk.left + off, right = pk.right + off,
        body = body + off,
    }
end

local BASE_WALK   = Config.WalkSim.Speed
local BASE_SPRINT = Config.WalkSim.SprintSpeed

local function applySpeed()
    local m = S.speed and S.speedMult or 1
    pcall(function()
        Config.WalkSim.Speed       = BASE_WALK * m
        Config.WalkSim.SprintSpeed = BASE_SPRINT * m
    end)
end

----------------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------------
local function isTouch()
    return UIS.PreferredInput == Enum.PreferredInput.Touch
end

local function typing()
    return UIS:GetFocusedTextBox() ~= nil
end

local KEYS = {
    [Enum.KeyCode.W] = Vector2.new(0, -1), [Enum.KeyCode.S] = Vector2.new(0, 1),
    [Enum.KeyCode.A] = Vector2.new(-1, 0), [Enum.KeyCode.D] = Vector2.new(1, 0),
    [Enum.KeyCode.Up] = Vector2.new(0, -1), [Enum.KeyCode.Down] = Vector2.new(0, 1),
    [Enum.KeyCode.Left] = Vector2.new(-1, 0), [Enum.KeyCode.Right] = Vector2.new(1, 0),
}

local function deadzone(v)
    local m = v.Magnitude
    if m <= 0.15 then return Vector2.new(0, 0) end
    return v.Unit * math.min(1, (m - 0.15) / 0.85)
end

-- Reads the same inputs the game's own controller reads (keys, gamepad stick and
-- the in-game touch walk joystick).
local function readMove(ctrl)
    local v = Vector2.new(0, 0)
    for key, dir in pairs(KEYS) do
        if UIS:IsKeyDown(key) then v = v + dir end
    end
    v = v + deadzone(ctrl.stick or Vector2.new(0, 0))
    v = v + deadzone(ctrl.touchMove or Vector2.new(0, 0))
    if v.Magnitude > 1 then v = v.Unit end
    return v
end

----------------------------------------------------------------------
-- MONKEY COLOUR (rainbow / black-white flicker)
----------------------------------------------------------------------
local origColor
local lastColorSync = 0

local function setMonkeyColor(c)
    pcall(function() LP:SetAttribute("MtnColor", c) end)
    if SYNC_COLOR_TO_SERVER and os.clock() - lastColorSync >= COLOR_SYNC_INTERVAL then
        lastColorSync = os.clock()
        pcall(function() Remotes.Action:FireServer("color", { c.R, c.G, c.B }) end)
    end
end

local function restoreMonkeyColor()
    if origColor then
        lastColorSync = 0
        setMonkeyColor(origColor)
    end
end

RunService.Heartbeat:Connect(function()
    if S.rainbow then
        origColor = origColor or LP:GetAttribute("MtnColor")
        setMonkeyColor(Color3.fromHSV((os.clock() * 0.35) % 1, 1, 1))
    elseif S.flicker then
        origColor = origColor or LP:GetAttribute("MtnColor")
        local on = math.floor(os.clock() / 0.12) % 2 == 0
        setMonkeyColor(on and Color3.new(1, 1, 1) or Color3.new(0.02, 0.02, 0.02))
    end
end)

----------------------------------------------------------------------
-- WORLD OBJECTS: floating pad + hand markers
----------------------------------------------------------------------
local pad, padTop, padDir = nil, nil, 0
local PAD_THICK, PAD_STAND = 0.6, 2.0

local function groundGroup()
    local world = workspace:FindFirstChild("MTNWorld")
    local col = world and world:FindFirstChild("Collision")
    if col then
        for _, d in ipairs(col:GetDescendants()) do
            if d:IsA("BasePart") then return d.CollisionGroup end
        end
    end
    return "Default"
end

local function ensurePad()
    if pad and pad.Parent then return pad end
    pad = Instance.new("Part")
    pad.Name = "404FloatingPad"
    pad.Anchored = true
    pad.CanCollide = true
    pad.CanQuery = true
    pad.CanTouch = false
    pad.CastShadow = false
    pad.Size = Vector3.new(PAD_SIZE, PAD_THICK, PAD_SIZE)
    pad.Material = Enum.Material.Neon
    pad.Color = Color3.fromRGB(255, 40, 60)
    pad.Transparency = 0.35
    pcall(function() pad.CollisionGroup = groundGroup() end)
    pad.Parent = workspace
    return pad
end

local function removePad()
    if pad then pad:Destroy() end
    pad, padTop, padDir = nil, nil, 0
end

local markers = {}
local function setMarkers(on)
    for i = 1, 2 do
        if on then
            if not markers[i] or not markers[i].Parent then
                local p = Instance.new("Part")
                p.Name = "404HandMarker" .. i
                p.Shape = Enum.PartType.Ball
                p.Size = Vector3.new(0.6, 0.6, 0.6)
                p.Anchored = true
                p.CanCollide = false
                p.CanQuery = false
                p.CanTouch = false
                p.CastShadow = false
                p.Material = Enum.Material.Neon
                p.Color = (i == 1) and Color3.fromRGB(60, 170, 255) or Color3.fromRGB(255, 60, 80)
                local hl = Instance.new("Highlight")
                hl.Adornee = p
                hl.FillColor = p.Color
                hl.OutlineColor = Color3.new(1, 1, 1)
                hl.FillTransparency = 0.25
                hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                hl.Parent = p
                p.Parent = workspace
                markers[i] = p
            end
        elseif markers[i] then
            markers[i]:Destroy()
            markers[i] = nil
        end
    end
end

----------------------------------------------------------------------
-- CAMERA MODS: freecam + third person (camera only; what others see is unchanged)
----------------------------------------------------------------------
-- The game draws no full-body model for you, so a simple stand-in (head + torso, plus the
-- hand markers) shows where your avatar is while the camera is away from your head.
local dummy = {}
local function ensureDummy()
    if dummy.head and dummy.head.Parent then return end
    local function part(name, shape, size)
        local p = Instance.new("Part")
        p.Name = name
        p.Shape = shape
        p.Size = size
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.CastShadow = false
        p.Material = Enum.Material.SmoothPlastic
        p.Color = Color3.fromRGB(255, 40, 60)
        p.Transparency = 0.25
        p.Parent = workspace
        return p
    end
    dummy.head = part("404DummyHead", Enum.PartType.Ball, Vector3.new(1.3, 1.3, 1.3))
    dummy.body = part("404DummyBody", Enum.PartType.Block, Vector3.new(1.5, 2.2, 0.8))
end
local function removeDummy()
    if dummy.head then dummy.head:Destroy() end
    if dummy.body then dummy.body:Destroy() end
    dummy.head, dummy.body = nil, nil
end

local camParams = RaycastParams.new()
camParams.FilterType = Enum.RaycastFilterType.Exclude
camParams.RespectCanCollide = true
local freePos = nil -- freecam position

local isTagged -- defined in the PLAYER HIGHLIGHTER section below
-- TROLL TAGGED PLAYERS: when a tagged (chasing) player closes in on you, teleport behind them
local trollLast, trollDist = 0, {}
local trollParams = RaycastParams.new()
trollParams.FilterType = Enum.RaycastFilterType.Exclude
trollParams.RespectCanCollide = true

local function trollStep(rig)
    if not (S.troll and Avatars and Avatars.packets) or S.freecam then return end
    if typeof(rig.head) ~= "CFrame" then return end
    if isTagged(LP.UserId) then return end           -- you are tagged: nobody to dodge
    local now = os.clock()
    local myHead = rig.head.Position
    local hOff = myHead - rig.position
    local tagR = (type(Config.TagDistance) == "number" and type(Config.MetresToStuds) == "number")
        and Config.TagDistance * Config.MetresToStuds or 4
    local behind = math.max(S.trollBehind, tagR + 1.5)  -- stay outside their tag reach

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local pk = Avatars.packets[p.UserId]
            if type(pk) == "table" and typeof(pk.head) == "CFrame" and isTagged(p.UserId) then
                local dist = (pk.head.Position - myHead).Magnitude
                local last = trollDist[p.UserId]
                trollDist[p.UserId] = dist
                local closing = last == nil or dist < last - 0.02
                if dist < S.trollRange and closing and now - trollLast > 0.7 then
                    local look = Vector3.new(pk.head.LookVector.X, 0, pk.head.LookVector.Z)
                    if look.Magnitude < 0.05 then look = Vector3.new(0, 0, -1) end
                    look = look.Unit
                    local from = pk.head.Position
                    local ignore = {}
                    if LP.Character then table.insert(ignore, LP.Character) end
                    if pad then table.insert(ignore, pad) end
                    trollParams.FilterDescendantsInstances = ignore
                    local d = behind
                    local hit = workspace:Raycast(from, -look * behind, trollParams)
                    if hit then d = math.max(1.5, hit.Distance - 1) end -- wall behind them: stand closer
                    pendingTp = from - look * d - hOff
                    trollLast = now
                    trollDist[p.UserId] = nil
                    return
                end
            else
                trollDist[p.UserId] = nil
            end
        end
    end
end
-- freecam look: the game's yaw / pitch (= your SENT head) stays frozen, the camera has its own
local fcInit, frozenYaw, frozenPitch, fcYaw, fcPitch = false, 0, 0, 0, 0

----------------------------------------------------------------------
-- PLAYER HIGHLIGHTER (ESP): outline + nametag + Roblox username + tagged status + colour
----------------------------------------------------------------------
-- Reads what the game already knows: Avatars.packets (other players' poses, same room only),
-- Avatars.actors (their avatar models), Avatars.roundState (who is infected / tagged) and the
-- MtnName / MtnColor attributes on each Player.
local espObjs = {}
local ESP_GREEN, ESP_RED = Color3.fromRGB(90, 225, 130), Color3.fromRGB(255, 85, 95)

local function lookupKey(t, k)
    if type(t) ~= "table" then return nil end
    local v = t[k]
    if v == nil then v = t[tostring(k)] end
    return v
end

function isTagged(uid)
    if not Avatars then return false end
    local st = Avatars.roundState
    local inf = (st and st.infected) or Avatars.infected
    if lookupKey(inf, uid) then return true end
    -- hunt mode: once a round is running, players with no target left are out ("dead")
    if st and st.kind == "HUNT" and st.phase == "PLAYING" and lookupKey(st.targets, uid) == nil then
        return true
    end
    return false
end

local function makeLabel(parent, y, h, size, bold)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = UDim2.fromOffset(24, y)
    l.Size = UDim2.new(1, -30, 0, h)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.GothamMedium
    l.TextSize = size
    l.TextColor3 = Color3.new(1, 1, 1)
    l.TextStrokeTransparency = 0.6
    l.Text = ""
    l.Parent = parent
    return l
end

local function buildEsp(p)
    local part = Instance.new("Part")
    part.Name = "404ESP"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Transparency = 1
    part.Size = Vector3.new(0.2, 0.2, 0.2)
    part.Parent = workspace

    local hl = Instance.new("Highlight")
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillTransparency = 0.55
    hl.OutlineTransparency = 0
    hl.Parent = part

    local bb = Instance.new("BillboardGui")
    bb.Adornee = part
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(200, 78)
    bb.StudsOffset = Vector3.new(0, 2.4, 0)
    bb.Parent = part

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
    bg.BackgroundTransparency = 0.3
    bg.BorderSizePixel = 0
    bg.Parent = bb
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = bg
    local st = Instance.new("UIStroke"); st.Thickness = 2; st.Parent = bg

    local swatch = Instance.new("Frame")
    swatch.Position = UDim2.fromOffset(6, 5)
    swatch.Size = UDim2.fromOffset(14, 14)
    swatch.BorderSizePixel = 0
    swatch.Parent = bg
    local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(1, 0); sc.Parent = swatch

    local o = {
        part = part, hl = hl, bb = bb, stroke = st, swatch = swatch,
        name = makeLabel(bg, 2, 20, 15, true),
        user = makeLabel(bg, 22, 16, 12, false),
        status = makeLabel(bg, 39, 18, 14, true),
        color = makeLabel(bg, 58, 16, 12, false),
    }
    o.user.Position = UDim2.fromOffset(8, 22); o.user.Size = UDim2.new(1, -12, 0, 16)
    o.status.Position = UDim2.fromOffset(8, 39); o.status.Size = UDim2.new(1, -12, 0, 18)
    o.color.Position = UDim2.fromOffset(8, 58); o.color.Size = UDim2.new(1, -12, 0, 16)
    espObjs[p] = o
    return o
end

local function removeEsp(p)
    local o = espObjs[p]
    if o then o.part:Destroy() end
    espObjs[p] = nil
end

local function clearEsp()
    for p in pairs(espObjs) do removeEsp(p) end
end
Players.PlayerRemoving:Connect(removeEsp)

RunService.RenderStepped:Connect(function()
    if not S.esp then return end
    local cam = workspace.CurrentCamera
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local pk = Avatars and Avatars.packets and Avatars.packets[p.UserId]
            local o = espObjs[p]
            if type(pk) ~= "table" or typeof(pk.head) ~= "CFrame" then
                if o then o.bb.Enabled = false; o.hl.Enabled = false end
            else
                o = o or buildEsp(p)
                o.part.Position = pk.head.Position
                local actor = Avatars.actors and Avatars.actors[p.UserId]
                local model = (actor and actor.model and actor.model.Parent and actor.model) or p.Character
                if o.hl.Adornee ~= model then o.hl.Adornee = model end

                local tagged = isTagged(p.UserId)
                local col = p:GetAttribute("MtnColor")
                if typeof(col) ~= "Color3" then col = Color3.fromRGB(150, 150, 160) end
                local statusCol = tagged and ESP_RED or ESP_GREEN

                o.hl.Enabled = model ~= nil
                o.hl.FillColor = S.espColor and col or statusCol
                o.hl.OutlineColor = statusCol

                o.bb.Enabled = S.espTags
                o.stroke.Color = statusCol

                local mtn = p:GetAttribute("MtnName")
                if type(mtn) ~= "string" or mtn == "" then mtn = p.DisplayName end
                o.name.Text = mtn
                o.name.Position = UDim2.fromOffset(24, 2)
                o.name.Size = UDim2.new(1, -30, 0, 20)
                local dist = cam and math.floor((pk.head.Position - cam.CFrame.Position).Magnitude + 0.5) or 0
                local user = "@" .. p.Name
                if p.DisplayName ~= p.Name then user = user .. " (" .. p.DisplayName .. ")" end
                o.user.Text = user .. "  " .. dist .. "st"

                o.status.Visible = S.espStatus
                o.status.Text = tagged and "TAGGED" or "UNTAGGED"
                o.status.TextColor3 = statusCol

                o.swatch.Visible = S.espColor
                o.color.Visible = S.espColor
                o.swatch.BackgroundColor3 = col
                o.color.Text = string.format("COLOR  #%02X%02X%02X", math.floor(col.R * 255 + 0.5), math.floor(col.G * 255 + 0.5), math.floor(col.B * 255 + 0.5))
            end
        end
    end
end)

----------------------------------------------------------------------
-- TOUCH TELEPORT: tap / click a floor or wall to go there. Air = nothing.
----------------------------------------------------------------------
local pendingTp
local tpParams = RaycastParams.new()
tpParams.FilterType = Enum.RaycastFilterType.Exclude
tpParams.RespectCanCollide = true
local tapStart = {}
local lastTp = 0

local function tryTeleport(screenPos)
    local cam = workspace.CurrentCamera
    if not cam or os.clock() - lastTp < (S.tpBypass and 0.06 or 0.25) then return end
    local ray = cam:ScreenPointToRay(screenPos.X, screenPos.Y)
    local ignore = {}
    if LP.Character then table.insert(ignore, LP.Character) end
    if pad then table.insert(ignore, pad) end
    for i = 1, 2 do if markers[i] then table.insert(ignore, markers[i]) end end
    tpParams.FilterDescendantsInstances = ignore
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 1500, tpParams)
    if not hit then return end -- tapped the sky / air: no teleport
    local n = hit.Normal
    if n.Y >= 0.7 then
        pendingTp = hit.Position + Vector3.new(0, 2.9, 0)                      -- floor
    elseif n.Y > -0.7 then
        pendingTp = hit.Position + n * 1.3 + Vector3.new(0, 0.5, 0)            -- wall
    else
        return                                                                  -- ceiling: ignored
    end
    lastTp = os.clock()
end

UIS.InputBegan:Connect(function(i, gp)
    if gp or not S.tp then return end
    if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
        tapStart[i] = { pos = Vector2.new(i.Position.X, i.Position.Y), t = os.clock() }
    end
end)
UIS.InputEnded:Connect(function(i)
    local st = tapStart[i]
    if not st then return end
    tapStart[i] = nil
    if S.tp and (Vector2.new(i.Position.X, i.Position.Y) - st.pos).Magnitude < 14 and os.clock() - st.t < 0.35 then
        tryTeleport(Vector2.new(i.Position.X, i.Position.Y))
    end
end)

----------------------------------------------------------------------
-- HAND JOYSTICKS (virtual) - values are written by the UI section below
----------------------------------------------------------------------
local stickL = { value = Vector2.new(0, 0) }
local stickR = { value = Vector2.new(0, 0) }
local stickF = { value = Vector2.new(0, 0) }   -- freecam move joystick
local handPos = { nil, nil }
local handLift = { 0, 0 }     -- extra height per hand (studs)
local liftDir  = { 0, 0 }     -- held lift button: 1 up, -1 down

local function keyAxis(up, down, left, right)
    local x = (UIS:IsKeyDown(right) and 1 or 0) - (UIS:IsKeyDown(left) and 1 or 0)
    local y = (UIS:IsKeyDown(up) and 1 or 0) - (UIS:IsKeyDown(down) and 1 or 0)
    return Vector2.new(x, y)
end

----------------------------------------------------------------------
-- PER-INSTANCE PATCHES ON THE GAME'S CONTROLLER
----------------------------------------------------------------------
-- Fly: stop the rig from re-detecting "ground" (otherwise it walks + hovers).
local function setFlyProbe(rig, on)
    if on then
        if rawget(rig, "probe") == nil then
            rig.probe = function(r) r.onGround = false end
        end
    elseif rawget(rig, "probe") ~= nil then
        rig.probe = nil
    end
end

-- Noclip: sweeps that hit walls / ceilings (normal.Y < 0.7) are ignored, floors
-- still hold you up. Fly + noclip additionally ignores everything.
local function setNoclip(collision, on)
    if on then
        if rawget(collision, "sweep") == nil then
            local orig = collision.sweep
            collision.sweep = function(c, a, b, d, e)
                local hit = orig(c, a, b, d, e)
                if hit and hit.Normal and hit.Normal.Y < 0.7 then return nil end
                return hit
            end
        end
    elseif rawget(collision, "sweep") ~= nil then
        collision.sweep = nil
    end
end

----------------------------------------------------------------------
-- THE HOOK:  WalkSim.step
----------------------------------------------------------------------
-- spaz helpers: random jitter applied to what the game SENDS to the server
local spinT = 0 -- accumulated head spin angle (radians)
local function rnd() return math.random() * 2 - 1 end
local function spazRot(a) return CFrame.Angles(rnd() * a, rnd() * a, rnd() * a) end

local origStep = WalkSim.step
local lastWarn = 0
local function softWarn(where, err)
    if os.clock() - lastWarn > 5 then
        lastWarn = os.clock()
        warn("[404 Mod Menu] " .. where .. ": " .. tostring(err))
    end
end

local function preStep(self, dt, blocked)
    local ctx = { blocked = blocked }
    local rig = self.rig
    if not rig then return ctx end

    if S.menuOpen and not isTouch() then
        ctx.blocked = true -- frees the mouse so you can click the menu on PC
    end

    -- freecam look: pull the look input into the camera, keep the sent head frozen
    if S.freecam then
        if not fcInit then
            fcInit = true
            frozenYaw, frozenPitch = self.yaw, self.pitch
            fcYaw, fcPitch = self.yaw, self.pitch
        end
        fcYaw = fcYaw + (self.yaw - frozenYaw)       -- look input that arrived between frames
        fcPitch = fcPitch + (self.pitch - frozenPitch)
        self.yaw = frozenYaw
        self.pitch = 0                               -- baseline so the game's pitch clamp can't cut the camera
    else
        fcInit = false
    end

    ctx.copy = getCopyData(rig)
    local following = ctx.copy ~= nil and S.copyFollow
    ctx.following = following
    setFlyProbe(rig, S.fly or following)
    if rig.collision then setNoclip(rig.collision, S.noclip) end

    if not following then trollStep(rig) end

    -- Teleport Lag Bypass, pull-back guard: if something (server correction, anti-cheat,
    -- map reset) yanks the rig far away from where our last step left it, put it back.
    if rig ~= lastRig then lastRig = rig; lastEnd = nil end
    if S.tpBypass and lastEnd and (rig.position - lastEnd).Magnitude > 60 then
        rig.position = lastEnd
        rig.previous = lastEnd
        rig.velocity = Vector3.new(0, 0, 0)
    end

    -- remember where we were before copy + follow drags the rig away
    if following and not copyReturn then
        copyReturn = rig.position
    end

    if pendingTp and not following then
        rig:teleport(pendingTp)
        if S.tpBypass then
            tpHold = { pos = pendingTp, untilT = os.clock() + 0.3 }
        end
        pendingTp = nil
        handPos[1], handPos[2] = nil, nil
        padTop = nil -- floating pad re-anchors at the new spot
    end

    -- Teleport Lag Bypass: pin the rig at the destination for a moment (no falling,
    -- no collision sweep from the old spot, no rubber-band) while the world catches up
    if tpHold then
        if S.tpBypass and not following and os.clock() < tpHold.untilT then
            rig.position = tpHold.pos
            rig.previous = rig.position
            rig.velocity = Vector3.new(0, 0, 0)
            rig.hasJumped = false
        else
            tpHold = nil
        end
    end

    -- copy + follow: glue my rig to the copied player so I stay next to them
    if following then
        pendingTp = nil
        local hOff = (typeof(rig.head) == "CFrame") and (rig.head.Position - rig.position) or Vector3.new(0, 2.8, 0)
        rig.position = ctx.copy.head.Position - hOff
        rig.previous = rig.position
        rig.velocity = Vector3.new(0, 0, 0)
        rig.hasJumped = false
        self.jumpPressed = false
    end

    ctx.p0 = rig.position
    local isBlocked = ctx.blocked or not self.focused or typing()

    -- floating pad lift assist (keeps you on top while the pad rises)
    if S.pad and padTop and not S.fly then
        local pos = rig.position
        local minY = padTop + PAD_STAND
        if pos.Y < minY and pos.Y > padTop - 3.5 then
            rig.position = Vector3.new(pos.X, minY, pos.Z)
            rig.previous = rig.position
            if rig.velocity.Y < 0 then
                rig.velocity = Vector3.new(rig.velocity.X, 0, rig.velocity.Z)
            end
        end
    end

    if S.fly and not following and not S.freecam then
        if S.flyLift then
            S.flyLift = false
            rig.position = rig.position + Vector3.new(0, 3, 0)
            rig.previous = rig.position
            ctx.p0 = rig.position
        end
        local mv = isBlocked and Vector2.new(0, 0) or readMove(self)
        local rot = CFrame.Angles(0, self.yaw, 0)
        local look = rot * CFrame.Angles(self.pitch, 0, 0)
        local dir = look.LookVector * (-mv.Y) + rot.RightVector * mv.X
        local speed = BASE_FLY_SPEED * (S.speed and S.speedMult or 1)
        ctx.flyDelta = dir * speed * math.min(dt, 0.1)

        self.jumpPressed = false
        rig.hasJumped = false
        rig.velocity = Vector3.new(0, 0, 0)
        if not S.noclip then
            rig.position = ctx.p0 + ctx.flyDelta
            rig.previous = rig.position
        end
    end
    return ctx
end

local function postStep(self, dt, ctx)
    local rig = self.rig
    if not rig then return nil end
    local newHead

    -- fly: final position (cancels gravity drift; ignores walls when noclip)
    if S.fly and ctx.flyDelta and ctx.p0 then
        local target = ctx.p0 + ctx.flyDelta
        if S.noclip then
            rig.position = target
        elseif (rig.position - target).Magnitude < 0.06 then
            rig.position = target
        end
        rig.previous = rig.position
        rig.velocity = Vector3.new(0, 0, 0)
        rig:render(0)
        self:publish(rig.head)
        self.root.CFrame = self.body
        local cam = workspace.CurrentCamera
        cam.CFrame = rig.head
        cam.Focus = rig.head * CFrame.new(0, 0, -10)
        newHead = rig.head
    end

    -- freecam: the body stays where it is (frozen at its pre-step spot); only the camera flies
    if S.freecam and fcInit then
        fcYaw = fcYaw + (self.yaw - frozenYaw)
        fcPitch = math.clamp(fcPitch + self.pitch, -1.5, 1.5)
        self.yaw, self.pitch = frozenYaw, frozenPitch
        rig.yaw, rig.pitch = frozenYaw, frozenPitch
    end
    if S.freecam and ctx.p0 then
        rig.position = ctx.p0
        rig.previous = ctx.p0
        rig.velocity = Vector3.new(0, 0, 0)
        rig.hasJumped = false
        self.jumpPressed = false
        rig:render(0)
        self:publish(rig.head)
        self.root.CFrame = self.body
        newHead = rig.head
    end

    -- floating pad follows you; buttons / E Q change its height
    if S.pad then
        ensurePad()
        if not padTop then
            padTop = rig.onGround and rig.lastGround.Y or (rig.position.Y - 2.8)
        end
        local kdir = 0
        if not typing() and not ctx.blocked then
            kdir = (UIS:IsKeyDown(Enum.KeyCode.E) and 1 or 0) - (UIS:IsKeyDown(Enum.KeyCode.Q) and 1 or 0)
        end
        local d = S.freecam and 0 or (padDir + kdir)
        if d > 1 then d = 1 elseif d < -1 then d = -1 end
        padTop = padTop + d * PAD_SPEED * math.min(dt, 0.1)
        pad.CFrame = CFrame.new(rig.position.X, padTop - PAD_THICK / 2, rig.position.Z)
    end

    -- hands: long arms + joystick control (edits the table the game sends)
    local hands = self.hands
    if hands and (S.longArms or S.hands or S.highlight or S.spazHands) then
        local hp = rig.head.Position
        local look = CFrame.Angles(0, self.yaw, 0) * CFrame.Angles(self.pitch, 0, 0)
        local kb = { Vector2.new(0, 0), Vector2.new(0, 0) }
        if S.hands and not typing() then
            kb[1] = keyAxis(Enum.KeyCode.T, Enum.KeyCode.G, Enum.KeyCode.F, Enum.KeyCode.H)
            kb[2] = keyAxis(Enum.KeyCode.I, Enum.KeyCode.K, Enum.KeyCode.J, Enum.KeyCode.L)
        end
        local sticks = { stickL.value + kb[1], stickR.value + kb[2] }
        for i = 1, 2 do
            local h = hands[i]
            if h then
                local pos = h.Position
                if S.longArms then
                    local off = pos - hp
                    pos = hp + Vector3.new(off.X * S.armScale, off.Y, off.Z * S.armScale)
                end
                local v = sticks[i]
                if S.hands then
                    handLift[i] = math.clamp(handLift[i] + liftDir[i] * HAND_LIFT_SPEED * math.min(dt, 0.1), -6, 9)
                end
                local stickOn = S.hands and v.Magnitude > 0.12
                local liftOn = S.hands and math.abs(handLift[i]) > 0.05
                if stickOn or liftOn then
                    local off
                    local reach = HAND_REACH * (S.longArms and math.max(1, S.armScale * 0.6) or 1)
                    if stickOn then
                        if v.Magnitude > 1 then v = v.Unit end
                        off = Vector3.new(v.X * reach, -0.5, -v.Y * reach)
                    else
                        off = Vector3.new((i == 1) and -1.2 or 1.2, -0.5, -2.2) -- resting spot in front of you
                    end
                    local target = hp + look:VectorToWorldSpace(off) + Vector3.new(0, handLift[i], 0)
                    local a = math.min(1, dt * 18)
                    handPos[i] = handPos[i] and handPos[i]:Lerp(target, a) or target
                    pos = handPos[i]
                else
                    handPos[i] = nil
                end
                local rot = h.Rotation
                if S.spazHands then
                    pos = pos + Vector3.new(rnd(), rnd(), rnd()) * 1.4 * S.spazAmt
                    rot = spazRot(1.6 * S.spazAmt)
                end
                hands[i] = CFrame.new(pos) * rot
                if markers[i] then markers[i].CFrame = hands[i] end
            end
        end
    end
    -- COPY PLAYER MOVEMENT: replace what gets sent (head / both hands / body) with the
    -- copied player's pose. Spaz / spin below can still be layered on top.
    local cp = ctx.copy
    if cp then
        newHead = cp.head
        local h = self.hands
        if not h then
            h = {}
            self.hands = h
            copyHandsMade = true
        end
        h[1], h[2] = cp.left, cp.right
        self.body = cp.body
        if markers[1] then markers[1].CFrame = cp.left end
        if markers[2] then markers[2].CFrame = cp.right end
    elseif copyHandsMade then
        self.hands = nil
        copyHandsMade = false
    end

    -- body spaz: wobbles / tumbles the body CFrame that is sent to others
    if S.spazBody and self.body then
        local a = S.spazAmt
        self.body = CFrame.new(self.body.Position + Vector3.new(rnd(), rnd() * 0.5, rnd()) * 0.4 * a) * spazRot(1.0 * a)
    end

    -- head spin: only the SENT head spins (X / Y / Z axes), your camera stays steady
    if S.spinHead and (S.spinX or S.spinY or S.spinZ) then
        spinT = (spinT + dt * S.spinSpeed * 2 * math.pi) % (2 * math.pi * 1000)
        local base = newHead or rig.head
        newHead = base * CFrame.Angles(S.spinX and spinT or 0, S.spinY and spinT or 0, S.spinZ and spinT or 0)
    end

    -- head spaz: only the SENT head jitters, your own camera stays steady
    if S.spazHead then
        local a = S.spazAmt
        local base = newHead or rig.head
        newHead = base * CFrame.new(rnd() * 0.25 * a, rnd() * 0.25 * a, rnd() * 0.25 * a) * spazRot(0.9 * a)
    end
    -- camera: freecam beats third person
    local cam = workspace.CurrentCamera
    if cam and (S.freecam or S.third) then
        local rot = S.freecam and (CFrame.Angles(0, fcYaw, 0) * CFrame.Angles(fcPitch, 0, 0))
            or (CFrame.Angles(0, self.yaw, 0) * CFrame.Angles(self.pitch, 0, 0))
        local sentHead = newHead or rig.head

        -- stand-in avatar so you can see yourself
        if typeof(sentHead) == "CFrame" then
            ensureDummy()
            setMarkers(true)
            local _, yaw = sentHead:ToOrientation()
            local hp = sentHead.Position
            dummy.head.CFrame = CFrame.new(hp)
            dummy.body.CFrame = CFrame.new(hp - Vector3.new(0, 1.9, 0)) * CFrame.Angles(0, yaw, 0)
            local hh = self.hands
            for i = 1, 2 do
                if markers[i] and hh and typeof(hh[i]) == "CFrame" then markers[i].CFrame = hh[i] end
            end
        end

        if S.freecam then
            if not freePos then freePos = cam.CFrame.Position end
            local blockedNow = ctx.blocked or not self.focused or typing()
            -- freecam moves with its OWN joystick (+ WASD), not the game's walk stick
            local mv = Vector2.new(0, 0)
            if not blockedNow then
                for key, d in pairs(KEYS) do
                    if UIS:IsKeyDown(key) then mv = mv + d end
                end
                mv = mv + deadzone(self.stick or Vector2.new(0, 0))
            end
            mv = mv + Vector2.new(stickF.value.X, -stickF.value.Y)
            if mv.Magnitude > 1 then mv = mv.Unit end
            local vert = 0
            if not blockedNow then
                vert = padDir + (UIS:IsKeyDown(Enum.KeyCode.E) and 1 or 0) - (UIS:IsKeyDown(Enum.KeyCode.Q) and 1 or 0)
                vert = math.clamp(vert, -1, 1)
            end
            local dir = rot.LookVector * (-mv.Y) + rot.RightVector * mv.X + Vector3.new(0, vert, 0)
            freePos = freePos + dir * S.freecamSpeed * math.min(dt, 0.1)
            cam.CFrame = CFrame.new(freePos) * rot.Rotation
            cam.Focus = cam.CFrame * CFrame.new(0, 0, -10)
        elseif typeof(rig.head) == "CFrame" then
            local hp = rig.head.Position
            local back = -rot.LookVector * S.thirdDist
            local ignore = {}
            if LP.Character then table.insert(ignore, LP.Character) end
            if pad then table.insert(ignore, pad) end
            for _, o in ipairs({ markers[1], markers[2], dummy.head, dummy.body }) do
                if o then table.insert(ignore, o) end
            end
            camParams.FilterDescendantsInstances = ignore
            local pos = hp + back
            local hit = workspace:Raycast(hp, back, camParams)
            if hit then pos = hit.Position + hit.Normal * 0.4 end
            cam.CFrame = CFrame.new(pos) * rot.Rotation
            cam.Focus = cam.CFrame * CFrame.new(0, 0, -10)
        end
    end

    return newHead
end

-- Teleport Lag Bypass: the game can send "MovementCorrection" from the server, which calls
-- WalkSim.correct and teleports you back to where the server thinks you are. Ignore it
-- while the bypass is on so far teleports stick.
local origCorrect = WalkSim.correct
if origCorrect then
    WalkSim.correct = function(self, ...)
        if S.tpBypass then return end
        return origCorrect(self, ...)
    end
end

WalkSim.step = function(self, dt, blocked, extra)
    local ok, ctx = pcall(preStep, self, dt, blocked)
    if not ok then
        softWarn("preStep", ctx)
        ctx = { blocked = blocked }
    end
    local head = origStep(self, dt, ctx.blocked, extra)
    if self.rig then lastRig = self.rig; lastEnd = self.rig.position end
    local ok2, newHead = pcall(postStep, self, dt, ctx)
    if not ok2 then
        softWarn("postStep", newHead)
    elseif newHead then
        head = newHead
    end
    return head
end

----------------------------------------------------------------------
-- UI  (black theme, same layout idea as the template: Disconnect on top,
--      title, category list, scroll bars on both sides)
----------------------------------------------------------------------
local C = {
    bg     = Color3.fromRGB(8, 8, 10),
    panel  = Color3.fromRGB(18, 18, 22),
    btn    = Color3.fromRGB(28, 28, 34),
    btnHi  = Color3.fromRGB(44, 44, 54),
    accent = Color3.fromRGB(255, 40, 60),
    accent2 = Color3.fromRGB(120, 18, 28),
    text   = Color3.fromRGB(240, 240, 245),
    dim    = Color3.fromRGB(135, 135, 148),
}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end
local function stroke(o, c, t)
    new("UIStroke", { Color = c, Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end

local old = PlayerGui:FindFirstChild("404ModMenu")
if old then old:Destroy() end

local gui = new("ScreenGui", {
    Name = "404ModMenu", ResetOnSpawn = false, IgnoreGuiInset = true,
    DisplayOrder = 1000, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, PlayerGui)

-- panel ------------------------------------------------------------
local panel = new("Frame", {
    Name = "Panel", Size = UDim2.fromOffset(320, 430), AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 24, 0.5, 0), BackgroundColor3 = C.bg, BorderSizePixel = 0,
    Active = true,
}, gui)
corner(panel, 12); stroke(panel, C.accent, 2)
new("UIScale", { Scale = 1 }, panel)

local disconnectBtn = new("TextButton", {
    Name = "Disconnect", Size = UDim2.new(1, -16, 0, 38), Position = UDim2.fromOffset(8, 8),
    BackgroundColor3 = C.accent2, Text = "Disconnect", TextColor3 = C.text,
    Font = Enum.Font.GothamBold, TextSize = 18, AutoButtonColor = true,
}, panel)
corner(disconnectBtn, 8); stroke(disconnectBtn, C.accent, 1)

local title = new("TextLabel", {
    Name = "Title", Size = UDim2.new(1, -16, 0, 34), Position = UDim2.fromOffset(8, 54),
    BackgroundTransparency = 1, Text = "404 Mod Menu [P0]", TextColor3 = C.text,
    Font = Enum.Font.GothamBlack, TextSize = 22, Active = true,
}, panel)
local crumb = new("TextLabel", {
    Size = UDim2.new(1, -16, 0, 16), Position = UDim2.fromOffset(8, 86),
    BackgroundTransparency = 1, Text = "drag title to move", TextColor3 = C.dim,
    Font = Enum.Font.Gotham, TextSize = 12,
}, panel)

local list = new("ScrollingFrame", {
    Name = "List", Size = UDim2.new(1, -76, 1, -116), Position = UDim2.fromOffset(38, 106),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, ScrollBarThickness = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, panel)
corner(list, 8)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)
new("UIPadding", {
    PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
}, list)

local function sideBar(xScale, xOff, glyph, delta)
    local b = new("TextButton", {
        Size = UDim2.new(0, 26, 1, -116), Position = UDim2.new(xScale, xOff, 0, 106),
        BackgroundColor3 = C.accent2, Text = glyph, TextColor3 = C.text,
        Font = Enum.Font.GothamBold, TextSize = 16, AutoButtonColor = true,
    }, panel)
    corner(b, 6)
    b.Activated:Connect(function()
        local y = math.clamp(list.CanvasPosition.Y + delta, 0, math.max(0, list.AbsoluteCanvasSize.Y - list.AbsoluteSize.Y))
        list.CanvasPosition = Vector2.new(0, y)
    end)
end
sideBar(0, 8, "v\nv\nv", 110)           -- scroll down (left bar, like the template)
sideBar(1, -34, "^\n^\n^", -110)        -- scroll up   (right bar)

-- open / close pill --------------------------------------------------
local openBtn = new("TextButton", {
    Name = "Open", Size = UDim2.fromOffset(64, 30), AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 6), BackgroundColor3 = C.bg, Text = "404",
    TextColor3 = C.accent, Font = Enum.Font.GothamBlack, TextSize = 16,
}, gui)
corner(openBtn, 15); stroke(openBtn, C.accent, 2)

local function setMenu(open)
    S.menuOpen = open
    panel.Visible = open
end
openBtn.Activated:Connect(function() setMenu(not S.menuOpen) end)
UIS.InputBegan:Connect(function(i, gp)
    if not gp and i.KeyCode == TOGGLE_KEY then setMenu(not S.menuOpen) end
end)

-- scale for small screens
local function fitScale()
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    panel:FindFirstChildOfClass("UIScale").Scale = math.clamp(vp.Y / 560, 0.62, 1)
end
fitScale()
if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale)
end

-- drag by title ------------------------------------------------------
do
    local dragging, startPos, startInput
    title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startInput, startPos = true, i.Position, panel.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- disconnect (game's own action: leaves your room, same as the in-game terminal) --
disconnectBtn.Activated:Connect(function()
    pcall(function() Remotes.Action:FireServer("disconnect", {}) end)
end)

-- on-screen joysticks for the hands -----------------------------------
local function makeStick(label, pos, stick, title)
    local base = new("Frame", {
        Name = "HandStick" .. label, Size = UDim2.fromOffset(110, 110), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = pos, BackgroundColor3 = C.bg, BackgroundTransparency = 0.25, Active = true, Visible = false,
    }, gui)
    corner(base, 55); stroke(base, C.accent, 2)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(44, 44), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        BackgroundColor3 = C.accent, BackgroundTransparency = 0.1,
    }, base)
    corner(knob, 22)
    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 0, -18), BackgroundTransparency = 1,
        Text = title or (label .. " HAND"), TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 12,
    }, base)

    local function update(p)
        local c = base.AbsolutePosition + base.AbsoluteSize / 2
        local d = (Vector2.new(p.X, p.Y) + GuiService:GetGuiInset() - c) / (base.AbsoluteSize.X / 2)
        if d.Magnitude > 1 then d = d.Unit end
        stick.value = Vector2.new(d.X, -d.Y)
        knob.Position = UDim2.new(0.5, d.X * 33, 0.5, d.Y * 33)
    end
    local function reset()
        stick.input = nil
        stick.value = Vector2.new(0, 0)
        knob.Position = UDim2.fromScale(0.5, 0.5)
    end
    base.InputBegan:Connect(function(i)
        if not stick.input and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1) then
            stick.input = i
            update(i.Position)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        local si = stick.input
        if si and (i == si or (si.UserInputType == Enum.UserInputType.MouseButton1 and i.UserInputType == Enum.UserInputType.MouseMovement)) then
            update(i.Position)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i == stick.input then reset() end
    end)
    stick.frame, stick.reset = base, reset
end
makeStick("LEFT",  UDim2.new(0, 95, 0.45, 0), stickL)
makeStick("RIGHT", UDim2.new(1, -95, 0.45, 0), stickR)
makeStick("FREECAM", UDim2.new(0, 95, 0.72, 0), stickF, "FREECAM MOVE")

-- hand lift buttons (hold ^ to raise that hand, v to lower it, o to reset)
local liftFrames = {}
local function makeLift(index, pos)
    local f = new("Frame", {
        Name = "HandLift" .. index, Size = UDim2.fromOffset(46, 150), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = pos, BackgroundTransparency = 1, Visible = false,
    }, gui)
    local function btn(glyph, y, dir)
        local b = new("TextButton", {
            Size = UDim2.fromOffset(46, 46), Position = UDim2.fromOffset(0, y), BackgroundColor3 = C.bg,
            BackgroundTransparency = 0.15, Text = glyph, TextColor3 = C.accent, Font = Enum.Font.GothamBlack,
            TextSize = 22, AutoButtonColor = false,
        }, f)
        corner(b, 23); stroke(b, C.accent, 2)
        if dir == 0 then
            b.Activated:Connect(function() handLift[index] = 0 end)
            return
        end
        b.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
                liftDir[index] = dir
                b.BackgroundColor3 = C.accent2
            end
        end)
        b.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
                if liftDir[index] == dir then liftDir[index] = 0 end
                b.BackgroundColor3 = C.bg
            end
        end)
    end
    btn("^", 0, 1)
    btn("o", 52, 0)
    btn("v", 104, -1)
    table.insert(liftFrames, f)
end
makeLift(1, UDim2.new(0, 180, 0.45, 0))
makeLift(2, UDim2.new(1, -180, 0.45, 0))

-- pad up / down arrows ----------------------------------------------
local padGui = new("Frame", {
    Name = "PadControls", Size = UDim2.fromOffset(64, 140), AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0.72, 0), BackgroundTransparency = 1, Visible = false,
}, gui)
local function padButton(glyph, y, dir)
    local b = new("TextButton", {
        Size = UDim2.fromOffset(64, 64), Position = UDim2.fromOffset(0, y), BackgroundColor3 = C.bg,
        BackgroundTransparency = 0.15, Text = glyph, TextColor3 = C.accent, Font = Enum.Font.GothamBlack,
        TextSize = 30, AutoButtonColor = false,
    }, padGui)
    corner(b, 32); stroke(b, C.accent, 2)
    b.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            padDir = dir
            b.BackgroundColor3 = C.accent2
        end
    end)
    b.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            if padDir == dir then padDir = 0 end
            b.BackgroundColor3 = C.bg
        end
    end)
end
padButton("^", 0, 1)
padButton("v", 76, -1)

-- player tracker -----------------------------------------------------
local trackerFrame = new("Frame", {
    Name = "Tracker", Size = UDim2.fromOffset(290, 340), AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -14, 0, 50), BackgroundColor3 = C.bg, Visible = false, Active = true,
}, gui)
corner(trackerFrame, 12); stroke(trackerFrame, C.accent, 2)
local tHead = new("TextLabel", {
    Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Text = "PLAYER TRACKER", TextColor3 = C.text,
    Font = Enum.Font.GothamBlack, TextSize = 15, Active = true,
}, trackerFrame)
do -- drag by header
    local dragging, startPos, startInput
    tHead.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startInput, startPos = true, i.Position, trackerFrame.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            trackerFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
end

local function trackerBox(y, h)
    local f = new("ScrollingFrame", {
        Size = UDim2.new(1, -16, 0, h), Position = UDim2.fromOffset(8, y), BackgroundColor3 = C.panel,
        BorderSizePixel = 0, ScrollBarThickness = 3, CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, trackerFrame)
    corner(f, 6)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, f)
    new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 4) }, f)
    return f
end
local rosterBox = trackerBox(30, 130)
new("TextLabel", {
    Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 164), BackgroundTransparency = 1,
    Text = "ACTIVITY (joins / leaves / room switches)", TextColor3 = C.dim, Font = Enum.Font.GothamBold, TextSize = 11,
}, trackerFrame)
local logBox = trackerBox(182, 150)

local function addLine(parent, text, color, order)
    return new("TextLabel", {
        Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Text = text, TextColor3 = color, Font = Enum.Font.Gotham, TextSize = 12, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = order,
    }, parent)
end

local GREEN, RED, YELLOW = Color3.fromRGB(90, 225, 130), Color3.fromRGB(255, 85, 95), Color3.fromRGB(255, 205, 70)
local logLines, logCount = {}, 0
local function logEvent(text, color)
    logCount = logCount + 1
    table.insert(logLines, addLine(logBox, os.date("%H:%M:%S") .. "  " .. text, color, logCount))
    if #logLines > 80 then table.remove(logLines, 1):Destroy() end
    task.defer(function() logBox.CanvasPosition = Vector2.new(0, 1e6) end)
end

-- The room CODE itself is not replicated to other clients, but every player's room
-- session id + queue is, so rooms are numbered per session: Room #1, Room #2 ...
local roomNums, roomCount = {}, 0
local function roomKey(p)
    local sess = p:GetAttribute("MtnRoomSession")
    if sess == nil then return "lobby" end
    return tostring(sess) .. "|" .. tostring(p:GetAttribute("MtnRoomQueue"))
end
local function roomLabel(p)
    local sess = p:GetAttribute("MtnRoomSession")
    if sess == nil then return "Lobby" end
    if not roomNums[sess] then roomCount = roomCount + 1; roomNums[sess] = roomCount end
    local txt = "Room #" .. roomNums[sess]
    local q = p:GetAttribute("MtnRoomQueue")
    if q and q ~= "DEFAULT" then txt = txt .. " (" .. string.lower(tostring(q)) .. ")" end
    if sess == LP:GetAttribute("MtnRoomSession") then txt = txt .. " [your room]" end
    return txt
end
local function pname(p)
    local n = p:GetAttribute("MtnName")
    if type(n) ~= "string" or n == "" then n = p.DisplayName end
    return (p == LP) and (n .. " (you)") or n
end

local lastKey, lastLabel = {}, {}
local function checkRoom(p)
    local key = roomKey(p)
    if lastKey[p] == key then return end
    local oldLabel = lastLabel[p] or "Lobby"
    local newLabel = roomLabel(p)
    local hadRoom = lastKey[p] ~= nil and lastKey[p] ~= "lobby"
    lastKey[p], lastLabel[p] = key, newLabel
    if key == "lobby" then
        logEvent(pname(p) .. " left " .. oldLabel .. " -> Lobby", RED)
    elseif not hadRoom then
        logEvent(pname(p) .. " joined " .. newLabel, GREEN)
    else
        logEvent(pname(p) .. " switched " .. oldLabel .. " -> " .. newLabel, YELLOW)
    end
end

local function watchPlayer(p, announce)
    lastKey[p] = roomKey(p)
    lastLabel[p] = roomLabel(p)
    if announce then logEvent(pname(p) .. " joined the server", GREEN) end
    local function changed() task.delay(0.2, checkRoom, p) end -- session + queue arrive together
    p:GetAttributeChangedSignal("MtnRoomSession"):Connect(changed)
    p:GetAttributeChangedSignal("MtnRoomQueue"):Connect(changed)
end
for _, p in ipairs(Players:GetPlayers()) do watchPlayer(p, false) end
Players.PlayerAdded:Connect(function(p) watchPlayer(p, true) end)
Players.PlayerRemoving:Connect(function(p)
    logEvent(pname(p) .. " left the server (was in " .. (lastLabel[p] or "Lobby") .. ")", RED)
    lastKey[p], lastLabel[p] = nil, nil
end)

task.spawn(function() -- live roster, grouped by room
    while true do
        task.wait(1)
        if trackerFrame.Visible then
            for _, c in ipairs(rosterBox:GetChildren()) do
                if c:IsA("TextLabel") then c:Destroy() end
            end
            local groups, names = {}, {}
            for _, p in ipairs(Players:GetPlayers()) do
                local l = roomLabel(p)
                if not groups[l] then groups[l] = {}; table.insert(names, l) end
                table.insert(groups[l], pname(p))
            end
            table.sort(names)
            local order = 0
            for _, l in ipairs(names) do
                order = order + 1
                addLine(rosterBox, l .. "  (" .. #groups[l] .. ")", C.accent, order)
                for _, n in ipairs(groups[l]) do
                    order = order + 1
                    addLine(rosterBox, "   " .. n, C.text, order)
                end
            end
        end
    end
end)

-- feature switchboard ------------------------------------------------
local refreshers = {}

local function setFlag(key, value)
    S[key] = value
    if key == "fly" then
        S.flyLift = value -- one-time hop so the rig is airborne when fly starts
    elseif key == "god" then
        local r = Remotes:FindFirstChild("Godmode404") or Remotes:WaitForChild("Godmode404", 3)
        if r then
            r:FireServer(value == true)
        else
            S.god = false
            crumb.Text = "Godmode: server script missing"
        end
    elseif key == "tracker" then
        trackerFrame.Visible = value
    elseif key == "speed" then
        applySpeed()
    elseif key == "rainbow" then
        if value then S.flicker = false else restoreMonkeyColor() end
    elseif key == "flicker" then
        if value then S.rainbow = false else restoreMonkeyColor() end
    elseif key == "pad" then
        padGui.Visible = value or S.freecam
        if not value then removePad() end
    elseif key == "hands" then
        stickL.frame.Visible = value
        stickR.frame.Visible = value
        for _, f in ipairs(liftFrames) do f.Visible = value end
        if value then
            S.highlight = true
            setMarkers(true)
        else
            stickL.reset(); stickR.reset()
            handPos[1], handPos[2] = nil, nil
            handLift[1], handLift[2] = 0, 0
            liftDir[1], liftDir[2] = 0, 0
        end
    elseif key == "highlight" then
        setMarkers(value)
    elseif key == "esp" then
        if not value then clearEsp() end
    elseif key == "freecam" or key == "third" then
        freePos = nil
        if key == "freecam" then
            stickF.frame.Visible = value
            if not value then stickF.reset() end
        end
        if key == "freecam" and value and S.third then S.third = false end -- one camera mode at a time
        if key == "third" and value and S.freecam then
            S.freecam = false; padGui.Visible = S.pad
            stickF.frame.Visible = false; stickF.reset()
        end
        if key == "freecam" then padGui.Visible = value or S.pad end
        if not (S.freecam or S.third) then
            removeDummy()
            if not (S.highlight or S.hands) then setMarkers(false) end
        end
    elseif key == "copy" or key == "copyFollow" then
        copyAnchor = nil
        if (key == "copy" or key == "copyFollow") and not value and copyReturn then
            pendingTp = copyReturn  -- back to where you started
            copyReturn = nil
        end
        if key == "copy" and value and not S.copyTarget then
            crumb.Text = "Pick a player in the list"
        end
    end
    for _, fn in ipairs(refreshers) do fn() end
end

-- stop copying if the copied player leaves the server
Players.PlayerRemoving:Connect(function(p)
    if S.copyTarget == p.UserId then
        S.copyTarget = nil
        if S.copy then setFlag("copy", false) else for _, fn in ipairs(refreshers) do fn() end end
    end
end)

-- page content -------------------------------------------------------
local PAGES = {
    { name = "Movement Mods", items = {
        { t = "toggle", label = "Fly",         key = "fly" },
        { t = "toggle", label = "Noclip",      key = "noclip" },
        { t = "toggle", label = "Speed Boost", key = "speed" },
        { t = "step",   label = "Speed Amount", key = "speedMult", min = 1, max = 12, step = 0.5, fmt = "x%.1f",
          after = function() applySpeed() end },
    } },
    { name = "Rig Mods", items = {
        { t = "toggle", label = "Long Arms",      key = "longArms" },
        { t = "step",   label = "Arm Length",     key = "armScale", min = 1.2, max = 6, step = 0.2, fmt = "x%.1f" },
        { t = "toggle", label = "Hand Joysticks", key = "hands" },
        { t = "toggle", label = "Hand Highlight", key = "highlight" },
    } },
    { name = "Tag Mods", items = {
        { t = "toggle", label = "Godmode (untaggable)", key = "god" },
        { t = "note",   label = "Needs 404_GodmodeServer in ServerScriptService. Works in casual, infection and hunt." },
        { t = "toggle", label = "Troll Tagged Players", key = "troll" },
        { t = "step",   label = "Trigger Distance (studs)", key = "trollRange", min = 5, max = 40, step = 1, fmt = "%.0f" },
        { t = "step",   label = "Behind Distance (studs)", key = "trollBehind", min = 2, max = 15, step = 1, fmt = "%.0f" },
        { t = "note",   label = "When a tagged player closes in within the trigger distance you teleport behind them. Needs you to be untagged." },
    } },
    { name = "Copy Mods", items = {
        { t = "toggle",  label = "Copy Player Movement", key = "copy" },
        { t = "players" },
        { t = "toggle",  label = "Follow Player", key = "copyFollow" },
        { t = "step",    label = "Side Distance (studs)", key = "copyDist", min = 0, max = 12, step = 1, fmt = "%.0f" },
        { t = "note",    label = "Others see you doing their head / hand / body moves. They must be in your room." },
        { t = "note",    label = "Follow ON = you sit inside their body (raise Side Distance to stand next to them). OFF = you stay put, only the motion is copied." },
    } },
    { name = "Camera Mods", items = {
        { t = "toggle", label = "Freecam", key = "freecam" },
        { t = "step",   label = "Freecam Speed", key = "freecamSpeed", min = 5, max = 150, step = 5, fmt = "%.0f" },
        { t = "note",   label = "Camera flies, your body AND head stay put. Use the FREECAM MOVE joystick (or WASD), drag / mouse to look, arrows or E / Q for height." },
        { t = "toggle", label = "Third Person", key = "third" },
        { t = "step",   label = "Camera Distance", key = "thirdDist", min = 4, max = 40, step = 1, fmt = "%.0f" },
        { t = "note",   label = "Camera behind your head. A red stand-in shows your body. Close the menu on PC to look around." },
    } },
    { name = "Spaz Mods", items = {
        { t = "toggle", label = "Head Spaz", key = "spazHead" },
        { t = "toggle", label = "Body Spaz", key = "spazBody" },
        { t = "toggle", label = "Hand Spaz", key = "spazHands" },
        { t = "step",   label = "Spaz Intensity", key = "spazAmt", min = 0.2, max = 3, step = 0.2, fmt = "x%.1f" },
    } },
    { name = "Spin Mods", items = {
        { t = "toggle", label = "Head Spinning", key = "spinHead" },
        { t = "toggle", label = "Spin X axis", key = "spinX" },
        { t = "toggle", label = "Spin Y axis", key = "spinY" },
        { t = "toggle", label = "Spin Z axis", key = "spinZ" },
        { t = "step",   label = "Spin Speed (turns/sec)", key = "spinSpeed", min = 0.25, max = 10, step = 0.25, fmt = "%.2f/s" },
    } },
    { name = "Tracker Mods", items = {
        { t = "toggle", label = "Player Tracker", key = "tracker" },
        { t = "note",   label = "Shows who joined, left or switched rooms. Room codes are hidden from clients, so rooms are numbered." },
    } },
    { name = "Visual Mods", items = {
        { t = "toggle", label = "Rainbow Monkey",          key = "rainbow" },
        { t = "toggle", label = "Black/White Flicker",     key = "flicker" },
        { t = "toggle", label = "Player Highlighter",      key = "esp" },
        { t = "toggle", label = "  Nametags + Usernames",  key = "espTags" },
        { t = "toggle", label = "  Tagged / Untagged",     key = "espStatus" },
        { t = "toggle", label = "  Show Their Color",      key = "espColor" },
        { t = "note",   label = "Outlines players in your room: red = tagged, green = untagged. Tag shows game name, Roblox @username, distance and monkey color." },
    } },
    { name = "World Mods", items = {
        { t = "toggle", label = "Touch Teleport", key = "tp" },
        { t = "toggle", label = "Teleport Lag Bypass", key = "tpBypass" },
        { t = "note",   label = "Stops the game pulling you back after a far teleport (blocks server corrections + snap-backs) and pins you at the spot for 0.3s." },
        { t = "note",   label = "Tap a floor or wall to teleport. Tapping air / sky does nothing." },
        { t = "toggle", label = "Floating Pad", key = "pad" },
        { t = "note",   label = "Pad arrows: right side of screen, or E / Q on PC" },
    } },
}

local currentPage = nil

local function clearList()
    refreshers = {}
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("GuiObject") then c:Destroy() end
    end
end

local function rowButton(text, order)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = C.btn, Text = text, TextColor3 = C.text,
        Font = Enum.Font.GothamMedium, TextSize = 16, AutoButtonColor = true, LayoutOrder = order,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, list)
    corner(b, 7)
    new("UIPadding", { PaddingLeft = UDim.new(0, 12) }, b)
    return b
end

local render

local function addToggle(item, order)
    local b = rowButton(item.label, order)
    local tag = new("TextLabel", {
        Size = UDim2.fromOffset(46, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
        BackgroundColor3 = C.bg, Text = "OFF", TextColor3 = C.dim, Font = Enum.Font.GothamBold, TextSize = 12,
    }, b)
    corner(tag, 11)
    local function refresh()
        local on = S[item.key]
        tag.Text = on and "ON" or "OFF"
        tag.TextColor3 = on and C.text or C.dim
        tag.BackgroundColor3 = on and C.accent or C.bg
    end
    refresh()
    table.insert(refreshers, refresh)
    b.Activated:Connect(function() setFlag(item.key, not S[item.key]) end)
end

local function addStepper(item, order)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 62), BackgroundColor3 = C.btn, LayoutOrder = order,
    }, list)
    corner(row, 7)
    new("TextLabel", {
        Size = UDim2.new(1, -12, 0, 22), Position = UDim2.fromOffset(12, 4), BackgroundTransparency = 1,
        Text = item.label, TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    local minus = new("TextButton", {
        Size = UDim2.fromOffset(40, 28), Position = UDim2.new(0, 12, 1, -34), BackgroundColor3 = C.bg,
        Text = "-", TextColor3 = C.accent, Font = Enum.Font.GothamBlack, TextSize = 20,
    }, row)
    local plus = new("TextButton", {
        Size = UDim2.fromOffset(40, 28), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 1, -34),
        BackgroundColor3 = C.bg, Text = "+", TextColor3 = C.accent, Font = Enum.Font.GothamBlack, TextSize = 20,
    }, row)
    local box = new("TextBox", {
        Size = UDim2.new(1, -116, 0, 28), Position = UDim2.fromOffset(58, 28), BackgroundColor3 = C.bg,
        Text = "", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 15, ClearTextOnFocus = false,
    }, row)
    corner(minus, 6); corner(plus, 6); corner(box, 6)

    local function set(v)
        v = math.clamp(v, item.min, item.max)
        v = math.floor(v / item.step + 0.5) * item.step
        S[item.key] = v
        box.Text = string.format(item.fmt, v)
        if item.after then item.after() end
    end
    box.Text = string.format(item.fmt, S[item.key])
    minus.Activated:Connect(function() set(S[item.key] - item.step) end)
    plus.Activated:Connect(function() set(S[item.key] + item.step) end)
    box.FocusLost:Connect(function()
        local n = tonumber((box.Text:gsub("[^%d%.%-]", "")))
        set(n or S[item.key])
    end)
end

-- player list shown right under the "Copy Player Movement" button
local copyStatus
local function addPlayerList(order)
    local box = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = C.btn, LayoutOrder = order,
    }, list)
    corner(box, 7)
    new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, box)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
    }, box)
    local status = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Text = "", TextColor3 = C.dim,
        Font = Enum.Font.GothamMedium, TextSize = 12, TextWrapped = true, LayoutOrder = 0,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, box)
    copyStatus = status

    local lastSig
    local function rebuild(force)
        local plist = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then table.insert(plist, p) end
        end
        local mine = LP:GetAttribute("MtnRoomSession")
        table.sort(plist, function(a, b)
            local am = (mine ~= nil and a:GetAttribute("MtnRoomSession") == mine) and 0 or 1
            local bm = (mine ~= nil and b:GetAttribute("MtnRoomSession") == mine) and 0 or 1
            if am ~= bm then return am < bm end
            return pname(a):lower() < pname(b):lower()
        end)
        local sig = tostring(S.copyTarget)
        for _, p in ipairs(plist) do sig = sig .. "|" .. p.UserId .. ":" .. roomKey(p) end
        if not force and sig == lastSig then return end
        lastSig = sig

        for _, c in ipairs(box:GetChildren()) do
            if c:IsA("TextButton") or (c:IsA("TextLabel") and c ~= status) then c:Destroy() end
        end
        if #plist == 0 then
            new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, Text = "No other players in the server",
                TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 12, LayoutOrder = 1,
            }, box)
            return
        end
        for i, p in ipairs(plist) do
            local sel = S.copyTarget == p.UserId
            local b = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = sel and C.accent2 or C.bg,
                Text = pname(p) .. "\n" .. roomLabel(p), TextColor3 = sel and C.text or C.dim,
                Font = Enum.Font.GothamMedium, TextSize = 12, LayoutOrder = i,
                TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
                AutoButtonColor = true,
            }, box)
            corner(b, 6)
            new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
            if sel then stroke(b, C.accent, 1) end
            b.Activated:Connect(function()
                S.copyTarget = p.UserId
                copyAnchor = nil
                copyLastPose = nil
                rebuild(true)
            end)
        end
    end
    rebuild(true)
    table.insert(refreshers, function() rebuild(true) end)

    task.spawn(function()
        while box.Parent do
            task.wait(1)
            rebuild(false)
        end
    end)
end

-- live status line above the player list
task.spawn(function()
    while true do
        task.wait(0.25)
        local s = copyStatus
        if s and s.Parent then
            local tp = S.copyTarget and Players:GetPlayerByUserId(S.copyTarget)
            local txt
            if not tp then
                txt = S.copy and "Pick a player below to copy" or "Tap a player to select, then turn Copy ON"
            elseif not S.copy then
                txt = "Selected: " .. pname(tp) .. "  (Copy is OFF)"
            elseif Avatars and Avatars.packets and Avatars.packets[tp.UserId]
                and os.clock() - copyLastAt <= 3 and copyLastPose == Avatars.packets[tp.UserId] then
                txt = "Copying " .. pname(tp) .. (S.copyFollow and "  (following)" or "  (in place)")
            else
                txt = "Waiting for " .. pname(tp) .. "'s movement... (must be in your room)"
            end
            s.Text = txt
        end
    end
end)

render = function()
    clearList()
    local order = 0
    local function nextOrder() order = order + 1; return order end

    if currentPage == nil then
        crumb.Text = "Select a category"
        for idx, page in ipairs(PAGES) do
            local b = rowButton(page.name, nextOrder())
            new("TextLabel", {
                Size = UDim2.fromOffset(20, 20), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0),
                BackgroundTransparency = 1, Text = ">", TextColor3 = C.accent, Font = Enum.Font.GothamBlack, TextSize = 16,
            }, b)
            b.Activated:Connect(function() currentPage = idx; render() end)
        end
    else
        local page = PAGES[currentPage]
        crumb.Text = page.name
        local back = rowButton("< Back", nextOrder())
        back.TextColor3 = C.accent
        back.Activated:Connect(function() currentPage = nil; render() end)
        for _, item in ipairs(page.items) do
            if item.t == "toggle" then
                addToggle(item, nextOrder())
            elseif item.t == "step" then
                addStepper(item, nextOrder())
            elseif item.t == "players" then
                addPlayerList(nextOrder())
            elseif item.t == "note" then
                new("TextLabel", {
                    Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Text = item.label,
                    TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 12, TextWrapped = true,
                    LayoutOrder = nextOrder(),
                }, list)
            end
        end
    end
    list.CanvasPosition = Vector2.new(0, 0)
end
render()

-- keep things tidy when the script is removed
script.Destroying:Connect(function()
    WalkSim.step = origStep
    WalkSim.correct = origCorrect
    removePad()
    clearEsp()
    removeDummy()
    setMarkers(false)
    restoreMonkeyColor()
    gui:Destroy()
end)

print("[404 Mod Menu] loaded - tap the 404 pill or press RightShift")
