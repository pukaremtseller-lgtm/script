-- Autoparry v8 (Blade Ball): реальный хитбок - расстояние до поверхности
-- Одно правило: парри, когда мяч окажется рядом в ближайшие lead секунд.
-- Режимы (прямой/кривой), проекция траектории и ожидание нужны только для того,
-- чтобы точнее предсказать это "рядом" и не нажать зря. Рядом = нажимаем всегда.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Stats = game:GetService("Stats")
local VIM = game:GetService("VirtualInputManager")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Balls = workspace:WaitForChild("Balls")

local CFG = {
    Enabled = true,
    ToggleKey = Enum.KeyCode.T,

    ReachGap = 5,          -- "рядом" = зазор между поверхностями (студы); растёт со скоростью
    ReactionBuffer = 0.03, -- запас сверх пинга, сек
    EarlyTime = 0.03,      -- насколько раньше нажимать, сек (главная ручка)
    Retry = 0.25,          -- повтор, если мяч всё ещё вплотную, сек

    StraightAngle = 12,    -- град: мяч "прямой", если угол меньше
    StraightRate = 40,     -- град/сек: и угол почти не меняется
    Horizon = 0.8,         -- проекция кривой вперёд, сек
    CurveSettle = 0.25,    -- сек после чужого удара, когда траектория неточна

    ShowSphere = true,
    ShowHighlight = true,
    ShowHUD = true,
}

local COL_IDLE = Color3.fromRGB(72, 220, 145)
local COL_ALERT = Color3.fromRGB(255, 72, 92)
local COL_FLASH = Color3.fromRGB(255, 255, 255)

-- ========== ПИНГ ==========
local ping_s = 0.05
local function update_ping()
    local raw = Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    ping_s = ping_s + (raw - ping_s) * 0.2
end

-- ========== БЛОК-СОСТОЯНИЯ ==========
local blocked = { infinity = false, death = false }
RS.Remotes.InfinityBall.OnClientEvent:Connect(function(_, v) blocked.infinity = v or false end)
RS.Remotes.DeathBall.OnClientEvent:Connect(function(_, v) blocked.death = v or false end)

-- чужой удар далеко от нас: мяч только что сменил траекторию
local last_curve = tick()
RS.Remotes.ParrySuccessAll.OnClientEvent:Connect(function(_, hitter)
    local me = LP.Character and LP.Character.PrimaryPart
    if not me or hitter == me then return end
    for _, b in ipairs(Balls:GetChildren()) do
        if b:GetAttribute("realBall") then
            local z = b:FindFirstChild("zoomies")
            if z and (me.Position - b.Position).Magnitude
                > 15 + math.min(z.VectorVelocity.Magnitude / 100, 40) then
                last_curve = tick()
            end
        end
    end
end)

-- ========== ПРОЕКЦИЯ ТРАЕКТОРИИ ==========
-- Ускорение (поворот мяча) затухает к концу CFG.Horizon.
local function advance(pos, vel, a, t, k)
    vel = vel + a * math.max(0, 1 - t / CFG.Horizon) * k
    return pos + vel * k, vel
end

-- Минимальное расстояние до нас на отрезке [0, span] вдоль проекции.
-- Для прямого мяча a = 0 (обычный линейный пролёт).
local function min_distance(rel, vr, a, span)
    local pos, vel = rel, vr
    local dmin, t, step = pos.Magnitude, 0, 0.01
    while t < span do
        local k = math.min(step, span - t)
        pos, vel = advance(pos, vel, a, t, k)
        t += k
        local d = pos.Magnitude
        if d < dmin then dmin = d end
    end
    return dmin
end

-- Время до входа в радиус R (для HUD и оценки), nil если не войдёт.
local function time_to_enter(rel, vr, a, R, horizon)
    if rel.Magnitude <= R then return 0 end
    local pos, vel, t, step = rel, vr, 0, 0.01
    while t < horizon do
        pos, vel = advance(pos, vel, a, t, step)
        t += step
        if pos.Magnitude <= R then return t end
    end
    return nil
end

-- состояние по мячу: скорость, ускорение, угол, скорость изменения угла
local states = setmetatable({}, { __mode = "k" })

-- ========== РЕАЛЬНЫЙ ХИТБОКС ==========
local ext_cache, ext_time, ext_char = Vector3.new(4, 5, 2), 0, nil

