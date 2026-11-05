-- TSB - Halloween Auto Farm v6.0  (Obsidian UI, mobile friendly)
-- Owner: lo6 | selam0exe   -   Discord: godvillage.
-- Server: https://discord.gg/PDyTWAEkPt
--
-- Priority: Kill (Penyta first) > Shop re-roll > Collect candy > Open doors > Visit trashcans
--
-- Main     : auto doors, auto trashcans, auto kill + skills 1-4 + auto ultimate, auto candy, shop re-roll
-- Visuals  : door ESP, NPC ESP (live HP), player ESP, fullbright
-- Player   : walkspeed, jump, infinite jump, fly, noclip, dash (adjustable distance), FPS boost, utilities
-- Webhooks : paste your Discord webhook, get alerts when Penyta dies (+ who, best effort) and candy milestones
-- Settings : credits, config save/load, themes, and all the name settings (the separate Names tab is gone)
--
-- NOTES
-- - "Who killed Penyta" is best-effort: the game may not expose a killer tag we can read reliably.
--   If it only ever says "Unknown", tell the owner so the detection can be adjusted.
-- - The door approach now offsets away from the door's own facing and temporarily disables
--   collision while standing there, to stop the camera from clipping into nearby tree geometry.
--   This is a practical fix, not a guaranteed one - if it still happens, raise the "Door forward
--   offset" slider in Main > Movement.
-- - FPS boost now re-applies itself continuously instead of once, and forces render quality down.
--   Actual FPS gained depends on your device; turning it off restores everything.
--
-- If something fails, the console prints "[TSB] ..." lines. Send the last one to the owner.

local function __tsbMain()

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local lp = Players.LocalPlayer
while not lp do
    task.wait()
    lp = Players.LocalPlayer
end

local DISCORD_URL = "https://discord.gg/PDyTWAEkPt"
local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"

local okLib, Library = pcall(function()
    return loadstring(game:HttpGet(repo .. "Library.lua"))()
end)
if not okLib or type(Library) ~= "table" then
    warn("[TSB] Could not load the Obsidian UI library: " .. tostring(Library))
    return
end
print("[TSB] Obsidian UI loaded")

-- addons are optional (config/theme); the script still works without them
local ThemeManager, SaveManager
pcall(function() ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))() end)
pcall(function() SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))() end)

local Toggles, Options = Library.Toggles, Library.Options

local VIM, VU
pcall(function() VIM = game:GetService("VirtualInputManager") end)
pcall(function() VU = game:GetService("VirtualUser") end)

-- ========== defaults / safe accessors ==========
local DEF = {
    MoveMode = "TP", TweenSpeed = 100, StepDelay = 0.6, DoorYOffset = -3, DoorForwardOffset = 4,
    CandyFilter = "Door/trash/kill drops", CandyWindow = 25, CandyRadius = 100, CandyMode = "Both", CandyDelay = 0.1,
    AttackMethod = "Auto", SkillMethod = "Auto", SkillInterval = 1.5,
    KillDist = 3, AttackDelay = 0.12, KillRange = 300, RerollCost = 500,
    FlySpeed = 60, WalkSpeedValue = 32, JumpValue = 60, DashDistance = 40,
    UltInterval = 1, UltKey = "R",
    PromptKeys = "trick or treat", DoorKeys = "door", TrashKeys = "trashcan", NpcKeys = "zombie",
    BossKeys = "boss", PinataKeys = "penyta", ExcludeKeys = "dummy", CandyFolder = "CandyVisuals",
    CandyNames = "candy, blox, choco", ShopKeys = "shopkeeper", RerollKeys = "reroll", CandyCountPath = "",
    DoorESPColor = Color3.fromRGB(255, 170, 0),
    NpcESPColor = Color3.fromRGB(255, 60, 60),
    PlayerESPColor = Color3.fromRGB(80, 170, 255),
    WebhookURL = "",
    CandyMilestone = 500,
}

local function T(n)
    local t = Toggles[n]
    return t ~= nil and t.Value == true
end

local function O(n)
    local o = Options[n]
    if o ~= nil and o.Value ~= nil then
        return o.Value
    end
    return DEF[n]
end

local function try(fn)
    local ok, err = pcall(fn)
    if not ok then
        warn("[TSB] UI section failed: " .. tostring(err))
    end
end

local function notify(msg, t)
    pcall(function() Library:Notify(msg, t or 4) end)
end

-- ========== state ==========
local alive = true
local conns = {}
local K = { prompt = {}, door = {}, trash = {}, npc = {}, boss = {}, exclude = {}, candy = {}, shop = {}, reroll = {}, pinata = {} }
local candyQueue, recentSpots = {}, {}
local doorCooldown = setmetatable({}, { __mode = "k" })
local trashDone = setmetatable({}, { __mode = "k" })
local killBan = setmetatable({}, { __mode = "k" })
local npcSet = setmetatable({}, { __mode = "k" })
local bosses = setmetatable({}, { __mode = "k" })
local candyState = setmetatable({}, { __mode = "k" })
local healthSrc = setmetatable({}, { __mode = "k" })
local candyBaseline = false
local origin = nil
local invisSeat = nil
local doorList, doorScanAt = {}, 0
local trashList, trashScanAt = {}, 0
local learned, learning, learnBuf, hookInstalled = {}, nil, {}, false
local lastSkill = { 0, 0, 0, 0 }
local lastUlt = 0
local shopModel, shopScanAt, lastShop = nil, 0, 0
local candyFn, candySrc, candyFnAt, candyFnPath = nil, "", 0, ""
local candyLabel = nil
local webhookLabel = nil
local lastCandyMilestoneSent = 0
local weAreAttacking = setmetatable({}, { __mode = "k" }) -- [npcModel] = true while our stepKill loop is on it
local reportedDead = setmetatable({}, { __mode = "k" })
local TRASH_COOLDOWN = 90
local F = {}

