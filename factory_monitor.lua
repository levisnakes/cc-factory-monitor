-- Factory Monitor: live dashboard for a Create Factory Controller.
-- Reads every gauge on the controller, draws a statistics dashboard on a
-- monitor (full color with a DirectGPU block, plain text without), and shares
-- the gauge data over rednet so the Mech Crafter computer knows what to make.
-- With a Stock Ticker on the network it also runs the crafty turtles (crafter.lua from
-- cc-craft-dispatch): for every Passive gauge that is short and has a learned recipe it orders the
-- ingredients for up to BATCH crafts to a free turtle's own address and tells it the recipe.

MONITOR = nil         -- nil = the biggest monitor attached
CONTROLLER = nil      -- nil = find the Factory Controller
TITLE = "FACTORY"
PAGE_SECONDS = 8      -- how long each page of gauges stays up
RESOLUTION = nil      -- DirectGPU sharpness 1-4; nil = pick one to fit the monitor
DISCORD_WEBHOOK = nil -- Discord webhook URL (in quotes) for "stuck" alerts
DISCORD_MENTION = nil -- who to ping when something is stuck, e.g. "<@&ROLE_ID>"
DISPATCH = true       -- run the crafty turtles when a Stock Ticker is on the network
BATCH = 64            -- most crafts ordered for one turtle at a time
ORDER_TIMEOUT_MINUTES = 10  -- forget a turtle order that never finished after this long
AUTO_UPDATE = true        -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
do
  local path = "/config.lua"
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError("config.lua: " .. tostring(runErr)) sleep(3) end
    else
      printError("config.lua: " .. tostring(err))
      sleep(3)
    end
  end
end


-- ============================================================ basics

local function now() return os.epoch("utc") / 1000 end

-- turtle crafting (filled in by the dispatcher block further down)
local dispatch = { active = false, flying = {}, stations = {}, recipes = {}, jobs = {}, lines = {} }