local function body_extents(char)
    local now = tick()
    if char ~= ext_char or now - ext_time > 0.5 then
        local ok, size = pcall(function() return char:GetExtentsSize() end)
        if ok and size then ext_cache = size end
        ext_char, ext_time = char, now
    end
    return ext_cache
end

-- Расстояние от центра корня до поверхности тела вдоль направления dir
-- (единичный вектор в мировых координатах): выход луча из бокса персонажа.
local function body_radius(char, root, dir)
    local e = body_extents(char)
    local u = root.CFrame:VectorToObjectSpace(dir)
    local ax, ay, az = math.abs(u.X), math.abs(u.Y), math.abs(u.Z)
    local t = math.huge
    if ax > 1e-4 then t = math.min(t, e.X / 2 / ax) end
    if ay > 1e-4 then t = math.min(t, e.Y / 2 / ay) end
    if az > 1e-4 then t = math.min(t, e.Z / 2 / az) end
    return math.min(t, math.max(e.X, e.Y, e.Z))
end

local function ball_radius(ball)
    local s = ball.Size
    return math.min(math.max(s.X, s.Y, s.Z) / 2, 8)
end

-- ========== ВИЗУАЛ ==========
local sphere = Instance.new("Part")
sphere.Shape = Enum.PartType.Ball
sphere.Anchored, sphere.CanCollide, sphere.CanQuery, sphere.CanTouch = true, false, false, false
sphere.Material = Enum.Material.Neon
sphere.Transparency = 0.9
sphere.Color = COL_IDLE
sphere.Size = Vector3.one * 20

local highlight = Instance.new("Highlight")
highlight.FillColor = COL_ALERT
highlight.OutlineColor = COL_FLASH
highlight.FillTransparency = 0.5
highlight.Enabled = false

local gui_parent = (gethui and gethui()) or game:GetService("CoreGui")
local old = gui_parent:FindFirstChild("_autoparry_hud")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "_autoparry_hud"
gui.ResetOnSpawn = false
gui.Parent = gui_parent

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(210, 140)
frame.Position = UDim2.new(0, 12, 0.4, 0)
frame.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
frame.BackgroundTransparency = 0.15
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = COL_IDLE
stroke.Thickness = 1.5

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, -16, 1, -12)
label.Position = UDim2.fromOffset(8, 6)
label.BackgroundTransparency = 1
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.GothamSemibold
label.TextSize = 13
label.TextColor3 = Color3.fromRGB(235, 235, 240)
label.Parent = frame

local parry_count, flash_until = 0, 0
local info = { speed = 0, dist = 0, angle = 0, mode = "-", tc = nil, trigger = 20, wait = false, off = 0 }

local function update_visuals(root, alert)
    local flashing = tick() < flash_until
    local color = flashing and COL_FLASH or (alert and COL_ALERT or COL_IDLE)

    if CFG.ShowSphere and CFG.Enabled and root then
        sphere.Parent = workspace
        sphere.Size = Vector3.one * math.max(info.trigger * 2, 4)
        sphere.CFrame = root.CFrame
        sphere.Color = color
        sphere.Transparency = flashing and 0.6 or 0.9
    else
        sphere.Parent = nil
    end

    frame.Visible = CFG.ShowHUD
    stroke.Color = CFG.Enabled and color or Color3.fromRGB(110, 110, 120)
    label.Text = string.format(
        "AUTOPARRY: %s  [%s]\nPing: %d ms\nBall speed: %d\nAngle: %d°  (%s%s)\nGap: %d  (fires at %d)\nContact in: %s\nParries: %d",
        CFG.Enabled and "ON" or "OFF", CFG.ToggleKey.Name,
        math.floor(ping_s * 1000), math.floor(info.speed),
        math.floor(info.angle), info.mode, info.wait and ", wait" or "",
        math.floor(info.dist - info.off), math.floor(info.trigger - info.off),
        info.tc and string.format("%.2fs", info.tc) or "-", parry_count)
end

UIS.InputBegan:Connect(function(input, gp)
    if not gp and input.KeyCode == CFG.ToggleKey then
        CFG.Enabled = not CFG.Enabled
    end
end)

-- ========== ПАРРИ ==========
local last_press = 0
local parried = {}

local function press()
    VIM:SendKeyEvent(true, Enum.KeyCode.F, false, game)
    VIM:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    last_press = tick()
    parry_count += 1
    flash_until = tick() + 0.25