local function track(c)
    conns[#conns + 1] = c
    return c
end

-- ========== helpers ==========
local function getHRP()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
    local c = lp.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function norm(s)
    s = string.lower(tostring(s))
    s = s:gsub("\195[\177\145]", "n") -- n with tilde -> n
    s = s:gsub("[%s_%-%.]", "")
    return s
end

local function parseList(str)
    local t = {}
    for w in string.gmatch(tostring(str or ""), "[^,]+") do
        w = norm(w)
        if w ~= "" then
            t[#t + 1] = w
        end
    end
    return t
end

local function hasKeyword(text, list)
    if #list == 0 then return false end
    text = norm(text)
    for _, k in ipairs(list) do
        if string.find(text, k, 1, true) then
            return true
        end
    end
    return false
end

local function toNum(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    local s = tostring(v):gsub(",", "")
    return tonumber(s)
end

local function fmtNum(v)
    return tostring(math.floor((v or 0) + 0.5))
end

-- ========== webhooks ==========
-- Finds whichever HTTP-with-headers function this executor exposes.
local function getRequester()
    return http_request or request or (syn and syn.request) or (fluxus and fluxus.request)
        or (http and http.request)
end

local function sendWebhook(title, description, color, fields)
    local url = O("WebhookURL")
    if not url or url == "" then return false, "No webhook URL set" end
    local req = getRequester()
    if not req then return false, "This executor has no HTTP request function with headers" end
    local embed = {
        title = title,
        description = description,
        color = color or 15105570,
        fields = fields,
    }
    local ok, body = pcall(function()
        return HttpService:JSONEncode({ embeds = { embed } })
    end)
    if not ok then return false, "Could not encode webhook payload" end
    local ok2, res = pcall(function()
        return req({
            Url = url,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body,
        })
    end)
    if not ok2 then return false, tostring(res) end
    return true
end

local function refreshKeys()
    K.prompt = parseList(O("PromptKeys"))
    K.door = parseList(O("DoorKeys"))
    K.trash = parseList(O("TrashKeys"))
    K.npc = parseList(O("NpcKeys"))
    K.boss = parseList(O("BossKeys"))
    K.exclude = parseList(O("ExcludeKeys"))
    K.candy = parseList(O("CandyNames"))
    K.shop = parseList(O("ShopKeys"))
    K.reroll = parseList(O("RerollKeys"))
    K.pinata = parseList(O("PinataKeys"))
end

local function posOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Attachment") then return inst.WorldPosition end
    if inst:IsA("Model") then return inst:GetPivot().Position end
    return nil
end

-- never move to NaN positions or into the void
local function safePos(v)
    if typeof(v) ~= "Vector3" then return false end
    if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z then return false end
    if v.Magnitude > 50000 then return false end
    if v.Y < Workspace.FallenPartsDestroyHeight + 100 then return false end
    return true
end

local function rootOf(m)
    if not m then return nil end
    if m:IsA("BasePart") then return m end
    return m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

local function isCharacterPart(inst)
    if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then
        return true
    end
    local p = inst.Parent
    while p and p ~= Workspace do
        if p:IsA("Model") and p:FindFirstChildOfClass("Humanoid") then
            return true
        end
        p = p.Parent
    end
    return false
end

local function chainText(inst, levels)
    local t, a = {}, inst
    for _ = 1, levels do
        if not a or a == Workspace then break end
        t[#t + 1] = a.Name
        a = a.Parent
    end
    return table.concat(t, " ")
end

local function matchDoor(p)
    local chain = chainText(p.Parent, 6)
    local text = p.Name .. " " .. p.ObjectText .. " " .. p.ActionText .. " " .. chain
    if not hasKeyword(text, K.prompt) then return false end
    if #K.door > 0 and not hasKeyword(p.ObjectText .. " " .. chain, K.door) then return false end
    return true
end

local function doorInfo(p)
    local a = p.Parent
    if a and a:IsA("Attachment") then a = a.Parent end
    if not a then return nil, nil end
    local target = a
    if #K.door > 0 then
        local x, lvl = a, 0
        while x and x ~= Workspace and lvl < 6 do
            if (x:IsA("Model") or x:IsA("BasePart")) and hasKeyword(x.Name, K.door) then
                target = x
                break
            end
            x = x.Parent
            lvl += 1
        end
    end
    local part = target:IsA("BasePart") and target or target:FindFirstChildWhichIsA("BasePart", true)
    if not (target:IsA("Model") or target:IsA("BasePart")) then
        target = part
    end
    return target, part
end

local function ensureOrigin(hrp)
    if not origin and hrp then
        origin = hrp.CFrame
    end
end

-- Move to a CFrame with the selected movement mode (TP or Tween)
local function moveTo(cf)
    local hrp = getHRP()
    if not hrp or not safePos(cf.Position) then return false end
    if O("MoveMode") == "Tween" then
        local dist = (hrp.Position - cf.Position).Magnitude
        if dist > 3 then
            local t = math.clamp(dist / O("TweenSpeed"), 0.05, 20)
            local wasAnchored = hrp.Anchored
            hrp.Anchored = true
            local done = false
            local tw = TweenService:Create(hrp, TweenInfo.new(t, Enum.EasingStyle.Linear), { CFrame = cf })
            local c = tw.Completed:Connect(function() done = true end)
            tw:Play()
            local t0 = os.clock()
            while alive and not done and os.clock() - t0 < t + 0.3 do
                task.wait()
            end
            c:Disconnect()
            pcall(function() tw:Cancel() end)
            local h2 = getHRP()
            if h2 then
                h2.Anchored = wasAnchored
                h2.AssemblyLinearVelocity = Vector3.zero
            end
            return true
        end
    end
    hrp.CFrame = cf
    hrp.AssemblyLinearVelocity = Vector3.zero
    return true
end

-- Real "hold E" on a prompt (uses the prompt's own hold duration)
local function holdPrompt(p)
    pcall(function()
        p.RequiresLineOfSight = false
        p:InputHoldBegin()
        task.wait(p.HoldDuration + 0.15)
        p:InputHoldEnd()
    end)
end

local function guiParent()
    local p = nil
    pcall(function()
        p = (gethui and gethui()) or game:GetService("CoreGui")
    end)
    return p or lp:FindFirstChildOfClass("PlayerGui")
end

local function resetVisibility()
    local c = lp.Character
    if not c then return end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("BasePart") then
            d.LocalTransparencyModifier = 0
        end
    end
end

local espFolder = Instance.new("Folder")
espFolder.Name = "TSBESP"
local okParent = pcall(function() espFolder.Parent = guiParent() end)
if not okParent or not espFolder.Parent then
    pcall(function() espFolder.Parent = lp:WaitForChild("PlayerGui", 5) end)
end

-- ========== attack / skills (learned remotes + fallbacks) ==========
local KEYCODES = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
local VKEYS = { 0x31, 0x32, 0x33, 0x34 }

local function refreshArgs(args)
    -- swap stale Tool/Instance arguments (after respawn) for the current ones
    for i = 1, args.n do
        local a = args[i]
        if type(a) == "table" then
            for k, v in pairs(a) do
                if typeof(v) == "Instance" and not v:IsDescendantOf(game) then
                    local repl = (lp.Backpack and lp.Backpack:FindFirstChild(v.Name)) or (lp.Character and lp.Character:FindFirstChild(v.Name))
                    if repl then a[k] = repl end
                end
            end
        elseif typeof(a) == "Instance" and not a:IsDescendantOf(game) then
            local repl = (lp.Backpack and lp.Backpack:FindFirstChild(a.Name)) or (lp.Character and lp.Character:FindFirstChild(a.Name))
            if repl then args[i] = repl end
        end
    end
end

local function replay(id)
    local list = learned[id]
    if not list then return false end
    for _, rec in ipairs(list) do
        local r = rec.remote
        if not (r and r.Parent) then
            local ch = lp.Character
            r = ch and ch:FindFirstChild(rec.name)
            rec.remote = r
        end
        if r then
            pcall(refreshArgs, rec.args)
            pcall(function()
                r:FireServer(table.unpack(rec.args, 1, rec.args.n))
            end)
        end
    end
    return true
end

local function installHook()
    if hookInstalled then return true end
    if not (hookmetamethod and getnamecallmethod) then return false end
    local ncc = newcclosure or function(f) return f end
    local ok = pcall(function()
        local old
        old = hookmetamethod(game, "__namecall", ncc(function(self, ...)
            if learning and getnamecallmethod() == "FireServer" then
                local okm, match = pcall(function()
                    return typeof(self) == "Instance" and self.ClassName == "RemoteEvent"
                        and (self.Name == "Communicate" or self.Parent == lp.Character)
                end)
                if okm and match then
                    learnBuf[#learnBuf + 1] = { remote = self, name = self.Name, args = table.pack(...) }
                end
            end
            return old(self, ...)
        end))
    end)
    hookInstalled = ok
    return ok
end

local function startLearn(id, label)
    if not installHook() then
        notify("Your executor does not support hookmetamethod. Use the other methods.", 6)
        return
    end
    if learning then
        notify("Already learning, wait a few seconds.", 3)
        return
    end
    learnBuf = {}
    learning = id
    notify("Now tap " .. label .. " ONCE (5 seconds)", 5)
    task.delay(5, function()
        learning = nil
        if #learnBuf == 0 then
            notify("Nothing captured for " .. label .. ". Try again and tap it once.", 5)
            return
        end
        local keep, names = {}, {}
        for i = 1, math.min(#learnBuf, 6) do
            keep[#keep + 1] = learnBuf[i]
            local a1 = learnBuf[i].args[1]
            if type(a1) == "table" then
                names[#names + 1] = tostring(a1.Goal or a1.goal or learnBuf[i].name)
            else
                names[#names + 1] = learnBuf[i].name
            end
        end
        learned[id] = keep
        notify("Learned " .. label .. ": " .. table.concat(names, ", "), 7)
    end)
end

local function fireInput()
    if mouse1click then
        if pcall(mouse1click) then return end
    end
    if VIM then
        local cam = Workspace.CurrentCamera
        local s = cam and cam.ViewportSize or Vector2.new(500, 300)
        local ok = pcall(function()
            VIM:SendMouseButtonEvent(s.X / 2, s.Y / 2, 0, true, game, 0)
            task.wait()
            VIM:SendMouseButtonEvent(s.X / 2, s.Y / 2, 0, false, game, 0)
        end)
        if ok then return end
    end
    if VU then
        pcall(function()
            VU:CaptureController()
            VU:ClickButton1(Vector2.new(0, 0))
        end)
    end
end

-- Unverified guess based on how I remember TSB's M1 remote
local function fireGuess()
    local ch = lp.Character
    local comm = ch and ch:FindFirstChild("Communicate")
    if comm and comm:IsA("RemoteEvent") then
        pcall(function() comm:FireServer({ Goal = "LeftClick", Mobile = true }) end)
        pcall(function() comm:FireServer({ Goal = "LeftClickRelease", Mobile = true }) end)
        return true
    end
    return false
end

local function attackClick()
    local mode = O("AttackMethod")
    if mode == "Learned M1" then
        if not replay("M1") then fireInput() end
    elseif mode == "Remote guess" then
        if not fireGuess() then fireInput() end
    elseif mode == "Input click" then
        fireInput()
    else -- Auto
        if not replay("M1") then
            fireGuess()
            fireInput()
        end
    end
end

local function pressKey(i)
    if VIM then
        local ok = pcall(function()
            VIM:SendKeyEvent(true, KEYCODES[i], false, game)
            task.wait(0.05)
            VIM:SendKeyEvent(false, KEYCODES[i], false, game)
        end)
        if ok then return true end
    end
    if keypress and keyrelease then
        local ok = pcall(function()
            keypress(VKEYS[i])
            task.wait(0.05)
            keyrelease(VKEYS[i])
        end)
        if ok then return true end
    end
    return false
end

local function useSkill(i)
    local method = O("SkillMethod")
    if method ~= "Key press only" then
        if replay("S" .. i) then return true end
        if method == "Learned only" then return false end
    end
    return pressKey(i)
end

-- fires at most one ready skill per call
local function useSkills()
    local now = os.clock()
    for i = 1, 4 do
        if T("Skill" .. i) and now - lastSkill[i] >= O("SkillInterval") then
            lastSkill[i] = now
            useSkill(i)
            task.wait(0.12)
            return true
        end
    end
    return false
end

-- ========== ultimate ==========
-- Best-effort readiness check: looks for a GUI element whose name mentions
-- "ultimate"/"ult" and reads a fill bar (Frame/ImageLabel Size.X.Scale) or a
-- NumberValue/attribute called Charge/Value/Cooldown. If nothing matching is
-- found, "Ignore readiness check" makes it just try on the interval instead.
local function scanUltReady()
    local pg = lp:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    local best = nil
    for _, d in ipairs(pg:GetDescendants()) do
        local lname = string.lower(d.Name)
        if string.find(lname, "ult", 1, true) then
            if (d:IsA("Frame") or d:IsA("ImageLabel")) and d.Size then
                local scale = d.Size.X.Scale
                if scale > 0 then
                    best = (best == nil) and (scale >= 0.98) or (best or (scale >= 0.98))
                end
            end
            for _, attrName in ipairs({ "Charge", "Value", "Progress", "Percent" }) do
                local okA, v = pcall(function() return d:GetAttribute(attrName) end)
                if okA and type(v) == "number" then
                    best = (v >= 99) or best
                end
            end
        end
    end
    return best
end

local function useUlt()
    local method = O("SkillMethod")
    if method ~= "Key press only" then
        if replay("ULT") then return true end
        if method == "Learned only" then return false end
    end
    if VIM then
        local code = Enum.KeyCode[O("UltKey")] or Enum.KeyCode.R
        local ok = pcall(function()
            VIM:SendKeyEvent(true, code, false, game)
            task.wait(0.05)
            VIM:SendKeyEvent(false, code, false, game)
        end)
        return ok
    end
    return false
end

-- fires the ultimate if it looks ready (or always, if the user chose to skip the check)
local function stepUlt()
    if not T("AutoUlt") then return false end
    local now = os.clock()
    if now - lastUlt < O("UltInterval") then return false end
    local ready = T("UltIgnoreReady")
    if not ready then
        local detected = scanUltReady()
        if detected == nil then
            -- couldn't find a readable ult bar at all; don't spam blindly unless asked to
            return false
        end
        ready = detected
    end
    if ready then
        lastUlt = now
        useUlt()
        return true
    end
    return false
end

-- ========== invisible (others, experimental) ==========
local function setInvisOthers(on)
    if on then
        local char = lp.Character
        local hrp = getHRP()
        if invisSeat or not char or not hrp then return end
        local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
        if not torso then
            notify("Invisible: torso not found", 4)
            return
        end
        local saved = hrp.CFrame
        local far = Vector3.new(-25.95, 84, 3537.55)
        char:PivotTo(CFrame.new(far))
        task.wait(0.15)
        local seat = Instance.new("Seat")
        seat.Name = "InvisChair"
        seat.Transparency = 1
        seat.CanCollide = false
        seat.Anchored = false
        seat.Position = far
        seat.Parent = Workspace
        local weld = Instance.new("Weld")
        weld.Part0 = seat
        weld.Part1 = torso
        weld.Parent = seat
        task.wait()
        seat.CFrame = saved
        invisSeat = seat
    else
        if invisSeat then
            invisSeat:Destroy()
            invisSeat = nil
        end
    end
end

-- ========== spots (where candy is allowed to be collected) ==========
local function addSpot(pos)
    if not pos then return end
    local last = recentSpots[#recentSpots]
    if last and (last.pos - pos).Magnitude < 15 and os.clock() - last.t < 5 then
        last.pos = pos
        last.t = os.clock()
        return
    end
    recentSpots[#recentSpots + 1] = { pos = pos, t = os.clock() }
    if #recentSpots > 60 then
        table.remove(recentSpots, 1)
    end
end

local function nearSpot(pos)
    local now = os.clock()
    local win = O("CandyWindow")
    local rad = O("CandyRadius")
    for i = #recentSpots, 1, -1 do
        local s = recentSpots[i]
        if now - s.t > win + 10 then
            table.remove(recentSpots, i)
        elseif now - s.t <= win and (s.pos - pos).Magnitude <= rad then
            return true
        end
    end
    return false
end

-- ========== NPCs / health ==========

-- Best-effort killer lookup. TSB may not expose this at all, in which case
-- this keeps returning "Unknown" - that's a game limitation, not a bug here.
local function findKiller(m, hum)
    if weAreAttacking[m] then
        return lp.Name .. " (you)"
    end
    local holders = { m, hum }
    for _, h in ipairs(holders) do
        if h then
            local okc, creator = pcall(function() return h:FindFirstChild("creator") end)
            if okc and creator and creator:IsA("ObjectValue") and creator.Value then
                local v = creator.Value
                if v:IsA("Player") then return v.Name end
                local plr = Players:GetPlayerFromCharacter(v)
                if plr then return plr.Name end
                return v.Name
            end
            for _, attrName in ipairs({ "Killer", "Tagger", "LastHitBy", "DamageSource" }) do
                local oka, v = pcall(function() return h:GetAttribute(attrName) end)
                if oka and type(v) == "string" and v ~= "" then
                    return v
                end
            end
        end
    end
    return "Unknown"
end

local function hookPenytaDeath(m)
    local hum = m:FindFirstChildOfClass("Humanoid")
    if not hum or reportedDead[m] then return end
    reportedDead[m] = true
    track(hum.Died:Connect(function()
        if not T("WebhookOnKill") then return end
        local killer = findKiller(m, hum)
        local candy, src = getCandyCount()
        task.spawn(function()
            sendWebhook(
                "Penyta down",
                m.Name .. " was killed.",
                3066993,
                {
                    { name = "Killed by", value = killer, inline = true },
                    { name = "Candy", value = candy and (fmtNum(candy) .. (src ~= "" and (" (" .. src .. ")") or "")) or "unknown", inline = true },
                }
            )
        end)
    end))
end

local function registerNpc(m, silent)
    if not m or not m:IsA("Model") then return end
    if Players:GetPlayerFromCharacter(m) then return end
    local hasHum = m:FindFirstChildOfClass("Humanoid") ~= nil
    local isP = hasKeyword(m.Name, K.pinata)
    if not (hasHum or isP) then return end
    if isP and not hasHum then
        -- never treat candy models as a Pinata
        if hasKeyword(m.Name, K.candy) then return end
        local cname = O("CandyFolder")
        if cname ~= "" then
            local f = Workspace:FindFirstChild(cname)
            if f and m:IsDescendantOf(f) then return end
        end
    end
    if npcSet[m] == nil then
        npcSet[m] = isP
        if isP then
            if not silent then
                notify("Penyta spawned: " .. m.Name, 4)
            end
            pcall(hookPenytaDeath, m)
        end
    end
    if not bosses[m] and hasKeyword(m.Name, K.boss) then
        bosses[m] = true
        if not silent then
            notify("Boss spawned: " .. m.Name, 4)
        end
    end
end

local function isTarget(m, isP)
    local hum = m:FindFirstChildOfClass("Humanoid")
    if isP then
        if hum and hum.Health <= 0 then return false end
        return true
    end
    if not hum or hum.Health <= 0 then return false end
    if hasKeyword(m.Name, K.shop) or hasKeyword(m.Name, K.exclude) or hasKeyword(m.Name, K.boss) then
        return false
    end
    if T("KillAll") then return true end
    return hasKeyword(m.Name, K.npc)
end

local function pinataAlive()
    local now = os.clock()
    for m, isP in pairs(npcSet) do
        if isP and m.Parent and (killBan[m] or 0) < now then
            local hum = m:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health > 0 then
                return true
            end
        end
    end
    return false
end

-- Pinata first, then the nearest normal target
local function nearestTarget(hrp)
    local bestP, bpd = nil, math.huge
    local best, bd = nil, O("KillRange")
    local now = os.clock()
    for m, isP in pairs(npcSet) do
        if m.Parent then
            if (killBan[m] or 0) < now and isTarget(m, isP) then
                local root = rootOf(m)
                if root then
                    local d = (root.Position - hrp.Position).Magnitude
                    if isP then
                        if d < bpd then bestP, bpd = m, d end
                    elseif d < bd then
                        best, bd = m, d
                    end
                end
            end
        else
            npcSet[m] = nil
        end
    end
    return bestP or best
end

local function findHealthSource(m, hum)
    local holders = { m }
    if hum then holders[#holders + 1] = hum end
    local root = rootOf(m)
    if root and root ~= m then holders[#holders + 1] = root end
    for _, h in ipairs(holders) do
        local okA, attrs = pcall(function() return h:GetAttributes() end)
        if okA then
            local curKey, mxKey
            for k, v in pairs(attrs) do
                if type(v) == "number" then
                    local lk = string.lower(k)
                    if lk == "health" or lk == "hp" or lk == "currenthealth" or lk == "curhealth" then
                        curKey = k
                    elseif lk == "maxhealth" or lk == "maxhp" then
                        mxKey = k
                    end
                end
            end
            if curKey then
                return function()
                    return h:GetAttribute(curKey), mxKey and h:GetAttribute(mxKey) or nil
                end
            end
        end
    end
    local curObj, mxObj
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("NumberValue") or d:IsA("IntValue") then
            local lk = string.lower(d.Name)
            if lk == "health" or lk == "hp" or lk == "currenthealth" then
                curObj = d
            elseif lk == "maxhealth" or lk == "maxhp" then
                mxObj = d
            end
        end
    end
    if curObj then
        return function()
            return curObj.Value, mxObj and mxObj.Value or nil
        end
    end
    return nil
end

-- returns current, max, isCustomSource
local function healthOf(m, hum)
    local src = healthSrc[m]
    if src == nil then
        local ok, f = pcall(findHealthSource, m, hum)
        src = (ok and f) or false
        healthSrc[m] = src
    end
    if src then
        local ok, c, x = pcall(src)
        if ok and type(c) == "number" then
            return c, x or (hum and hum.MaxHealth) or c, true
        end
    end
    if hum then
        return hum.Health, hum.MaxHealth, false
    end
    return nil, nil, false
end

local function hpText(cur, mx, custom, hum)
    if not cur then return "HP ?" end
    local s = "HP " .. fmtNum(cur) .. "/" .. fmtNum(mx or cur)
    if custom and hum and math.abs(hum.Health - cur) > 1 then
        s = s .. " (hum " .. fmtNum(hum.Health) .. ")"
    end
    return s
end

-- ========== candy ==========
local function candyRoot()
    local name = O("CandyFolder")
    if name ~= "" then
        local f = Workspace:FindFirstChild(name)
        if f then return f, true end
    end
    return Workspace, false
end

local function isCandyCandidate(d, inFolder)
    if d:IsA("Model") then
        if d:FindFirstChildOfClass("Humanoid") then return false end
    elseif d:IsA("BasePart") then
        local p = d.Parent
        if p and (p:IsA("BasePart") or p:IsA("Model")) then return false end
    else
        return false
    end
    if #K.candy > 0 then
        if not hasKeyword(d.Name, K.candy) then return false end
    elseif not inFolder then
        return false
    end
    return true
end

local function candyVisible(inst)
    if inst:IsA("BasePart") then
        return inst.Transparency < 0.95
    end
    if inst:IsA("Model") then
        local p = inst:FindFirstChildWhichIsA("BasePart", true)
        return p ~= nil and p.Transparency < 0.95
    end
    return false
end

local function enqueueCandy(d, pos)
    if not safePos(pos) then return false end
    if O("CandyFilter") ~= "Any new candy" and not nearSpot(pos) then return false end
    if #candyQueue >= 250 then
        table.remove(candyQueue, 1)
    end
    candyQueue[#candyQueue + 1] = { inst = d, t = os.clock(), pos = pos }
    return true
end

-- A candy counts as "dropped" when it appears, becomes visible or jumps to a new
-- position near a door / trashcan / kill spot (works for reused candy objects too).
-- Candies parked in the void are ignored.
local function pollCandy()
    local root, inFolder = candyRoot()
    local now = os.clock()
    local win = O("CandyWindow")
    local n = 0
    for _, d in ipairs(root:GetDescendants()) do
        n += 1
        if n % 2500 == 0 then task.wait() end
        if isCandyCandidate(d, inFolder) then
            local pos = posOf(d)
            if pos then
                local vis = candyVisible(d)
                local st = candyState[d]
                if not st then
                    st = { pos = pos, vis = vis, enq = false, t = candyBaseline and now or -1e6, tries = 0 }
                    candyState[d] = st
                else
                    local moved = (pos - st.pos).Magnitude > 3
                    local appeared = vis and not st.vis
                    if vis and (moved or appeared) then
                        st.t = now
                        st.tries = 0
                    end
                end
                if not vis then
                    st.enq = false
                elseif st.enq then
                    if now - st.t > 3 then
                        st.enq = false
                    end
                elseif now - st.t < win and st.tries < 2 then
                    if enqueueCandy(d, pos) then
                        st.enq = true
                        st.tries = st.tries + 1
                    end
                end
                st.pos = pos
                st.vis = vis
            end
        end
    end
    candyBaseline = true
end

local function enqueueAllVisible()
    local root, inFolder = candyRoot()
    local hrp = getHRP()
    local list, n = {}, 0
    for _, d in ipairs(root:GetDescendants()) do
        n += 1
        if n % 2500 == 0 then task.wait() end
        if isCandyCandidate(d, inFolder) and candyVisible(d) then
            local pos = posOf(d)
            if pos and safePos(pos) then
                list[#list + 1] = { d = d, pos = pos, dist = hrp and (pos - hrp.Position).Magnitude or 0 }
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    for _, it in ipairs(list) do
        candyQueue[#candyQueue + 1] = { inst = it.d, t = os.clock(), pos = it.pos }
    end
    notify("Queued " .. #list .. " visible candies", 4)
end

local function collectCandy(inst, hrp)
    local pos = posOf(inst)
    if not pos or not safePos(pos) then return end
    local part = inst:IsA("BasePart") and inst or inst:FindFirstChildWhichIsA("BasePart", true)
    local prompt = inst:FindFirstChildWhichIsA("ProximityPrompt", true)
    local mode = O("CandyMode")
    local useTouch = mode == "Touch" and firetouchinterest ~= nil and part ~= nil and prompt == nil
    if not useTouch then
        moveTo(CFrame.new(pos))
        task.wait(0.12)
    end
    if (mode == "Touch" or mode == "Both") and firetouchinterest and part then
        local h = getHRP()
        if h and part.Parent then
            pcall(function()
                firetouchinterest(h, part, 0)
                task.wait()
                firetouchinterest(h, part, 1)
            end)
        end
    end
    if prompt and prompt.Parent then
        holdPrompt(prompt)
    end
end

-- ========== candy counter + shopkeeper ==========
local function findCandySource()
    local custom = O("CandyCountPath")
    if custom ~= "" then
        local obj = lp
        for part in string.gmatch(custom, "[^%.]+") do
            obj = obj and obj:FindFirstChild(part)
        end
        if obj and obj ~= lp and obj:IsA("ValueBase") then
            return function() return toNum(obj.Value) end, custom
        end
    end
    for _, d in ipairs(lp:GetDescendants()) do
        if d:IsA("ValueBase") and string.find(string.lower(d.Name), "candy", 1, true) and toNum(d.Value) then
            return function() return toNum(d.Value) end, d.Name
        end
    end
    for k, v in pairs(lp:GetAttributes()) do
        if string.find(string.lower(k), "candy", 1, true) and toNum(v) then
            return function() return toNum(lp:GetAttribute(k)) end, "attr " .. k
        end
    end
    local pg = lp:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("TextLabel") and string.find(string.lower(d.Name), "candy", 1, true)
                and string.match(d.Text, "%d") then
                return function() return toNum(string.match(d.Text, "%d[%d,]*")) end, "gui " .. d.Name
            end
        end
    end
    return nil, ""
end

local function getCandyCount()
    local custom = O("CandyCountPath")
    if custom ~= candyFnPath then
        candyFnPath = custom
        candyFn = nil
        candyFnAt = 0
    end
    if not candyFn and os.clock() - candyFnAt > 5 then
        candyFnAt = os.clock()
        candyFn, candySrc = findCandySource()
    end
    if candyFn then
        local ok, v = pcall(candyFn)
        if ok and v then return v, candySrc end
        candyFn = nil
    end
    return nil, ""
end

local function findShopkeeper()
    if shopModel and shopModel.Parent then return shopModel end
    shopModel = nil
    for m in pairs(npcSet) do
        if m.Parent and hasKeyword(m.Name, K.shop) then
            shopModel = m
            return m
        end
    end
    if os.clock() - shopScanAt < 4 then return nil end
    shopScanAt = os.clock()
    local n = 0
    for _, d in ipairs(Workspace:GetDescendants()) do
        n += 1
        if n % 3000 == 0 then task.wait() end
        if d:IsA("Model") and hasKeyword(d.Name, K.shop) then
            shopModel = d
            return d
        end
    end
    return nil
end

local function guiVisible(g)
    local x = g
    while x and x ~= game do
        if x:IsA("GuiObject") and not x.Visible then return false end
        if x:IsA("ScreenGui") and not x.Enabled then return false end
        x = x.Parent
    end
    return true
end

local function findGuiButton(keys)
    local pg = lp:FindFirstChildOfClass("PlayerGui")
    if not pg or #keys == 0 then return nil end
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("TextButton") or d:IsA("ImageButton") then
            local text = d.Name
            if d:IsA("TextButton") then
                text = text .. " " .. d.Text
            end
            for _, c in ipairs(d:GetDescendants()) do
                if c:IsA("TextLabel") or c:IsA("TextButton") then
                    text = text .. " " .. c.Text
                end
            end
            if hasKeyword(text, keys) and guiVisible(d) then
                return d
            end
        end
    end
    return nil
end

local function clickGui(btn)
    local fired = false
    if firesignal then
        for _, s in ipairs({ "Activated", "MouseButton1Click" }) do
            if pcall(function() firesignal(btn[s]) end) then
                fired = true
            end
        end
    end
    if not fired and getconnections then
        for _, s in ipairs({ "Activated", "MouseButton1Click" }) do
            pcall(function()
                for _, c in ipairs(getconnections(btn[s])) do
                    c:Fire()
                end
            end)
            fired = true
        end
    end
    if not fired and VIM then
        local inset = GuiService:GetGuiInset()
        local sg = btn:FindFirstAncestorOfClass("ScreenGui")
        local yoff = (sg and sg.IgnoreGuiInset) and 0 or inset.Y
        local c = btn.AbsolutePosition + btn.AbsoluteSize / 2
        pcall(function()
            VIM:SendMouseButtonEvent(c.X, c.Y + yoff, 0, true, game, 0)
            task.wait(0.05)
            VIM:SendMouseButtonEvent(c.X, c.Y + yoff, 0, false, game, 0)
        end)
    end
end

local function doReroll()
    local m = findShopkeeper()
    if not m then
        notify("Shopkeeper not found (check the Names tab)", 5)
        return false
    end
    local pos = posOf(m)
    if not pos then return false end
    moveTo(CFrame.new(pos + Vector3.new(0, 0, 4)))
    task.wait(O("StepDelay"))

    local pressed = false
    for _, p in ipairs(m:GetDescendants()) do
        if p:IsA("ProximityPrompt") and p.Enabled then
            holdPrompt(p)
            pressed = true
            task.wait(0.4)
        end
    end
    if not pressed then
        local n = 0
        for _, p in ipairs(Workspace:GetDescendants()) do
            n += 1
            if n % 3000 == 0 then task.wait() end
            if p:IsA("ProximityPrompt") and p.Enabled then
                local pp = posOf(p.Parent)
                if pp and (pp - pos).Magnitude <= 20 then
                    holdPrompt(p)
                    pressed = true
                    task.wait(0.4)
                    break
                end
            end
        end
    end

    local btn
    for _ = 1, 12 do
        btn = findGuiButton(K.reroll)
        if btn then break end
        task.wait(0.3)
    end
    if not btn then
        notify("Re-roll button not found. Check 'Re-roll button text' in Names.", 6)
        return false
    end
    clickGui(btn)
    task.wait(0.6)
    notify("Re-roll clicked", 3)
    return true
end

-- ========== scans ==========
local function refreshDoors()
    if os.clock() - doorScanAt < 3 then return end
    doorScanAt = os.clock()
    local list, n = {}, 0
    for _, d in ipairs(Workspace:GetDescendants()) do
        n += 1
        if n % 3000 == 0 then task.wait() end
        if d:IsA("ProximityPrompt") and matchDoor(d) then
            list[#list + 1] = d
        end
    end
    doorList = list
end

local function refreshTrash()
    if os.clock() - trashScanAt < 5 then return end
    trashScanAt = os.clock()
    local list, n = {}, 0
    local included = {}
    local croot, inFolder = candyRoot()
    for _, d in ipairs(Workspace:GetDescendants()) do
        n += 1
        if n % 3000 == 0 then task.wait() end
        if (d:IsA("Model") or d:IsA("BasePart")) and hasKeyword(d.Name, K.trash)
            and not isCharacterPart(d) and not (inFolder and d:IsDescendantOf(croot)) then
            local skip = false
            local a = d.Parent
            while a and a ~= Workspace do
                if included[a] then
                    skip = true
                    break
                end
                a = a.Parent
            end
            if not skip then
                included[d] = true
                list[#list + 1] = d
            end
        end
    end
    trashList = list
end

local function scanConsole()
    local doorHits, prompts, trash, npcNames, candyByParent, pinatas = {}, {}, {}, {}, {}, {}
    local n = 0
    for _, d in ipairs(Workspace:GetDescendants()) do
        n += 1
        if n % 3000 == 0 then task.wait() end
        if d:IsA("ProximityPrompt") then
            local line = d:GetFullName() .. " | " .. d.ObjectText .. " / " .. d.ActionText .. " | hold=" .. tostring(d.HoldDuration) .. (d.Enabled and "" or " (disabled)")
            if matchDoor(d) then
                doorHits[#doorHits + 1] = line
            else
                prompts[#prompts + 1] = line
            end
        elseif d:IsA("Humanoid") and d.Parent and not Players:GetPlayerFromCharacter(d.Parent) then
            local nm = d.Parent.Name
            npcNames[nm] = (npcNames[nm] or 0) + 1
        elseif d:IsA("Model") and hasKeyword(d.Name, K.pinata) then
            pinatas[#pinatas + 1] = d:GetFullName()
        elseif (d:IsA("BasePart") or d:IsA("Model")) and #K.candy > 0 and hasKeyword(d.Name, K.candy) then
            local pn = d.Parent and d.Parent:GetFullName() or "nil"
            candyByParent[pn] = (candyByParent[pn] or 0) + 1
        elseif (d:IsA("Model") or d:IsA("BasePart")) and hasKeyword(d.Name, K.trash) then
            trash[#trash + 1] = d:GetFullName()
        end
    end

    print("---- WORKSPACE TOP LEVEL ----")
    local top = Workspace:GetChildren()
    for i = 1, math.min(#top, 80) do
        print(top[i].ClassName .. " | " .. top[i].Name .. " | children=" .. #top[i]:GetChildren())
    end
    print("---- DOOR PROMPTS MATCHED (" .. #doorHits .. ") ----")
    for i = 1, math.min(#doorHits, 40) do print(doorHits[i]) end
    print("---- OTHER PROMPTS (" .. #prompts .. ") ----")
    for i = 1, math.min(#prompts, 60) do print(prompts[i]) end
    print("---- NPCS (non-player humanoids) ----")
    for nm, c in pairs(npcNames) do print(nm .. " x" .. c) end
    print("---- PINATA MODELS (" .. #pinatas .. ") ----")
    for i = 1, math.min(#pinatas, 20) do print(pinatas[i]) end
    print("---- TRASHCANS (" .. #trash .. ") ----")
    for i = 1, math.min(#trash, 40) do print(trash[i]) end
    print("---- CANDY NAME MATCHES BY PARENT ----")
    for pn, c in pairs(candyByParent) do print(pn .. " x" .. c) end

    local f, inFolder = candyRoot()
    print("---- CANDY ROOT: " .. (inFolder and f:GetFullName() or "WORKSPACE (folder not found)") .. " ----")
    if inFolder then
        local kids = f:GetChildren()
        for i = 1, math.min(#kids, 30) do
            local c = kids[i]
            local hasPrompt = c:FindFirstChildWhichIsA("ProximityPrompt", true) and "prompt" or "-"
            local okT, t = pcall(function() return c:FindFirstChildWhichIsA("TouchTransmitter", true) end)
            local hasTouch = (okT and t) and "touch" or "-"
            local pos = posOf(c)
            print(c.ClassName .. " | " .. c.Name .. " | " .. hasPrompt .. " | " .. hasTouch .. " | vis=" .. tostring(candyVisible(c)) .. " | pos=" .. (pos and tostring(pos) or "?"))
        end
    end

    local cnt, src = getCandyCount()
    print("---- CANDY COUNT SOURCE: " .. (cnt and (src .. " = " .. cnt) or "not found") .. " ----")
    notify("Scan done: doors " .. #doorHits .. ", trashcans " .. #trash .. ". Check the console.", 6)
end

-- ========== ESP ==========
local doorEsp, npcEsp, plrEsp = {}, {}, {}

local function newLabelGui(adornee, width)
    local gui = Instance.new("BillboardGui")
    gui.AlwaysOnTop = true
    gui.Size = UDim2.new(0, width, 0, 26)
    gui.StudsOffset = Vector3.new(0, 3, 0)
    gui.Adornee = adornee
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.TextScaled = true
    lbl.Font = Enum.Font.GothamBold
    lbl.TextStrokeTransparency = 0.4
    lbl.Parent = gui
    gui.Parent = espFolder
    return gui, lbl
end

local function syncBoxEsp(store, items, color)
    local active = {}
    for _, it in ipairs(items) do
        local o = store[it.key]
        if o and (o.root ~= it.root or not o.box.Parent) then
            pcall(function()
                o.box:Destroy()
                o.gui:Destroy()
            end)
            store[it.key] = nil
            o = nil
        end
        if not o then
            local box = Instance.new("BoxHandleAdornment")
            box.Adornee = it.root
            box.AlwaysOnTop = true
            box.ZIndex = 1
            box.Size = Vector3.new(4, 5, 2)
            box.Transparency = 0.55
            box.Parent = espFolder
            local gui, lbl = newLabelGui(it.root, 200)
            o = { box = box, gui = gui, lbl = lbl, root = it.root }
            store[it.key] = o
        end
        o.lbl.Text = it.text
        o.lbl.TextColor3 = color
        o.box.Color3 = color
        active[it.key] = true
    end
    for k, o in pairs(store) do
        if not active[k] then
            pcall(function()
                o.box:Destroy()
                o.gui:Destroy()
            end)
            store[k] = nil
        end
    end
end

local function clearDoorEsp()
    for p, o in pairs(doorEsp) do
        pcall(function()
            if o.gui then o.gui:Destroy() end
            if o.hl then o.hl:Destroy() end
        end)
        doorEsp[p] = nil
    end
end

local function updateDoorEsp()
    if not T("DoorESP") then
        if next(doorEsp) then clearDoorEsp() end
        return
    end
    refreshDoors()
    local hrp = getHRP()
    local color = O("DoorESPColor")
    local active = {}
    local hlCount = 0
    for _, o in pairs(doorEsp) do
        if o.hl then hlCount += 1 end
    end
    for _, p in ipairs(doorList) do
        if p.Parent then
            local target, part = doorInfo(p)
            if part then
                active[p] = true
                local o = doorEsp[p]
                if not o then
                    o = {}
                    o.gui, o.lbl = newLabelGui(part, 140)
                    if hlCount < 20 and target then
                        local hl = Instance.new("Highlight")
                        hl.Adornee = target
                        hl.FillTransparency = 0.6
                        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        hl.Parent = espFolder
                        o.hl = hl
                        hlCount += 1
                    end
                    doorEsp[p] = o
                end
                local used = (not p.Enabled) or (os.clock() - (doorCooldown[p] or -100)) < 15
                local c = used and Color3.fromRGB(150, 150, 150) or color
                local dist = hrp and math.floor((part.Position - hrp.Position).Magnitude) or 0
                o.lbl.Text = "Door [" .. dist .. "m]" .. (used and " (used)" or "")
                o.lbl.TextColor3 = c
                if o.hl then
                    o.hl.FillColor = c
                    o.hl.OutlineColor = c
                end
            end
        end
    end
    for p, o in pairs(doorEsp) do
        if not active[p] then
            pcall(function()
                if o.gui then o.gui:Destroy() end
                if o.hl then o.hl:Destroy() end
            end)
            doorEsp[p] = nil
        end
    end
end

local function updateNpcEsp()
    local color = O("NpcESPColor")
    if not T("NpcESP") then
        if next(npcEsp) then syncBoxEsp(npcEsp, {}, color) end
        return
    end
    local hrp = getHRP()
    local items = {}
    for m in pairs(npcSet) do
        if m.Parent and not hasKeyword(m.Name, K.exclude) then
            local root = rootOf(m)
            local hum = m:FindFirstChildOfClass("Humanoid")
            if root then
                local cur, mx, custom = healthOf(m, hum)
                if not (cur and cur <= 0) then
                    local dist = hrp and math.floor((root.Position - hrp.Position).Magnitude) or 0
                    items[#items + 1] = {
                        key = m,
                        root = root,
                        text = m.Name .. " [" .. dist .. "m] " .. hpText(cur, mx, custom, hum),
                    }
                end
            end
        end
    end
    syncBoxEsp(npcEsp, items, color)
end

local function updatePlayerEsp()
    local color = O("PlayerESPColor")
    if not T("PlayerESP") then
        if next(plrEsp) then syncBoxEsp(plrEsp, {}, color) end
        return
    end
    local hrp = getHRP()
    local items = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p.Character then
            local root = p.Character:FindFirstChild("HumanoidRootPart")
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if root and hum and hum.Health > 0 then
                local dist = hrp and math.floor((root.Position - hrp.Position).Magnitude) or 0
                items[#items + 1] = {
                    key = p,
                    root = root,
                    text = p.Name .. " [" .. dist .. "m] HP " .. fmtNum(hum.Health) .. "/" .. fmtNum(hum.MaxHealth),
                }
            end
        end
    end
    syncBoxEsp(plrEsp, items, color)
end

local function clearAllEsp()
    clearDoorEsp()
    syncBoxEsp(npcEsp, {}, Color3.new(1, 1, 1))
    syncBoxEsp(plrEsp, {}, Color3.new(1, 1, 1))
end

-- ========== player features ==========
do
    local flyBV = nil
    local noclipOrig = setmetatable({}, { __mode = "k" })
    local savedWalk, savedJump = 16, nil
    local fb = nil
    local fps = { on = false, orig = setmetatable({}, { __mode = "k" }), c1 = nil, c2 = nil, light = nil, terrain = nil, quality = nil }
    local dashGui = nil
    local lastDash = 0

    function F.stopFly()
        if flyBV then
            pcall(function() flyBV:Destroy() end)
            flyBV = nil
        end
    end

    function F.flyStep(hrp, hum)
        if not flyBV or flyBV.Parent ~= hrp then
            F.stopFly()
            local bv = Instance.new("BodyVelocity")
            bv.MaxForce = Vector3.new(9e9, 9e9, 9e9)
            bv.Velocity = Vector3.zero
            bv.Parent = hrp
            flyBV = bv
        end
        local cam = Workspace.CurrentCamera
        local move = hum.MoveDirection
        if not cam or move.Magnitude < 0.05 then
            flyBV.Velocity = Vector3.zero
            return
        end
        local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector
        local fl = Vector3.new(look.X, 0, look.Z)
        local fr = Vector3.new(right.X, 0, right.Z)
        if fl.Magnitude < 0.05 or fr.Magnitude < 0.05 then
            flyBV.Velocity = move * O("FlySpeed")
            return
        end
        local fwd = move:Dot(fl.Unit)
        local rgt = move:Dot(fr.Unit)
        local dir = look * fwd + right * rgt
        if dir.Magnitude < 0.01 then
            flyBV.Velocity = Vector3.zero
        else
            flyBV.Velocity = dir.Unit * O("FlySpeed")
        end
    end

    function F.noclipStep()
        local ch = lp.Character
        if not ch then return end
        for _, d in ipairs(ch:GetDescendants()) do
            if d:IsA("BasePart") and d.CanCollide then
                noclipOrig[d] = true
                d.CanCollide = false
            end
        end
    end

    function F.noclipOff()
        for part in pairs(noclipOrig) do
            if part.Parent then
                pcall(function() part.CanCollide = true end)
            end
            noclipOrig[part] = nil
        end
    end

    function F.walkToggle(v)
        local hum = getHum()
        if not hum then return end
        if v then
            savedWalk = hum.WalkSpeed
        else
            hum.WalkSpeed = savedWalk
        end
    end

    function F.jumpToggle(v)
        local hum = getHum()
        if not hum then return end
        if v then
            savedJump = hum.UseJumpPower and hum.JumpPower or hum.JumpHeight
        elseif savedJump then
            if hum.UseJumpPower then
                hum.JumpPower = savedJump
            else
                hum.JumpHeight = savedJump
            end
        end
    end

    function F.playerTick()
        local hrp, hum = getHRP(), getHum()
        if not hrp or not hum then return end
        if T("WalkSpeedOn") then
            hum.WalkSpeed = O("WalkSpeedValue")
        end
        if T("JumpOn") then
            local v = O("JumpValue")
            if hum.UseJumpPower then
                hum.JumpPower = v
            else
                hum.JumpHeight = (v * v) / (2 * Workspace.Gravity)
            end
        end
        if T("FlyOn") then
            F.flyStep(hrp, hum)
        else
            F.stopFly()
        end
    end

    function F.doDash()
        local hrp, hum = getHRP(), getHum()
        if not hrp or not hum then return end
        if os.clock() - lastDash < 0.35 then return end
        lastDash = os.clock()
        local dir = hum.MoveDirection
        if dir.Magnitude < 0.05 then
            local lv = hrp.CFrame.LookVector
            dir = Vector3.new(lv.X, 0, lv.Z)
        end
        if dir.Magnitude < 0.01 then return end
        dir = dir.Unit
        local dist = O("DashDistance")
        local params = RaycastParams.new()
        params.FilterDescendantsInstances = { lp.Character }
        local hit = Workspace:Raycast(hrp.Position, dir * dist, params)
        if hit then
            dist = hit.Distance - 2
        end
        if dist < 1 then return end
        local steps = 6
        for _ = 1, steps do
            local h = getHRP()
            if not h then return end
            h.CFrame = h.CFrame + dir * (dist / steps)
            task.wait()
        end
    end

    function F.setDashButton(on)
        if on then
            if dashGui then return end
            local sg = Instance.new("ScreenGui")
            sg.Name = "TSBDash"
            sg.ResetOnSpawn = false
            sg.DisplayOrder = 50
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0, 70, 0, 70)
            btn.Position = UDim2.new(1, -110, 0.5, -35)
            btn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
            btn.BackgroundTransparency = 0.25
            btn.TextColor3 = Color3.new(1, 1, 1)
            btn.Text = "DASH"
            btn.Font = Enum.Font.GothamBold
            btn.TextSize = 16
            btn.Parent = sg
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(1, 0)
            corner.Parent = btn
            btn.Activated:Connect(function()
                task.spawn(F.doDash)
            end)
            local okp = pcall(function() sg.Parent = guiParent() end)
            if not okp or not sg.Parent then
                pcall(function() sg.Parent = lp:WaitForChild("PlayerGui", 5) end)
            end
            dashGui = sg
        elseif dashGui then
            pcall(function() dashGui:Destroy() end)
            dashGui = nil
        end
    end

    function F.fullbrightApply()
        if not fb then
            fb = {
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                FogEnd = Lighting.FogEnd,
                GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient,
            }
        end
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1e6
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
    end

    function F.fullbrightOff()
        if not fb then return end
        for k, v in pairs(fb) do
            pcall(function() Lighting[k] = v end)
        end
        fb = nil
    end

    local function isFx(d)
        return d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke")
            or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("PostEffect")
    end

    local function fpsApply(d)
        if isFx(d) and d.Enabled then
            if fps.orig[d] == nil then
                fps.orig[d] = true
            end
            d.Enabled = false
        end
    end

    -- Re-applies every render toggle on a timer. The game (or other scripts)
    -- can turn effects back on after we disable them once, so a single pass
    -- is not enough - this keeps forcing them back off while FPS boost is on.
    local function fpsReinforce()
        pcall(function()
            if Lighting.GlobalShadows then
                Lighting.GlobalShadows = false
            end
        end)
        pcall(function()
            local r = settings().Rendering
            if r.QualityLevel ~= Enum.QualityLevel.Level01 then
                r.QualityLevel = Enum.QualityLevel.Level01
            end
        end)
        pcall(function()
            local t = Workspace:FindFirstChildOfClass("Terrain")
            if t and (t.WaterWaveSize ~= 0 or t.WaterWaveSpeed ~= 0) then
                t.WaterWaveSize = 0
                t.WaterWaveSpeed = 0
                t.WaterReflectance = 0
            end
        end)
        local n = 0
        for _, root in ipairs({ Workspace, Lighting }) do
            for _, d in ipairs(root:GetDescendants()) do
                n += 1
                if n % 2000 == 0 then task.wait() end
                if not fps.on then return end
                pcall(fpsApply, d)
            end
        end
    end

    function F.setFps(on)
        if on == fps.on then return end
        fps.on = on
        if on then
            pcall(function()
                fps.light = Lighting.GlobalShadows
            end)
            pcall(function()
                local t = Workspace:FindFirstChildOfClass("Terrain")
                if t then
                    fps.terrain = { t, t.WaterWaveSize, t.WaterWaveSpeed, t.WaterReflectance }
                end
            end)
            pcall(function()
                fps.quality = settings().Rendering.QualityLevel
            end)
            fps.c1 = Workspace.DescendantAdded:Connect(function(d) pcall(fpsApply, d) end)
            fps.c2 = Lighting.DescendantAdded:Connect(function(d) pcall(fpsApply, d) end)
            task.spawn(function()
                while fps.on do
                    pcall(fpsReinforce)
                    task.wait(1)
                end
            end)
        else
            if fps.c1 then
                fps.c1:Disconnect()
                fps.c1 = nil
            end
            if fps.c2 then
                fps.c2:Disconnect()
                fps.c2 = nil
            end
            for d, v in pairs(fps.orig) do
                if d.Parent then
                    pcall(function() d.Enabled = v end)
                end
                fps.orig[d] = nil
            end
            pcall(function()
                if fps.light ~= nil then Lighting.GlobalShadows = fps.light end
            end)
            pcall(function()
                local tt = fps.terrain
                if tt and tt[1] then
                    tt[1].WaterWaveSize = tt[2]
                    tt[1].WaterWaveSpeed = tt[3]
                    tt[1].WaterReflectance = tt[4]
                end
            end)
            pcall(function()
                if fps.quality then settings().Rendering.QualityLevel = fps.quality end
            end)
            fps.light, fps.terrain, fps.quality = nil, nil, nil
        end
    end

    function F.rejoin()
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp)
        end)
        if not ok then
            pcall(function() TeleportService:Teleport(game.PlaceId, lp) end)
        end
    end

    function F.serverHop()
        local HttpService = game:GetService("HttpService")
        local ok, body = pcall(function()
            return game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100")
        end)
        if not ok then
            notify("Server hop failed: could not fetch the server list", 5)
            return
        end
        local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then
            notify("Server hop failed: bad server list", 5)
            return
        end
        for _, s in ipairs(data.data) do
            if s.id ~= game.JobId and type(s.playing) == "number" and type(s.maxPlayers) == "number"
                and s.playing < s.maxPlayers - 1 then
                notify("Hopping to another server...", 3)
                pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, lp) end)
                return
            end
        end
        notify("No free server found", 4)
    end

    function F.playerNames()
        local t = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lp then
                t[#t + 1] = p.Name
            end
        end
        table.sort(t)
        return t
    end

    function F.tpToPlayer(name)
        local p = name and Players:FindFirstChild(name)
        local ch = p and p.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if not root then
            notify("Player not found or has no character", 4)
            return
        end
        moveTo(CFrame.new(root.Position + Vector3.new(0, 0, 3)))
    end

    function F.cleanup()
        F.stopFly()
        F.noclipOff()
        F.setFps(false)
        F.fullbrightOff()
        F.setDashButton(false)
        local hum = getHum()
        if hum and T("WalkSpeedOn") then
            pcall(function() hum.WalkSpeed = savedWalk end)
        end
    end
end

-- ========== UI ==========
local Window = Library:CreateWindow({
    Title = "TSB Halloween",
    Footer = "Auto Farm v6.0 | by lo6 | selam0exe",
    Center = true,
    AutoShow = true,
    ShowCustomCursor = false,
})
print("[TSB] Window created")

local TabMain = Window:AddTab("Main")
local TabVisuals = Window:AddTab("Visuals")
local TabPlayer = Window:AddTab("Player")
local TabWebhooks = Window:AddTab("Webhooks")
local TabTesters = Window:AddTab("Testers")
local TabSettings = Window:AddTab("Settings")
local TabNames = TabSettings -- name/keyword settings now live at the bottom of Settings

-- Main
try(function()
    local G = TabMain:AddLeftGroupbox("Farm")
    G:AddToggle("AutoDoors", { Text = "Auto doors (Trick Or Treat)", Default = false })
    G:AddToggle("AutoTrash", { Text = "Auto trashcans (visit all)", Default = false })
    G:AddToggle("AutoKill", { Text = "Auto kill (mobs + Penyta)", Default = false })
    G:AddToggle("AutoCandy", {
        Text = "Auto collect candy",
        Default = false,
        Callback = function(v)
            if not v then
                candyBaseline = false
                candyQueue = {}
                for k in pairs(candyState) do
                    candyState[k] = nil
                end
            end
        end,
    })
    G:AddToggle("ReturnOrigin", { Text = "Return to start when idle", Default = true })
end)

try(function()
    local G = TabMain:AddLeftGroupbox("Movement")
    G:AddDropdown("MoveMode", { Values = { "TP", "Tween" }, Default = 1, Text = "Movement mode" })
    G:AddSlider("TweenSpeed", { Text = "Tween speed", Default = DEF.TweenSpeed, Min = 20, Max = 300, Rounding = 0, Suffix = " st/s" })
    G:AddSlider("StepDelay", { Text = "Door/trash step delay", Default = DEF.StepDelay, Min = 0.1, Max = 2, Rounding = 2, Suffix = "s" })
    G:AddSlider("DoorYOffset", { Text = "Door stand height (negative = below)", Default = DEF.DoorYOffset, Min = -10, Max = 5, Rounding = 1 })
    G:AddSlider("DoorForwardOffset", { Text = "Door forward offset (away from tree/wall)", Default = DEF.DoorForwardOffset, Min = 0, Max = 15, Rounding = 1, Suffix = " st" })
end)

try(function()
    local G = TabMain:AddRightGroupbox("Candy")
    G:AddDropdown("CandyFilter", { Values = { "Door/trash/kill drops", "Any new candy" }, Default = 1, Text = "Collect which candy" })
    G:AddSlider("CandyWindow", { Text = "Drop time window", Default = DEF.CandyWindow, Min = 5, Max = 60, Rounding = 0, Suffix = "s" })
    G:AddSlider("CandyRadius", { Text = "Drop radius", Default = DEF.CandyRadius, Min = 20, Max = 250, Rounding = 0, Suffix = " st" })
    G:AddDropdown("CandyMode", { Values = { "Move", "Touch", "Both" }, Default = 3, Text = "Collect method" })
    G:AddSlider("CandyDelay", { Text = "Delay between candies", Default = DEF.CandyDelay, Min = 0.05, Max = 1, Rounding = 2, Suffix = "s" })
    G:AddButton({ Text = "Collect all visible candy now", Func = function() task.spawn(enqueueAllVisible) end })
end)

try(function()
    local G = TabMain:AddRightGroupbox("Kill")
    G:AddDropdown("AttackMethod", { Values = { "Auto", "Learned M1", "Remote guess", "Input click" }, Default = 1, Text = "Attack method" })
    G:AddButton({ Text = "Learn M1 (then tap M1 once)", Func = function() startLearn("M1", "M1") end })
    G:AddToggle("KillAll", { Text = "Kill every NPC (except bosses)", Default = false })
    G:AddSlider("KillDist", { Text = "Distance behind NPC", Default = DEF.KillDist, Min = 2, Max = 8, Rounding = 1 })
    G:AddSlider("AttackDelay", { Text = "Attack interval", Default = DEF.AttackDelay, Min = 0.05, Max = 0.5, Rounding = 2, Suffix = "s" })
    G:AddSlider("KillRange", { Text = "Max range", Default = DEF.KillRange, Min = 30, Max = 1000, Rounding = 0 })
end)

try(function()
    local G = TabMain:AddLeftGroupbox("Skills (used while killing)")
    for i = 1, 4 do
        G:AddToggle("Skill" .. i, { Text = "Use skill " .. i, Default = false })
    end
    G:AddSlider("SkillInterval", { Text = "Skill interval", Default = DEF.SkillInterval, Min = 0.3, Max = 10, Rounding = 1, Suffix = "s" })
    G:AddDropdown("SkillMethod", { Values = { "Auto", "Learned only", "Key press only" }, Default = 1, Text = "Skill method" })
    for i = 1, 4 do
        G:AddButton({ Text = "Learn skill " .. i .. " (then tap it once)", Func = function() startLearn("S" .. i, "skill " .. i) end })
    end
end)

try(function()
    local G = TabMain:AddLeftGroupbox("Ultimate")
    G:AddToggle("AutoUlt", { Text = "Auto use ultimate when ready", Default = false })
    G:AddToggle("UltIgnoreReady", { Text = "Ignore readiness check (just press every interval)", Default = false })
    G:AddSlider("UltInterval", { Text = "Check / press interval", Default = DEF.UltInterval, Min = 0.3, Max = 15, Rounding = 1, Suffix = "s" })
    try(function()
        G:AddLabel("Ult key (used if nothing is learned)"):AddKeyPicker("UltKey", { Default = DEF.UltKey, NoUI = true, Text = "Ult key" })
    end)
    G:AddButton({ Text = "Learn ultimate (then tap it once)", Func = function() startLearn("ULT", "the ultimate") end })
    G:AddLabel("Readiness detection looks for an on-screen ultimate bar. If your HUD doesn't expose one, turn on 'Ignore readiness check'.", true)
end)

try(function()
    local G = TabMain:AddRightGroupbox("Shop (Halloween event)")
    G:AddToggle("AutoReroll", { Text = "Auto re-roll at candy cost", Default = false })
    G:AddSlider("RerollCost", { Text = "Candy per re-roll", Default = DEF.RerollCost, Min = 100, Max = 5000, Rounding = 0 })
    candyLabel = G:AddLabel("Candy: ?", true)
    G:AddButton({
        Text = "Re-roll now (Shopkeeper)",
        Func = function()
            task.spawn(function()
                ensureOrigin(getHRP())
                doReroll()
            end)
        end,
    })
end)

-- Visuals
try(function()
    local G = TabVisuals:AddLeftGroupbox("ESP")
    local t1 = G:AddToggle("DoorESP", { Text = "Door ESP", Default = false })
    local t2 = G:AddToggle("NpcESP", { Text = "NPC ESP (HumanoidRootPart + live HP)", Default = false })
    local t3 = G:AddToggle("PlayerESP", { Text = "Player ESP (HP)", Default = false })
    try(function() t1:AddColorPicker("DoorESPColor", { Default = DEF.DoorESPColor, Title = "Door ESP color" }) end)
    try(function() t2:AddColorPicker("NpcESPColor", { Default = DEF.NpcESPColor, Title = "NPC ESP color" }) end)
    try(function() t3:AddColorPicker("PlayerESPColor", { Default = DEF.PlayerESPColor, Title = "Player ESP color" }) end)
    G:AddLabel("NPC ESP skips players and names in the exclude list (dummy). If an NPC keeps its real HP in an attribute or value, that is shown first and the Humanoid HP in brackets.", true)
end)

try(function()
    local G = TabVisuals:AddRightGroupbox("World")
    G:AddToggle("Fullbright", {
        Text = "Fullbright",
        Default = false,
        Callback = function(v)
            if not v then pcall(F.fullbrightOff) end
        end,
    })
end)

-- Player
try(function()
    local G = TabPlayer:AddLeftGroupbox("Movement")
    G:AddToggle("WalkSpeedOn", { Text = "WalkSpeed", Default = false, Callback = function(v) pcall(F.walkToggle, v) end })
    G:AddSlider("WalkSpeedValue", { Text = "WalkSpeed value", Default = DEF.WalkSpeedValue, Min = 16, Max = 200, Rounding = 0 })
    G:AddToggle("JumpOn", { Text = "Jump power", Default = false, Callback = function(v) pcall(F.jumpToggle, v) end })
    G:AddSlider("JumpValue", { Text = "Jump power value", Default = DEF.JumpValue, Min = 30, Max = 300, Rounding = 0 })
    G:AddToggle("InfJump", { Text = "Infinite jump", Default = false })
    G:AddToggle("NoclipOn", {
        Text = "Noclip",
        Default = false,
        Callback = function(v)
            if not v then pcall(F.noclipOff) end
        end,
    })
end)

try(function()
    local G = TabPlayer:AddLeftGroupbox("Fly")
    G:AddToggle("FlyOn", { Text = "Fly (move with the joystick, look up/down to climb)", Default = false })
    G:AddSlider("FlySpeed", { Text = "Fly speed", Default = DEF.FlySpeed, Min = 10, Max = 300, Rounding = 0, Suffix = " st/s" })
end)

try(function()
    local G = TabPlayer:AddLeftGroupbox("Dash (our own dash)")
    G:AddSlider("DashDistance", { Text = "Dash distance", Default = DEF.DashDistance, Min = 5, Max = 150, Rounding = 0, Suffix = " st" })
    G:AddButton({ Text = "Dash now", Func = function() task.spawn(F.doDash) end })
    G:AddToggle("DashButton", { Text = "Show on-screen dash button", Default = false, Callback = function(v) pcall(F.setDashButton, v) end })
    try(function()
        G:AddLabel("Dash key"):AddKeyPicker("DashKey", {
            Default = "V",
            Mode = "Toggle",
            Text = "Dash key",
            NoUI = false,
            Callback = function() task.spawn(F.doDash) end,
        })
    end)
    G:AddLabel("This is a script dash (it stops at walls). The game's own dash distance cannot be changed from here.", true)
end)

try(function()
    local G = TabPlayer:AddRightGroupbox("Performance")
    G:AddToggle("FPSBoost", {
        Text = "FPS boost mode",
        Default = false,
        Callback = function(v) task.spawn(F.setFps, v) end,
    })
    G:AddLabel("Keeps forcing particles/trails/beams/post effects/shadows/water off and graphics quality down every second, so other scripts can't turn them back on. Turning it off restores everything. Actual FPS gain depends on your device.", true)
end)

try(function()
    local G = TabPlayer:AddRightGroupbox("Invisible")
    G:AddToggle("InvisLocal", {
        Text = "Invisible (local, only you)",
        Default = false,
        Callback = function(v)
            if not v then pcall(resetVisibility) end
        end,
    })
    G:AddToggle("InvisOthers", {
        Text = "Invisible (others) - experimental",
        Default = false,
        Callback = function(v) task.spawn(setInvisOthers, v) end,
    })
    G:AddLabel("Experimental: uses a seat-weld trick that I could not test in TSB. If your moveset or character breaks, turn it off or reset.", true)
end)

try(function()
    local G = TabPlayer:AddRightGroupbox("Utility")
    G:AddToggle("AntiAFK", { Text = "Anti AFK", Default = true })
    G:AddButton({
        Text = "Reset character",
        Func = function()
            local h = getHum()
            if h then h.Health = 0 end
        end,
    })
    G:AddButton({ Text = "Rejoin server", Func = function() F.rejoin() end })
    G:AddButton({ Text = "Server hop", Func = function() task.spawn(F.serverHop) end })
    local names = F.playerNames()
    if #names == 0 then names = { "-" } end
    G:AddDropdown("TPTarget", { Values = names, Default = 1, Text = "Teleport to player" })
    G:AddButton({ Text = "Teleport to selected player", Func = function() F.tpToPlayer(O("TPTarget")) end })
end)

-- Webhooks
try(function()
    local G = TabWebhooks:AddLeftGroupbox("Discord webhook")
    G:AddInput("WebhookURL", { Text = "Webhook URL", Default = "", Placeholder = "https://discord.com/api/webhooks/..." })
    G:AddToggle("WebhookOnKill", { Text = "Send an alert when Penyta dies", Default = false })
    G:AddToggle("WebhookOnCandy", { Text = "Send a candy milestone alert", Default = false })
    G:AddSlider("CandyMilestone", { Text = "Milestone step", Default = DEF.CandyMilestone, Min = 100, Max = 5000, Rounding = 0 })
    webhookLabel = G:AddLabel("", true)
    G:AddButton({
        Text = "Send test message",
        Func = function()
            task.spawn(function()
                local ok, err = sendWebhook("Test message", "If you can see this, the webhook works.", 3447003)
                if webhookLabel then
                    webhookLabel:SetText(ok and "Test sent" or ("Failed: " .. tostring(err)))
                end
            end)
        end,
    })
end)

try(function()
    local G = TabWebhooks:AddRightGroupbox("About")
    G:AddLabel("Get a webhook URL from your Discord server: Channel Settings > Integrations > Webhooks > New Webhook > Copy URL.", true)
    G:AddLabel("The \"Killed by\" field is best-effort. If the game doesn't expose who damaged an NPC, it will show as Unknown - that's a limit of what TSB shares with the client, not a bug in this script.", true)
end)

-- Names (folded into the Settings tab, no separate tab for this anymore)
try(function()
    local G = TabNames:AddLeftGroupbox("Names (comma separated)")
    G:AddInput("PromptKeys", { Text = "Prompt to press", Default = DEF.PromptKeys })
    G:AddInput("DoorKeys", { Text = "Door name (empty = no filter)", Default = DEF.DoorKeys })
    G:AddInput("TrashKeys", { Text = "Trashcan name", Default = DEF.TrashKeys })
    G:AddInput("NpcKeys", { Text = "NPC name to kill", Default = DEF.NpcKeys })
    G:AddInput("PinataKeys", { Text = "Penyta name", Default = DEF.PinataKeys })
    G:AddInput("BossKeys", { Text = "Boss name", Default = DEF.BossKeys })
    G:AddInput("ExcludeKeys", { Text = "Exclude from ESP/kill", Default = DEF.ExcludeKeys })
    G:AddToggle("TrashHit", { Text = "Hit trashcan (M1) if it has no prompt", Default = true })
end)

try(function()
    local G = TabNames:AddRightGroupbox("Candy / Shop names")
    G:AddInput("CandyFolder", { Text = "Candy folder (empty = Workspace)", Default = DEF.CandyFolder })
    G:AddInput("CandyNames", { Text = "Candy names", Default = DEF.CandyNames })
    G:AddInput("ShopKeys", { Text = "Shopkeeper name", Default = DEF.ShopKeys })
    G:AddInput("RerollKeys", { Text = "Re-roll button text", Default = DEF.RerollKeys })
    G:AddInput("CandyCountPath", { Text = "Candy count path (optional)", Default = "", Placeholder = "e.g. leaderstats.Candy" })
    G:AddButton({ Text = "Scan to console", Func = function() task.spawn(scanConsole) end })
end)

-- Testers
try(function()
    local G = TabTesters:AddLeftGroupbox("Testers")
    G:AddLabel("Grim_Reaper - Tester", true)
    G:AddLabel("notagoodhackayt - Tester", true)
end)

-- Settings
local GMenu = nil
try(function()
    GMenu = TabSettings:AddLeftGroupbox("Menu")
    try(function()
        GMenu:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
    end)
    GMenu:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
end)

try(function()
    local G = TabSettings:AddRightGroupbox("Credits")
    G:AddLabel("Owner: lo6 | selam0exe", true)
    G:AddLabel("Discord: godvillage.", true)
    G:AddLabel("Server: discord.gg/PDyTWAEkPt", true)
    G:AddButton({
        Text = "Copy Discord link",
        Func = function()
            local clip = setclipboard or toclipboard
            if clip then
                pcall(clip, DISCORD_URL)
                notify("Discord link copied", 3)
            else
                notify(DISCORD_URL, 8)
            end
        end,
    })
end)

try(function()
    if Options.MenuKeybind then
        Library.ToggleKeybind = Options.MenuKeybind
    end
end)

local hasFiles = isfolder and makefolder and writefile and readfile and listfiles
if SaveManager and ThemeManager and hasFiles then
    local okCfg, errCfg = pcall(function()
        ThemeManager:SetLibrary(Library)
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
        ThemeManager:SetFolder("TSBHalloween")
        SaveManager:SetFolder("TSBHalloween/configs")
        SaveManager:BuildConfigSection(TabSettings)
        ThemeManager:ApplyToTab(TabSettings)
        SaveManager:LoadAutoloadConfig()
    end)
    if not okCfg then
        warn("[TSB] Config/theme setup failed: " .. tostring(errCfg))
        if GMenu then pcall(function() GMenu:AddLabel("Config system failed to load in this executor.", true) end) end
    end
else
    if GMenu then pcall(function() GMenu:AddLabel("Config system is not supported by this executor.", true) end) end
end
print("[TSB] UI built")

pcall(refreshKeys)

pcall(function()
    Library:OnUnload(function()
        alive = false
        learning = nil
        for _, c in ipairs(conns) do
            pcall(function() c:Disconnect() end)
        end
        pcall(resetVisibility)
        pcall(setInvisOthers, false)
        pcall(F.cleanup)
        pcall(clearAllEsp)
        pcall(function() espFolder:Destroy() end)
    end)
end)

-- ========== steps ==========
local function stepKill()
    if not T("AutoKill") then return false end
    local hrp = getHRP()
    if not hrp then return false end
    local m = nearestTarget(hrp)
    if not m then return false end
    ensureOrigin(hrp)
    local isP = npcSet[m] == true
    local hum = m:FindFirstChildOfClass("Humanoid")
    local limit = hum and (isP and 35 or 12) or 8
    local t0 = os.clock()
    local lastPos = nil
    local killed = false
    weAreAttacking[m] = true
    while alive and T("AutoKill") and m.Parent and os.clock() - t0 < limit do
        local root = rootOf(m)
        local me = getHRP()
        if not root or not me then break end
        local cur = healthOf(m, hum)
        if cur and cur <= 0 then
            killed = true
            break
        end
        lastPos = root.Position
        if isP then addSpot(lastPos) end
        local behind = (root.CFrame * CFrame.new(0, 0, O("KillDist"))).Position
        if safePos(behind) then
            local cf = CFrame.lookAt(behind, root.Position)
            if (me.Position - behind).Magnitude > 12 then
                moveTo(cf)
            else
                me.CFrame = cf
                me.AssemblyLinearVelocity = Vector3.zero
            end
        end
        useSkills()
        stepUlt()
        attackClick()
        task.wait(O("AttackDelay"))
    end
    if not m.Parent then
        killed = true
    end
    task.delay(2, function() weAreAttacking[m] = nil end) -- keep the flag briefly for the Died event
    if killed then
        if lastPos then addSpot(lastPos) end
    elseif m.Parent then
        killBan[m] = os.clock() + ((isP and not hum) and 60 or 20) -- could not kill it, skip for a while
    end
    return true
end

local function stepShop()
    if not T("AutoReroll") then return false end
    if os.clock() - lastShop < 12 then return false end
    local count = getCandyCount()
    if not count or count < O("RerollCost") then return false end
    lastShop = os.clock()
    ensureOrigin(getHRP())
    doReroll()
    return true
end

local function stepCandy()
    if not T("AutoCandy") then return false end
    local hrp = getHRP()
    if not hrp then return false end
    local now = os.clock()
    local bestI, bestD = nil, nil
    for i = #candyQueue, 1, -1 do
        local item = candyQueue[i]
        local inst = item.inst
        local pos = inst and inst.Parent and posOf(inst) or nil
        if not pos or now - item.t > 60 or not candyVisible(inst) or not safePos(pos)
            or (pos - item.pos).Magnitude > 120 then
            table.remove(candyQueue, i)
        else
            local d = (pos - hrp.Position).Magnitude
            if not bestD or d < bestD then
                bestI, bestD = i, d
            end
        end
    end
    if not bestI then return false end
    local item = table.remove(candyQueue, bestI)
    ensureOrigin(hrp)
    collectCandy(item.inst, hrp)
    task.wait(O("CandyDelay"))
    return true
end

local function stepDoor()
    if not T("AutoDoors") then return false end
    if T("AutoKill") and pinataAlive() then return false end -- Penyta first, ignore doors
    refreshDoors()
    for _, p in ipairs(doorList) do
        if p.Parent and p.Enabled and (os.clock() - (doorCooldown[p] or -100)) > 15 then
            local pos = posOf(p.Parent)
            local hrp = getHRP()
            if pos and hrp and safePos(pos) then
                doorCooldown[p] = os.clock()
                ensureOrigin(hrp)
                addSpot(pos)
                -- stand off to the side of the door (away from its facing) instead of
                -- right on top of it, and briefly drop collision: both stop the camera
                -- from getting pushed/clipped by nearby tree geometry
                local target, part = doorInfo(p)
                local standCf = CFrame.new(pos + Vector3.new(0, O("DoorYOffset"), 0))
                if part then
                    local fwd = part.CFrame.LookVector
                    if fwd.Magnitude > 0.1 then
                        standCf = CFrame.new(part.Position + fwd * O("DoorForwardOffset") + Vector3.new(0, O("DoorYOffset"), 0))
                    end
                end
                local wasCollide = hrp.CanCollide
                pcall(function() hrp.CanCollide = false end)
                moveTo(standCf)
                task.wait(O("StepDelay"))
                for _ = 1, 2 do
                    if T("AutoKill") and pinataAlive() then break end
                    holdPrompt(p)
                    task.wait(O("StepDelay"))
                    if not (p.Parent and p.Enabled) then break end
                end
                local h2 = getHRP()
                if h2 then pcall(function() h2.CanCollide = wasCollide end) end
                addSpot(pos)
                return true
            end
        end
    end
    return false
end

local function stepTrash()
    if not T("AutoTrash") then return false end
    if T("AutoKill") and pinataAlive() then return false end
    refreshTrash()
    for _, inst in ipairs(trashList) do
        if inst.Parent and (os.clock() - (trashDone[inst] or -1000)) > TRASH_COOLDOWN then
            local pos = posOf(inst)
            local hrp = getHRP()
            if pos and hrp and safePos(pos) then
                trashDone[inst] = os.clock()
                ensureOrigin(hrp)
                addSpot(pos)
                moveTo(CFrame.lookAt(pos + Vector3.new(0, 1, 3), pos))
                task.wait(O("StepDelay"))
                local fired = false
                for _, p in ipairs(inst:GetDescendants()) do
                    if p:IsA("ProximityPrompt") and p.Enabled then
                        holdPrompt(p)
                        fired = true
                    end
                end
                if not fired and T("TrashHit") then
                    for _ = 1, 3 do
                        attackClick()
                        task.wait(0.15)
                    end
                end
                task.wait(O("StepDelay"))
                addSpot(pos)
                return true
            end
        end
    end
    return false
end

-- ========== events ==========
track(Workspace.DescendantAdded:Connect(function(d)
    local cls = d.ClassName
    if cls == "Humanoid" then
        task.defer(function()
            task.wait(0.2)
            if d.Parent then
                pcall(registerNpc, d.Parent, false)
            end
        end)
    elseif cls == "Model" and #K.pinata > 0 and hasKeyword(d.Name, K.pinata) then
        task.defer(function()
            task.wait(0.2)
            if d.Parent then
                pcall(registerNpc, d, false)
            end
        end)
    end
end))

task.spawn(function()
    local n = 0
    for _, d in ipairs(Workspace:GetDescendants()) do
        n += 1
        if n % 3000 == 0 then task.wait() end
        if d.ClassName == "Humanoid" and d.Parent then
            pcall(registerNpc, d.Parent, true)
        elseif d.ClassName == "Model" and #K.pinata > 0 and hasKeyword(d.Name, K.pinata) then
            pcall(registerNpc, d, true)
        end
    end
end)

track(RunService.RenderStepped:Connect(function()
    if not T("InvisLocal") then return end
    local c = lp.Character
    if not c then return end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("BasePart") then
            d.LocalTransparencyModifier = 1
        end
    end
end))

track(RunService.Heartbeat:Connect(function()
    pcall(F.playerTick)
    pcall(stepUlt)
end))

track(RunService.Stepped:Connect(function()
    if T("NoclipOn") then
        pcall(F.noclipStep)
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if T("InfJump") then
        local hum = getHum()
        if hum then
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
        end
    end
end))

track(lp.Idled:Connect(function()
    if T("AntiAFK") and VU then
        pcall(function()
            VU:CaptureController()
            VU:ClickButton2(Vector2.new())
        end)
    end
end))

track(lp.CharacterAdded:Connect(function()
    if invisSeat then
        invisSeat:Destroy()
        invisSeat = nil
    end
    local t = Toggles.InvisOthers
    if t and t.Value then
        pcall(function() t:SetValue(false) end)
    end
    origin = nil
end))

local function refreshTP()
    local names = F.playerNames()
    if #names == 0 then names = { "-" } end
    pcall(function() Options.TPTarget:SetValues(names) end)
end
track(Players.PlayerAdded:Connect(function() task.delay(1, refreshTP) end))
track(Players.PlayerRemoving:Connect(function() task.delay(1, refreshTP) end))

-- ========== background loops ==========
task.spawn(function()
    while alive do
        pcall(updateDoorEsp)
        pcall(updateNpcEsp)
        pcall(updatePlayerEsp)
        task.wait(0.2)
    end
end)

task.spawn(function()
    while alive do
        local interval = 0.3
        if T("AutoCandy") then
            local ok, err = pcall(pollCandy)
            if not ok then warn("[TSB] Candy watcher error: " .. tostring(err)) end
            local _, inFolder = candyRoot()
            if not inFolder then interval = 2 end
        end
        task.wait(interval)
    end
end)

task.spawn(function()
    while alive do
        pcall(function()
            local c, src = getCandyCount()
            if candyLabel then
                if c then
                    candyLabel:SetText("Candy: " .. fmtNum(c) .. " (" .. src .. ")")
                else
                    candyLabel:SetText("Candy: not found (set the path in Settings)")
                end
            end
            if c and T("WebhookOnCandy") then
                local step = O("CandyMilestone")
                if step > 0 then
                    local reached = math.floor(c / step) * step
                    if reached > 0 and reached > lastCandyMilestoneSent then
                        lastCandyMilestoneSent = reached
                        task.spawn(function()
                            sendWebhook("Candy milestone", lp.Name .. " reached " .. fmtNum(reached) .. " candy.", 15844367)
                        end)
                    end
                end
            end
        end)
        if T("Fullbright") then
            pcall(F.fullbrightApply)
        end
        task.wait(1)
    end
end)

-- ========== main loop ==========
task.spawn(function()
    local lastKeys = 0
    while alive do
        if os.clock() - lastKeys > 1 then
            lastKeys = os.clock()
            pcall(refreshKeys)
        end
        local ok, worked = pcall(function()
            return stepKill() or stepShop() or stepCandy() or stepDoor() or stepTrash()
        end)
        if not ok then
            warn("[TSB] Auto Farm error: " .. tostring(worked))
            worked = false
            task.wait(1)
        end
        if worked then
            task.wait(0.05)
        else
            if origin and T("ReturnOrigin") and getHRP() then
                moveTo(origin)
            end
            origin = nil
            task.wait(0.3)
        end
    end
end)

notify("Loaded v6.0. First: Main > Kill > Learn M1 / Skills > Learn skill / Ultimate > Learn ultimate.", 6)
print("[TSB] Loaded OK")

end

local __ok, __err = xpcall(__tsbMain, debug.traceback)
if not __ok then
    warn("[TSB] Script error:\n" .. tostring(__err))
end