local function pretty(id)
  if not id or id == "" then return "Empty" end
  local name = id:gsub("^[^:]+:", ""):gsub("_", " ")
  return (name:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

local function fmtNum(n)
  n = math.floor(n or 0)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

local function clockText()
  return os.date and os.date("%H:%M") or textutils.formatTime(os.time(), true)
end

-- ============================================================ data

local data = {
  ok = false, err = nil, name = "", paused = false,
  gauges = {}, missing = 0, at = 0,
}
local crafter = { at = 0, msg = nil }
local history = {}          -- { t, ok, total } every 30s, last hour
local feed = {}             -- recent gauge state changes
local lastState = {}

local function controllerName()
  if CONTROLLER then return CONTROLLER end
  local c = peripheral.find("factory_controller")
  return c and peripheral.getName(c)
end

local function unitMult(g)
  if g.unit == "STACKS" then return 64 end
  return 1
end

-- Severity: 1 waiting for network, 2 short, 3 in transit, 4 paused, 5 ok.
-- Returns a label and a shorter one for tight spaces.
local function classify(g)
  if g.paused or data.paused then return 4, "Paused", "Paused" end
  if g.satisfied then return 5, "Stocked", "OK" end
  if g.promised > 0 then
    return 3, "+" .. fmtNum(g.promised) .. " coming", "+" .. fmtNum(g.promised)
  end
  if g.waiting then return 1, "No inputs", "No inputs" end
  local short = fmtNum(math.max(0, g.targetItems - g.stock))
  return 2, "Short " .. short, "-" .. short
end

local function pushFeed(text, sev)
  table.insert(feed, 1, { t = clockText(), text = text, sev = sev })
  while #feed > 6 do table.remove(feed) end
end

local function crafterFresh()
  return crafter.msg and now() - crafter.at < 10
end

-- Ingredients the crafter is stuck waiting for: { recipe, item, have, need }.
local function crafterBlocked()
  local out = {}
  if not crafterFresh() then return out end
  for _, r in ipairs(crafter.msg.recipes or {}) do
    for _, m in ipairs(r.missing or {}) do
      table.insert(out, { recipe = r.name, item = m.item, have = m.have, need = m.need })
    end
  end
  return out
end

local function neededSet()
  local set = {}
  for _, b in ipairs(crafterBlocked()) do set[b.item] = true end
  return set
end

-- Trace why the network is short of an item, from the gauge that makes it.
-- Returns text and a severity for coloring.
local function supplyState(item)
  local best
  for _, g in ipairs(data.gauges) do
    if g.item == item and (not best or g.sev < best.sev) then best = g end
  end
  if not best then return "no gauge makes it", 1 end
  if best.paused or data.paused then return "its gauge is paused", 1 end
  if best.promised > 0 then return "+" .. fmtNum(best.promised) .. " on the way", 3 end
  if best.waiting then return "its gauge is waiting for inputs", 1 end
  if best.satisfied then return "gauge target is too low", 2 end
  return "gauge is short, ordering soon", 2
end

local function readController()
  local name = controllerName()
  if not name or not peripheral.isPresent(name) then
    data.ok, data.err = false, "No Factory Controller found"
    return
  end
  local okI, info = pcall(peripheral.call, name, "getInfo")
  local okG, gauges = pcall(peripheral.call, name, "getGauges")
  local okM, missing = pcall(peripheral.call, name, "getMissingLinks")
  if not okG or type(gauges) ~= "table" then
    data.ok, data.err = false, "Can't read gauges: " .. tostring(gauges)
    return
  end

  data.paused = okI and type(info) == "table" and info.redstonePowered == true
  local list = {}
  for _, g in ipairs(gauges) do
    if g.item and g.item ~= "" and g.item ~= "minecraft:air" then
      local e = {
        id = g.gaugeId, item = g.item, target = g.count or 0, unit = g.unit,
        stock = g.stock or 0, promised = g.promised or 0,
        satisfied = g.satisfied == true, waiting = g.waitingForNetwork == true,
        paused = g.redstonePowered == true, address = g.address or "",
        -- safe to craft for: Passive, or no address (a gauge without one can't order anything itself)
        passive = g.requestMode ~= "NORMAL" or (g.address or "") == "",
      }
      e.promised = e.promised + (dispatch.flying[g.item] or 0)
      e.targetItems = e.target * unitMult(e)
      e.fluid = g.unit == "FLUID_MB" or g.unit == "FLUID_BUCKET"
      e.sev, e.label, e.shortLabel = classify(e)
      table.insert(list, e)

      local key = e.id or e.item
      local prev = lastState[key]
      if prev and prev ~= e.sev then
        if e.sev == 5 then pushFeed(pretty(e.item) .. " restocked", 5)
        elseif e.sev == 1 then pushFeed(pretty(e.item) .. " waiting for ingredients", 1)
        elseif e.sev == 3 and prev ~= 3 then pushFeed(pretty(e.item) .. " being made", 3)
        elseif e.sev == 2 and prev == 5 then pushFeed(pretty(e.item) .. " ran low", 2) end
      end
      lastState[key] = e.sev
    end
  end
  local needed = neededSet()
  table.sort(list, function(a, b)
    local na, nb = needed[a.item] and 0 or 1, needed[b.item] and 0 or 1
    if na ~= nb then return na < nb end
    if a.sev ~= b.sev then return a.sev < b.sev end
    local da, db = a.targetItems - a.stock, b.targetItems - b.stock
    if da ~= db then return da > db end
    return pretty(a.item) < pretty(b.item)
  end)

  data.ok, data.err = true, nil
  data.name = (okI and type(info) == "table" and info.name) or ""
  data.gauges = list
  data.missing = (okM and type(missing) == "table") and #missing or 0
  data.at = now()

  local t = now()
  if #history == 0 or t - history[#history].t >= 30 then
    local okCount = 0
    for _, g in ipairs(list) do if g.sev == 5 then okCount = okCount + 1 end end
    table.insert(history, { t = t, ok = okCount, total = #list })
    while #history > 120 do table.remove(history, 1) end
  end
end

local function stats()
  local s = { total = #data.gauges, ok = 0, short = 0, transit = 0, promised = 0, waiting = 0 }
  for _, g in ipairs(data.gauges) do
    if g.sev == 5 then s.ok = s.ok + 1 end
    if g.sev == 1 or g.sev == 2 then s.short = s.short + 1 end
    if g.sev == 1 then s.waiting = s.waiting + 1 end
    if g.promised > 0 then s.transit = s.transit + 1 end
    s.promised = s.promised + g.promised
  end
  return s
end

local function crafterRecipeFor(item)
  if not crafterFresh() then return nil end
  for _, r in ipairs(crafter.msg.recipes or {}) do
    if r.output == item then return r end
  end
end

-- ============================================================ network

local function openModems()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.hasType(side, "modem") and not rednet.isOpen(side) then
      rednet.open(side)
    end
  end
end

local function broadcastGauges()
  local out = {}
  for _, g in ipairs(data.gauges) do
    table.insert(out, {
      item = g.item, target = g.target, unit = g.unit, stock = g.stock,
      promised = g.promised, satisfied = g.satisfied, paused = g.paused,
      waiting = g.waiting, address = g.address,
    })
  end
  pcall(rednet.broadcast, { kind = "gauges", t = now(), paused = data.paused, gauges = out }, "cfm-gauges")
end

local function dataLoop()
  openModems()
  while true do
    local ok, err = pcall(readController)
    if not ok then data.ok, data.err = false, tostring(err) end
    if data.ok then broadcastGauges() end
    sleep(2)
  end
end

local function netLoop()
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" and ev[4] == "cfm-crafter" and type(ev[3]) == "table" then
      crafter.msg = ev[3]
      crafter.at = now()
    elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
      openModems()
    end
  end
end

-- ============================================================ turtle crafting (dispatcher)

local dispatchLoop
do
  local PROTOCOL = "craft-dispatch"
  local DIR = "/dispatch"
  if not fs.exists(DIR) then fs.makeDir(DIR) end

  local function load(path, default)
    if not fs.exists(path) then return default end
    local f = fs.open(path, "r")
    local v = textutils.unserialize(f.readAll())
    f.close()
    return v == nil and default or v
  end
  local function save(path, v)
    local f = fs.open(path .. ".tmp", "w")
    f.write(textutils.serialize(v))
    f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(path .. ".tmp", path)
  end

  dispatch.recipes = load(DIR .. "/recipes", {})  -- [output] = { grid = {9}, outCount }
  dispatch.jobs = load(DIR .. "/jobs", {})         -- [id] = { id, station, out, crafts, outCount, t }
  local nextJob = load(DIR .. "/next", 1)
  local recent = {}                                -- finished results not yet in the gauge's stock
  local lastStock = {}
  local ticker

  local function saveJobs() save(DIR .. "/jobs", dispatch.jobs) save(DIR .. "/next", nextJob) end
  local function note(text, sev)
    table.insert(dispatch.lines, 1, os.date("!%H:%M ") .. text)
    while #dispatch.lines > 30 do table.remove(dispatch.lines) end
    pushFeed(text, sev or 3)
  end
  local function send(msg) pcall(rednet.broadcast, msg, PROTOCOL) end
  local function perCraft(grid)
    local need = {}
    for i = 1, 9 do if grid[i] then need[grid[i]] = (need[grid[i]] or 0) + 1 end end
    return need
  end

  local function inFlight(out)
    local n = 0
    for _, j in pairs(dispatch.jobs) do if j.out == out then n = n + j.crafts * (j.outCount or 1) end end
    for _, r in ipairs(recent) do
      if r.out == out then n = n + math.max(0, r.count - math.max(0, (lastStock[out] or 0) - r.stockAt)) end
    end
    return n
  end

  local function freeStation()
    local best
    for id, st in pairs(dispatch.stations) do
      if st.free and not st.assigned and now() - st.t < 8 and (not best or id < best) then best = id end
    end
    return best
  end

  local function order(out, crafts, station, stock)
    local r, st = dispatch.recipes[out], dispatch.stations[station]
    local filters = {}
    for name, per in pairs(perCraft(r.grid)) do
      table.insert(filters, { name = name, _requestCount = per * crafts })
    end
    local ok, sent = pcall(ticker.requestFiltered, st.address, table.unpack(filters))
    if not ok or not sent or sent == 0 then
      note("Couldn't order " .. pretty(out) .. " ingredients: " .. tostring(sent), 1)
      return false
    end
    for name, per in pairs(perCraft(r.grid)) do stock[name] = (stock[name] or 0) - per * crafts end
    local id = nextJob
    nextJob = nextJob + 1
    dispatch.jobs[id] = { id = id, station = station, out = out, crafts = crafts, outCount = r.outCount or 1, t = now() }
    saveJobs()
    st.assigned, st.assignedAt = id, now()
    send({ kind = "job", to = station, job = id, grid = r.grid, crafts = crafts, out = out, outCount = r.outCount or 1 })
    note("Ordered " .. crafts * (r.outCount or 1) .. "x " .. pretty(out) .. " -> " .. st.name, 3)
    return true
  end

  local function tick()
    for id, j in pairs(dispatch.jobs) do
      if now() - j.t > ORDER_TIMEOUT_MINUTES * 60 then
        note("Turtle order " .. id .. " (" .. pretty(j.out) .. ") never finished", 1)
        dispatch.jobs[id] = nil
        saveJobs()
      end
    end
    for i = #recent, 1, -1 do if now() - recent[i].t > 120 then table.remove(recent, i) end end
    if not data.ok or data.paused then return end

    local stock = {}
    local okS, list = pcall(ticker.stock)
    if okS and type(list) == "table" then
      for _, it in pairs(list) do
        if type(it) == "table" and it.name then stock[it.name] = (stock[it.name] or 0) + (it.count or 0) end
      end
    end
    local wanted = {}
    for _, g in ipairs(data.gauges) do
      if not g.fluid and not g.paused and dispatch.recipes[g.item] then
        local w = wanted[g.item] or { target = 0, stock = g.stock, passive = true }
        w.target = math.max(w.target, g.targetItems)
        if not g.passive then w.passive, w.orderedBy = false, g.address end
        wanted[g.item] = w
        lastStock[g.item] = g.stock
      end
    end
    dispatch.state = {}
    for out, w in pairs(wanted) do
      local r = dispatch.recipes[out]
      local deficit = w.target - w.stock - inFlight(out)
      local why = deficit > 0 and "short" or "stocked"
      if not w.passive then
        why = "a gauge for it orders by itself (sends to " .. tostring(w.orderedBy) .. "): set it to Passive"
        deficit = 0
      end
      while deficit > 0 do
        local station = freeStation()
        if not station then why = "waiting for a free turtle" break end
        local crafts = math.min(BATCH, math.ceil(deficit / (r.outCount or 1)))
        local missing = {}
        for name, per in pairs(perCraft(r.grid)) do
          local can = math.floor((stock[name] or 0) / per)
          if can < crafts then crafts = can end
          if can <= 0 then table.insert(missing, pretty(name)) end
        end
        if crafts <= 0 then why = "missing " .. table.concat(missing, ", ") break end
        if not order(out, crafts, station, stock) then why = "order failed" break end
        deficit = deficit - crafts * (r.outCount or 1)
        why = "crafting"
      end
      dispatch.state[out] = why
    end
    local flying = {}
    for out in pairs(dispatch.recipes) do flying[out] = inFlight(out) end
    dispatch.flying = flying
  end

  local function onMessage(from, msg)
    if type(msg) ~= "table" then return end
    if msg.kind == "station" then
      local st = dispatch.stations[from] or {}
      st.address, st.name, st.t, st.free, st.job = msg.address, msg.name or ("Turtle " .. from), now(), msg.free, msg.job
      if st.assigned and (msg.job == st.assigned or now() - (st.assignedAt or 0) > 10) then st.assigned = nil end
      if st.assigned then st.free = false end
      dispatch.stations[from] = st
    elseif msg.kind == "done" or msg.kind == "failed" then
      local j = dispatch.jobs[msg.job]
      if j then
        local made = (msg.crafted or 0) * (j.outCount or 1)
        if made > 0 then table.insert(recent, { out = j.out, count = made, t = now(), stockAt = lastStock[j.out] or 0 }) end
        dispatch.jobs[msg.job] = nil
        saveJobs()
        if msg.kind == "failed" then note(pretty(j.out) .. ": " .. tostring(msg.reason) .. " (" .. made .. " made)", 2)
        else note("Crafted " .. made .. "x " .. pretty(j.out), 5) end
      end
      if dispatch.stations[from] then dispatch.stations[from].assigned = nil end
    elseif msg.kind == "learn" and type(msg.grid) == "table" and msg.out then
      dispatch.recipes[msg.out] = { grid = msg.grid, outCount = msg.outCount or 1, by = from }
      save(DIR .. "/recipes", dispatch.recipes)
      note("Learned " .. pretty(msg.out) .. " (" .. (msg.outCount or 1) .. " per craft)", 5)
      send({ kind = "learned", by = from, out = msg.out })
    end
  end

  function dispatchLoop()
    local nextTick = 0
    while true do
      if DISPATCH ~= false and not ticker then ticker = peripheral.find("Create_StockTicker") end
      dispatch.active = DISPATCH ~= false and ticker ~= nil
      local timer = os.startTimer(0.5)
      local ev = { os.pullEvent() }
      if ev[1] == "rednet_message" and ev[4] == PROTOCOL then
        pcall(onMessage, ev[2], ev[3])
      elseif ev[1] == "peripheral_detach" then
        ticker = nil
      end
      os.cancelTimer(timer)
      if dispatch.active and now() >= nextTick then
        nextTick = now() + 2
        send({ kind = "dispatcher" })
        local ok, err = pcall(tick)
        if not ok then note("Dispatcher error: " .. tostring(err), 1) end
      end
    end
  end
end

-- ============================================================ DirectGPU renderer

local gpu, display, W, H
local page, pageCount, pageAt = 1, 1, now()

local FONT = "SansSerif"
local BG = { 14, 16, 20 }
local PANEL = { 27, 31, 38 }
local PANEL2 = { 35, 40, 49 }
local MUTED = { 135, 144, 158 }
local WHITE = { 236, 239, 244 }
local GREEN = { 62, 192, 104 }
local AMBER = { 240, 172, 52 }
local RED = { 232, 84, 74 }
local BLUE = { 84, 156, 240 }
local GREY = { 110, 116, 126 }
local TRACK = { 48, 54, 64 }

local SEV_COLOR = { RED, AMBER, BLUE, GREY, GREEN }

local BADGE_COLORS = {
  { 231, 76, 60 }, { 230, 126, 34 }, { 241, 196, 15 }, { 46, 204, 113 }, { 26, 188, 156 },
  { 52, 152, 219 }, { 155, 89, 182 }, { 236, 112, 160 }, { 149, 165, 166 }, { 211, 84, 0 },
}
local function badgeColor(id)
  local h = 0
  for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000003 end
  return BADGE_COLORS[h % #BADGE_COLORS + 1]
end

local function findMonitor()
  if MONITOR then return MONITOR end
  local best, area = nil, 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then
      local ok, w, h = pcall(peripheral.call, name, "getSize")
      if ok and w * h > area then best, area = name, w * h end
    end
  end
  return best
end

local function setupGpu()
  gpu = peripheral.find("directgpu")
  local mon = findMonitor()
  if not gpu or not mon then return false end
  local ok, id = pcall(gpu.autoDetectAndCreateDisplay, mon, RESOLUTION or 1)
  if not ok then return false end
  display = id
  local info = gpu.getDisplayInfo(display)
  -- Small monitors get a higher resolution so the dashboard has room.
  if not RESOLUTION and info.pixelHeight < 300 then
    local res = math.min(4, math.ceil(300 / info.pixelHeight))
    local ok2, id2 = pcall(gpu.autoDetectAndCreateDisplay, mon, res)
    if ok2 then
      display = id2
      info = gpu.getDisplayInfo(display)
    end
  end
  W, H = info.pixelWidth, info.pixelHeight
  pcall(gpu.setDisplayPersistent, display, true)
  return true
end

local function I(v) return math.floor(v + 0.5) end

local function rect(x, y, w, h, c)
  if w <= 0 or h <= 0 then return end
  gpu.fillRect(display, I(x), I(y), I(w), I(h), c[1], c[2], c[3])
end

local function text(s, x, y, c, size, style)
  gpu.drawText(display, s, I(x), I(y), c[1], c[2], c[3], FONT, I(size), style or "plain")
end

local widthCache = {}
local function textWidth(s, size, style)
  local key = s .. "|" .. I(size) .. "|" .. (style or "plain")
  local w = widthCache[key]
  if not w then
    local m = gpu.measureText(s, FONT, I(size), style or "plain")
    w = (m and m.width) or #s * size * 0.55
    widthCache[key] = w
  end
  return w
end

local function fit(s, maxW, size, style)
  if textWidth(s, size, style) <= maxW then return s end
  while #s > 1 and textWidth(s .. "..", size, style) > maxW do s = s:sub(1, -2) end
  return s .. ".."
end

local function textRight(s, right, y, c, size, style)
  text(s, right - textWidth(s, size, style), y, c, size, style)
end

local function line(x1, y1, x2, y2, c)
  gpu.drawLine(display, I(x1), I(y1), I(x2), I(y2), c[1], c[2], c[3])
end

local function circle(cx, cy, r, c, filled)
  gpu.drawCircle(display, I(cx), I(cy), I(r), c[1], c[2], c[3], filled)
end

-- Donut showing a fraction, drawn with radial lines.
local function ring(cx, cy, r, thick, frac, c)
  circle(cx, cy, r, TRACK, true)
  local steps = math.max(8, math.floor(2 * math.pi * r))
  local filled = math.floor(steps * math.max(0, math.min(1, frac)))
  for i = 0, filled do
    local a = (i / steps) * 2 * math.pi - math.pi / 2
    line(cx + math.cos(a) * (r - thick), cy + math.sin(a) * (r - thick), cx + math.cos(a) * r, cy + math.sin(a) * r, c)
  end
  circle(cx, cy, r - thick, PANEL, true)
end

local function sparkline(x, y, w, h, values, c)
  if #values < 2 then return end
  local prevX, prevY
  for i, v in ipairs(values) do
    local px = x + (i - 1) / (#values - 1) * w
    local py = y + h - v * h
    if prevX then
      line(prevX, prevY, px, py, c)
      line(prevX, prevY + 1, px, py + 1, c)
    end
    prevX, prevY = px, py
  end
end

local function tile(x, y, w, h, label, value, color, small, big)
  rect(x, y, w, h, PANEL)
  rect(x, y, 3, h, color)
  text(label, x + 10, y + 6, MUTED, small)
  text(fit(value, w - 16, big, "bold"), x + 10, y + 8 + small, WHITE, big, "bold")
end

local function drawGauge(g, x, y, w, h, small, medium)
  local color = SEV_COLOR[g.sev]
  rect(x, y, w, h, PANEL)
  rect(x, y, 4, h, color)

  local pad = math.max(6, h * 0.12)
  local bd = h - pad * 2
  local bx = x + 4 + pad
  local bcol = badgeColor(g.item)
  rect(bx, y + pad, bd, bd, bcol)
  local initials = pretty(g.item):gsub("(%a)%a*%s*", "%1"):sub(1, 2):upper()
  local iw = textWidth(initials, medium, "bold")
  text(initials, bx + (bd - iw) / 2, y + pad + (bd - medium) / 2 - 1, { 20, 20, 24 }, medium, "bold")

  local tx = bx + bd + pad
  local right = x + w - pad
  local name = pretty(g.item)
  local cc = crafterRecipeFor(g.item)
  local needed = neededSet()[g.item]
  local tag = (needed and "  NEEDED") or (cc and "  CC") or ""
  text(fit(name, right - tx - textWidth(tag, small, "bold"), medium, "bold"), tx, y + pad - 2, WHITE, medium, "bold")
  if needed then
    textRight("NEEDED", right, y + pad, RED, small, "bold")
    -- red outline so it stands out
    rect(x, y, w, 2, RED)
    rect(x, y + h - 2, w, 2, RED)
    rect(x + w - 2, y, 2, h, RED)
  elseif cc then
    textRight("CC", right, y + pad, BLUE, small, "bold")
  end

  local unit = g.fluid and (g.unit == "FLUID_BUCKET" and " B" or " mB") or ""
  local counts = fmtNum(g.stock) .. "/" .. fmtNum(g.targetItems) .. unit
  local by = y + pad + medium + 4
  text(counts, tx, by, MUTED, small)
  local status = (cc and cc.status ~= "" and g.sev ~= 5) and cc.status or g.label
  local room = right - tx - textWidth(counts, small) - 8
  if textWidth(status, small, "bold") > room then status = g.shortLabel end
  textRight(fit(status, room, small, "bold"), right, by, color, small, "bold")

  -- Stock bar with the promised amount stacked on top
  local barY = y + h - pad - 5
  local barW = right - tx
  rect(tx, barY, barW, 5, TRACK)
  local target = math.max(1, g.targetItems)
  local stockW = barW * math.min(1, g.stock / target)
  local promW = barW * math.min(1 - stockW / barW, g.promised / target)
  rect(tx, barY, stockW, 5, g.sev == 5 and GREEN or color)
  rect(tx + stockW, barY, promW, 5, BLUE)
end

local function drawGpu()
  local s = stats()
  local pad = math.max(6, math.floor(W * 0.015))
  local small = math.max(8, math.floor(H * 0.032))
  local medium = math.max(10, math.floor(H * 0.042))
  local big = math.max(12, math.floor(H * 0.06))

  gpu.clear(display, BG[1], BG[2], BG[3])

  -- Header
  local headH = big + pad * 2
  rect(0, 0, W, headH, PANEL)
  text(TITLE, pad, pad - 1, WHITE, big, "bold")
  local tw = textWidth(TITLE, big, "bold")
  if data.name ~= "" then text(data.name, pad * 2 + tw, pad + (big - small) / 2, MUTED, small) end
  local clock = clockText()
  local cw = textWidth(clock, medium, "bold")
  text(clock, W - pad - cw, (headH - medium) / 2, WHITE, medium, "bold")
  local pill = (not data.ok and "OFFLINE") or (data.paused and "PAUSED") or "RUNNING"
  local pillC = (not data.ok and RED) or (data.paused and GREY) or GREEN
  local pw = textWidth(pill, small, "bold") + pad * 2
  local ph = small + pad
  rect(W - pad * 2 - cw - pw, (headH - ph) / 2, pw, ph, pillC)
  text(pill, W - pad * 2 - cw - pw + pad, (headH - ph) / 2 + pad / 2, BG, small, "bold")

  if not data.ok then
    text(data.err or "No data", pad, headH + pad * 2, RED, medium, "bold")
    gpu.updateDisplay(display)
    return
  end

  -- KPI tiles
  local y = headH + pad
  local tileH = small + big + 18
  local tiles = (W >= 520) and 5 or 3
  local gap = pad
  local tileW = (W - pad * 2 - gap * (tiles - 1)) / tiles
  local x = pad

  -- Health ring with sparkline
  rect(x, y, tileW, tileH, PANEL)
  local frac = s.total > 0 and s.ok / s.total or 1
  local rr = (tileH - 12) / 2
  ring(x + 8 + rr, y + tileH / 2, rr, math.max(3, rr * 0.28), frac, frac >= 0.999 and GREEN or (frac > 0.6 and AMBER or RED))
  local pct = math.floor(frac * 100 + 0.5) .. "%"
  local pctW = textWidth(pct, small, "bold")
  text(pct, x + 8 + rr - pctW / 2, y + tileH / 2 - small / 2 - 1, WHITE, small, "bold")
  local hx = x + 16 + rr * 2
  text("Healthy", hx, y + 6, MUTED, small)
  text(s.ok .. "/" .. s.total, hx, y + 8 + small, WHITE, big, "bold")
  local vals = {}
  for _, h in ipairs(history) do table.insert(vals, h.total > 0 and h.ok / h.total or 1) end
  sparkline(hx, y + tileH - 12, x + tileW - hx - 8, 8, vals, GREEN)
  x = x + tileW + gap

  tile(x, y, tileW, tileH, "Short", tostring(s.short), s.short > 0 and RED or GREEN, small, big)
  x = x + tileW + gap
  tile(x, y, tileW, tileH, "In transit", fmtNum(s.promised), BLUE, small, big)
  x = x + tileW + gap
  if tiles == 5 then
    tile(x, y, tileW, tileH, "Missing links", tostring(data.missing), data.missing > 0 and RED or GREEN, small, big)
    x = x + tileW + gap
    if crafterFresh() then
      local m = crafter.msg
      local made = 0
      for _, r in ipairs(m.recipes or {}) do made = made + (r.made or 0) end
      local busy = m.active ~= nil
      local blocked = crafterBlocked()
      if #blocked > 0 and not busy then
        tile(x, y, tileW, tileH, "Crafter: blocked", pretty(blocked[1].item), RED, small, big)
      else
        tile(x, y, tileW, tileH, "Crafter: " .. (busy and "crafting" or "idle"), busy and pretty(m.active) or (fmtNum(made) .. " made"), busy and AMBER or GREEN, small, big)
      end
    else
      tile(x, y, tileW, tileH, "Crafter", "offline", GREY, small, big)
    end
  end
  y = y + tileH + pad

  -- Gauge cards
  local footH = small + pad * 2
  local bodyH = H - y - footH - pad
  local cardH = math.max(medium + small + 26, math.floor(H * 0.12))
  local minW = math.max(150, math.floor(W * 0.23))
  local cols = math.max(1, math.floor((W - pad * 2 + gap) / (minW + gap)))
  local rows = math.max(1, math.floor((bodyH + gap) / (cardH + gap)))
  local per = cols * rows
  pageCount = math.max(1, math.ceil(#data.gauges / per))
  if page > pageCount then page = 1 end
  local cardW = (W - pad * 2 - gap * (cols - 1)) / cols

  if #data.gauges == 0 then
    text("No gauges on this controller yet.", pad, y + pad, MUTED, medium)
  end
  for i = 1, per do
    local g = data.gauges[(page - 1) * per + i]
    if not g then break end
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    drawGauge(g, pad + col * (cardW + gap), y + row * (cardH + gap), cardW, cardH, small, medium)
  end

  -- Footer: latest event and page dots
  local fy = H - footH
  rect(0, fy, W, footH, PANEL)
  local blocked = crafterBlocked()
  local ev = feed[1]
  if #blocked > 0 then
    local b = blocked[math.floor(now() / 4) % #blocked + 1]
    local why, sev = supplyState(b.item)
    local msg = b.recipe .. " blocked: " .. pretty(b.item) .. " " .. b.have .. "/" .. b.need .. "  >  " .. why
    circle(pad + 4, fy + footH / 2, 4, RED, true)
    text(fit(msg, W - pad * 2 - 14 - pageCount * 12, small, "bold"), pad + 14, fy + (footH - small) / 2 - 1, SEV_COLOR[sev] or RED, small, "bold")
  elseif ev then
    local c = SEV_COLOR[ev.sev] or WHITE
    circle(pad + 4, fy + footH / 2, 4, c, true)
    text(fit(ev.t .. "  " .. ev.text, W * 0.6, small), pad + 14, fy + (footH - small) / 2 - 1, WHITE, small)
  elseif crafterFresh() then
    text("Crafter: " .. (crafter.msg.activity or ""), pad, fy + (footH - small) / 2 - 1, MUTED, small)
  end
  if pageCount > 1 then
    local dot = 6
    local dx = W - pad - pageCount * (dot + 6)
    for p = 1, pageCount do
      circle(dx + (p - 1) * (dot + 6) + dot / 2, fy + footH / 2, dot / 2, p == page and WHITE or GREY, true)
    end
  end

  gpu.updateDisplay(display)
end

-- ============================================================ plain monitor fallback

local function drawPlain()
  local name = findMonitor()
  local mon = name and peripheral.wrap(name)
  if not mon then return end
  mon.setTextScale(0.5)
  local w, h = mon.getSize()
  mon.setBackgroundColour(colours.black)
  mon.clear()
  local function at(x, y, s, c)
    mon.setCursorPos(x, y)
    mon.setTextColour(c or colours.white)
    mon.write(s)
  end
  local s = stats()
  at(1, 1, TITLE .. (data.name ~= "" and (" - " .. data.name) or ""), colours.white)
  at(w - 5, 1, clockText(), colours.lightGrey)
  if not data.ok then
    at(1, 3, data.err or "No data", colours.red)
    return
  end
  at(1, 2, "Healthy " .. s.ok .. "/" .. s.total .. "  Short " .. s.short .. "  Transit " .. fmtNum(s.promised) .. "  Links " .. data.missing, colours.lightGrey)
  local blocked = crafterBlocked()
  if #blocked > 0 then
    local b = blocked[1]
    at(1, 3, (b.recipe .. " blocked: " .. pretty(b.item) .. " > " .. supplyState(b.item)):sub(1, w), colours.red)
  end
  local sevC = { colours.red, colours.orange, colours.lightBlue, colours.grey, colours.lime }
  local per = h - 4
  pageCount = math.max(1, math.ceil(#data.gauges / per))
  if page > pageCount then page = 1 end
  local y = 4
  for i = 1, per do
    local g = data.gauges[(page - 1) * per + i]
    if not g then break end
    at(1, y, "\7", sevC[g.sev])
    local nameW = math.max(8, w - 28)
    local nm = pretty(g.item)
    if #nm > nameW then nm = nm:sub(1, nameW - 1) .. "." end
    at(3, y, nm)
    at(w - 24, y, fmtNum(g.stock) .. "/" .. fmtNum(g.targetItems), colours.lightGrey)
    local label = g.label
    if #label > 12 then label = label:sub(1, 12) end
    at(w - 12, y, label, sevC[g.sev])
    y = y + 1
  end
  if pageCount > 1 then at(1, h, "Page " .. page .. "/" .. pageCount .. " (tap to flip)", colours.grey) end
end

-- ============================================================ display + input

local useGpu = false
local gpuError = nil

-- ============================================================ stuck alerts

-- Pings Discord when the crafting computer goes silent or the controller is
-- gone, saying what to restart; a follow-up without a ping when it's fixed.
local alerts = { queue = {}, open = {}, error = nil }

local function alertEmbed(title, what, fix, color, ping)
  if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == "" or not http then return end
  local fields = { { name = "What happened", value = what } }
  if fix then table.insert(fields, { name = "What to do", value = fix }) end
  local ok, body = pcall(textutils.serializeJSON, {
    username = "Factory Monitor",
    content = (ping and DISCORD_MENTION) or "",
    allowed_mentions = { parse = { "roles", "users", "everyone" } },
    embeds = { { title = title, color = color, fields = fields, footer = { text = os.date("!%Y-%m-%d %H:%M UTC") } } },
  }, { unicode_strings = true })
  if ok then table.insert(alerts.queue, body) end
end

local function problemCheck(key, active, delay, title, what, fix)
  local p = alerts.open[key]
  if active then
    if not p then
      p = { since = now(), sent = false }
      alerts.open[key] = p
    end
    if not p.sent and now() - p.since >= delay then
      p.sent, p.title = true, title
      alertEmbed("STUCK: " .. title, what, fix, 15158332, true)
    end
  elseif p then
    if p.sent then alertEmbed("Fixed: " .. p.title, "Back to normal.", nil, 3066993, false) end
    alerts.open[key] = nil
  end
end

local function alertLoop()
  local lastTick = 0
  while true do
    if now() - lastTick >= 10 then
      lastTick = now()
      -- only once we've heard from the crafter at least once, so a monitor
      -- without a crafter never alerts
      problemCheck("crafter", crafter.at > 0 and not crafterFresh(), 120, "crafting computer offline",
        "The Mech Crafter computer hasn't reported in for over 2 minutes.",
        "Restart the **crafting computer** (and make sure the base it's in is loaded). Check the cable or modems between it and this Factory Monitor.")
      problemCheck("controller", not data.ok, 120, "Factory Controller unreadable",
        data.err or "The Factory Monitor can't read the Factory Controller.",
        "Check the wired modem on the **Factory Controller** is red (connected), then restart the **Factory Monitor computer**.")
    end
    local body = table.remove(alerts.queue, 1)
    if body then
      local ok, res, err = pcall(http.post, DISCORD_WEBHOOK, body, { ["Content-Type"] = "application/json" })
      if ok and res then res.close() alerts.error = nil else alerts.error = tostring(err or res) end
      sleep(2)
    else
      sleep(1)
    end
  end
end

local function drawTerminal()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  print("Factory Monitor")
  print("")
  if data.ok then
    local s = stats()
    print("Controller: " .. (data.name ~= "" and data.name or controllerName() or "?"))
    print("Gauges: " .. s.total .. "  healthy " .. s.ok .. "  short " .. s.short)
    print("In transit: " .. s.promised .. "  missing links: " .. data.missing)
  else
    term.setTextColor(colors.red)
    print(data.err or "Waiting for data")
    term.setTextColor(colors.white)
  end
  print("Crafter: " .. (crafterFresh() and (crafter.msg.activity or "online") or "offline"))
  for _, b in ipairs(crafterBlocked()) do
    term.setTextColor(colors.red)
    print("  " .. b.recipe .. " needs " .. pretty(b.item) .. " (" .. b.have .. "/" .. b.need .. "): " .. supplyState(b.item))
    term.setTextColor(colors.white)
  end
  if dispatch.active then
    local free, busy = 0, 0
    for _, st in pairs(dispatch.stations) do
      if now() - st.t < 8 then if st.free then free = free + 1 else busy = busy + 1 end end
    end
    local recipesN, jobsN = 0, 0
    for _ in pairs(dispatch.recipes) do recipesN = recipesN + 1 end
    for _ in pairs(dispatch.jobs) do jobsN = jobsN + 1 end
    print("Turtles: " .. free .. " free, " .. busy .. " busy, " .. jobsN .. " orders, " .. recipesN .. " recipes")
    for item, why in pairs(dispatch.state or {}) do
      if why ~= "stocked" then print("  " .. pretty(item) .. ": " .. why) end
    end
    for i = 1, math.min(4, #dispatch.lines) do print("  " .. dispatch.lines[i]) end
  elseif DISPATCH ~= false then
    print("Turtles: off (no Stock Ticker on the network)")
  end
  print("Display: " .. (useGpu and "DirectGPU" or "plain monitor"))
  if gpuError then
    term.setTextColor(colors.orange)
    print("GPU: " .. gpuError)
    term.setTextColor(colors.white)
  end
end

local function displayLoop()
  useGpu = setupGpu()
  if not useGpu then gpuError = "no DirectGPU block or monitor found" end
  local retryAt = now() + 30
  while true do
    if pageCount > 1 and now() - pageAt >= PAGE_SECONDS then
      page = page % pageCount + 1
      pageAt = now()
    end
    if useGpu then
      local ok, err = pcall(drawGpu)
      if ok then gpuError = nil else
        useGpu, gpuError, retryAt = false, tostring(err), now() + 30
      end
    end
    if not useGpu then
      pcall(drawPlain)
      if now() >= retryAt then
        useGpu = setupGpu()
        retryAt = now() + 30
      end
    end
    drawTerminal()
    sleep(1)
  end
end

local function flip(dir)
  page = (page - 1 + dir) % pageCount + 1
  pageAt = now()
end

local function inputLoop()
  while true do
    local timer = os.startTimer(0.1)
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" then
      local okS, w = pcall(peripheral.call, ev[2], "getSize")
      if okS and w then flip(ev[3] < w / 2 and -1 or 1) end
    end
    if useGpu and gpu and display then
      local ok, has = pcall(gpu.hasEvents, display)
      while ok and has do
        local e = gpu.pollEvent(display)
        if e and e.type == "mouse_click" and W then flip(e.x < W / 2 and -1 or 1) end
        ok, has = pcall(gpu.hasEvents, display)
      end
    end
    if ev[1] ~= "timer" or ev[2] ~= timer then os.cancelTimer(timer) end
  end
end

local function readyToUpdate()
  if next(dispatch.jobs) ~= nil then return false end  -- let running turtle orders finish
  return true
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-factory-monitor"
local UPDATE_FILE = "factory_monitor.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not _G.load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not _G.load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end

bootUpdate()
parallel.waitForAny(dataLoop, netLoop, displayLoop, inputLoop, alertLoop, dispatchLoop, updateLoop)