end

local function step()
    local char = LP.Character
    local root = char and char.PrimaryPart
    update_ping()

    local alert = false
    info.speed, info.dist, info.angle, info.mode, info.tc, info.wait, info.off = 0, 0, 0, "-", nil, false, 0

    if root then
        for _, ball in ipairs(Balls:GetChildren()) do
            if not ball:GetAttribute("realBall") then continue end
            local z = ball:FindFirstChild("zoomies")
            if not z then continue end

            if ball:GetAttribute("target") ~= LP.Name then
                parried[ball] = nil
                states[ball] = nil
                if highlight.Parent == ball then highlight.Enabled = false end
                continue
            end

            alert = true
            if CFG.ShowHighlight then
                highlight.Parent = ball
                highlight.Enabled = true
            end

            -- геометрия
            local rel = ball.Position - root.Position
            local dist = rel.Magnitude
            local vr = z.VectorVelocity - root.AssemblyLinearVelocity
            local speed = vr.Magnitude
            info.speed, info.dist = speed, dist
            if dist < 0.01 or speed < 1 then break end

            local closing = -rel:Dot(vr) / dist
            local cosang = math.clamp(-rel:Dot(vr) / (dist * speed), -1, 1)
            local angle = math.deg(math.acos(cosang))
            info.angle = angle

            -- оценка ускорения и скорости изменения угла
            local now = tick()
            local s = states[ball]
            if not s then
                s = { v = vr, t = now, a = Vector3.zero, ang = angle, rate = 0 }
                states[ball] = s
            end
            local dt = now - s.t
            if dt > 0.001 then
                local a_new = (vr - s.v) / dt
                if a_new.Magnitude > 3000 then a_new = a_new.Unit * 3000 end
                s.a = s.a:Lerp(a_new, 0.3)
                s.rate = s.rate + (((angle - s.ang) / dt) - s.rate) * 0.3
                s.v, s.t, s.ang = vr, now, angle
            end

            -- режим полёта
            local straight = angle < CFG.StraightAngle and math.abs(s.rate) < CFG.StraightRate
            info.mode = straight and "STRAIGHT" or "CURVED"
            local a = straight and Vector3.zero or s.a

            -- единое правило: "рядом" = окажемся в радиусе R за время lead
            -- смещение центр-центр до касания поверхностей: радиус мяча + радиус
            -- тела персонажа вдоль линии к мячу. R = центр-центр, при котором
            -- зазор между поверхностями равен ReachGap (плюс запас на скорость).
            local off = ball_radius(ball) + body_radius(char, root, rel / dist)
            info.off = off
            local R = off + CFG.ReachGap + math.min(speed * 0.02, 12)
            -- прямой: полный запас раньше; кривой: запас вдвое меньше,
            -- т.к. проекция менее надёжна, и ранний выстрел чаще пролетает мимо
            local lead = ping_s + CFG.ReactionBuffer
                + CFG.EarlyTime * (straight and 1 or 0.5)
            info.trigger = R + math.max(closing, 0) * lead

            if closing <= 1 then info.mode = "away" break end

            info.tc = straight and (math.max(dist - R, 0) / closing)
                or time_to_enter(rel, vr, s.a, R, CFG.Horizon)

            local d_min = min_distance(rel, vr, a, lead)
            local near = d_min <= R

            -- ожидание: траектория только что изменилась, а мяч ещё далеко.
            -- Если мяч уже близко (<= 1.5R), ожидание отключается.
            local waiting = (not straight)
                and (now - last_curve) < CFG.CurveSettle
                and dist > R * 1.5
            info.wait = waiting

            -- последний шанс: мяч вплотную, нажимаем в любом случае
            local emergency = dist <= R * 1.2
            local should = emergency or (near and not waiting)

            local first = not parried[ball]
            local retry = (not first) and now - last_press >= CFG.Retry and dist <= R

            if CFG.Enabled and should and (first or retry)
                and not ball:FindFirstChild("ComboCounter")
                and not blocked.infinity and not blocked.death
                and now - last_press >= 0.05 then
                press()
                parried[ball] = true
            end
            break
        end
    end

    if not alert then highlight.Enabled = false end
    update_visuals(root, alert)
end

RunService.PreSimulation:Connect(step)
