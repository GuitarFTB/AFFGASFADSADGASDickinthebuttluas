-- == CONFIG ==
local DEFAULT_MAX_OFFSET   = 98
local DEFAULT_STEP         = 15
local DEFAULT_EXPLORE_PCT  = 13
local DEFAULT_DECAY_PCT    = 5
local MOVE_SPEED_THRESH    = 110
local MISS_RETRY_LIMIT     = 5
local JITTER_COOLDOWN_S    = 0.30

-- == UTILS ==
local function clamp(v, lo, hi) if v<lo then return lo elseif v>hi then return hi else return v end end
local function hypot(x,y) x=x or 0; y=y or 0; return math.sqrt(x*x+y*y) end
local function deg_atan2(y,x) return math.deg(math.atan2(y or 0, x or 0)) end
local function now() return (game and game.global_vars and game.global_vars.real_time) or 0 end

local function get_prop(ent, names, field)
    if not ent then return nil end
    for i=1,#names do
        local nm = names[i]
        local o = ent[nm]
        if type(o)=="function" then o = o(ent) end
        if o ~= nil then
            if field and type(o)=="table" then
                local f = o[field] or o[field=="y" and "Y" or field]
                if type(f)=="function" then f = f(o) end
                return f
            end
            if type(o)=="table" and o.get then o=o:get() end
            return o
        end
    end
    return nil
end

local function gget(ctrl, def)
    if not ctrl then return def end
    if ctrl.get_value then
        local p = ctrl:get_value()
        if p and p.get then
            local v = p:get()
            if v ~= nil then return v end
        end
    end
    if ctrl.get then
        local v = ctrl:get()
        if v ~= nil then return v end
    end
    if ctrl.value ~= nil then return ctrl.value end
    return def
end
local function gset(ctrl, val)
    if not ctrl then return end
    if ctrl.get_value then local p=ctrl:get_value(); if p and p.set then p:set(val); return end end
    if ctrl.set then ctrl:set(val) end
end

-- == UI ==
local ui = gui.ctx:find("lua>elements a")
local cb_enable = gui.checkbox(gui.control_id("rz_enable"))
local cb_learn  = gui.checkbox(gui.control_id("rz_learn"))
local sl_maxoff = gui.slider (gui.control_id("rz_max_off"),  0,180, DEFAULT_MAX_OFFSET)
local sl_step   = gui.slider (gui.control_id("rz_step"),     5, 45, DEFAULT_STEP)
local sl_eps    = gui.slider (gui.control_id("rz_eps"),      0,100, DEFAULT_EXPLORE_PCT)
local sl_decay  = gui.slider (gui.control_id("rz_decay"),    0, 20, DEFAULT_DECAY_PCT)
local sl_spdth  = gui.slider (gui.control_id("rz_spdth"),    0,500, MOVE_SPEED_THRESH)
local cb_dump   = gui.checkbox(gui.control_id("rz_dump"))
local cb_clear  = gui.checkbox(gui.control_id("rz_clear"))
ui:add(gui.make_control("Enable Resolver", cb_enable))
ui:add(gui.make_control("Learning",        cb_learn))
ui:add(gui.make_control("Max Offset (°)",  sl_maxoff))
ui:add(gui.make_control("Offset Step (°)", sl_step))
ui:add(gui.make_control("Explore %",       sl_eps))
ui:add(gui.make_control("Decay %",         sl_decay))
ui:add(gui.make_control("Move Speed Thresh", sl_spdth))
ui:add(gui.make_control("Dump Memory",     cb_dump))
ui:add(gui.make_control("Clear Memory",    cb_clear))
ui:reset()

-- == SELF/TEAM ==
local myPawn, myTeam = nil, nil
local myName = (game.cvar and game.cvar:find("name") and game.cvar:find("name").value) or ""
events.present_queue:add(function()
    if myPawn or myName=="" then return end
    entities.players:for_each(function(e)
        local p=e.entity
        if p and p.is_alive and p:is_alive() and p.get_name and p:get_name()==myName then
            myPawn = p
            myTeam = get_prop(p, {"m_iTeamNum"}) or (p.m_iTeamNum and p.m_iTeamNum:get()) or myTeam
        end
    end)
end)

-- == ENEMIES ==
-- enemies[handle] = {entity, vel, duck, bucket, last_offset, last_result, last_time, retry_count}
local enemies = {}
events.present_queue:add(function()
    if not myPawn or not myTeam then return end
    entities.players:for_each(function(e)
        local p=e.entity
        if p and p.is_alive and p:is_alive() then
            local team = get_prop(p, {"m_iTeamNum"}) or (p.m_iTeamNum and p.m_iTeamNum:get())
            if team and team ~= myTeam then
                local h = (e.handle and e.handle.get and e.handle:get()) or e.handle
                if h then
                    local rec = enemies[h] or {}
                    rec.entity = p
                    rec.vel  = get_prop(p, {"m_vecVelocity"}) or rec.vel or {x=0,y=0,z=0}
                    rec.duck = get_prop(p, {"m_flDuckAmount"}) or rec.duck or 0
                    rec.bucket = rec.bucket or ""
                    rec.last_offset = rec.last_offset or 0
                    rec.last_result = rec.last_result or nil
                    rec.last_time   = rec.last_time or 0
                    rec.retry_count = rec.retry_count or 0
                    enemies[h]=rec
                end
            end
        end
    end)
end)

-- == LEARNING ==
-- memory[bucket][offsetStr] = {hits=, misses=}
local memory = {}
local function bucket_key(speed, duck)
    return ("s%d_d%d"):format(math.floor((speed or 0)/25), math.floor((duck or 0)*10))
end
local function learn(bucket, off, did_hit, decay_pct)
    if not bucket then return end
    memory[bucket] = memory[bucket] or {}
    local k = tostring(off)
    local m = memory[bucket][k] or {hits=0, misses=0}
    if did_hit then m.hits = m.hits + 1 else m.misses = m.misses + 1 end
    local d = (decay_pct or 0) * 0.01
    if d>0 then m.hits = m.hits*(1-d); m.misses = m.misses*(1-d) end
    memory[bucket][k] = m
end
local function score(bucket, off)
    local b = memory[bucket]; if not b then return 0 end
    local m = b[tostring(off)]; if not m then return 0 end
    return (m.hits - m.misses)
end
local function choose_offset(bucket, maxo, step, eps, fallback, retry_count)
    local list = {}
    for o=-maxo, maxo, step do list[#list+1]=o end
    if #list==0 then return fallback end
    if eps > math.random() then
        return list[math.random(#list)]
    end
    -- pick best-scoring; shift index by retry_count to avoid tunneling
    local best_o, best_s = fallback, -1e9
    for i=1,#list do
        local o = list[i]
        local s = score(bucket, o)
        if s > best_s then best_o, best_s = o, s end
    end
    local shift = clamp((retry_count or 0), 0, MISS_RETRY_LIMIT)
    local idx = 1
    -- find rank-ordered list
    table.sort(list, function(a,b) return score(bucket,a) > score(bucket,b) end)
    idx = clamp(1+shift, 1, #list)
    return list[idx] or best_o
end

-- == RESOLVER ==
function resolve_enemy_yaw(enemy)
    if not gget(cb_enable,false) then return nil end
    local p = enemy and enemy.entity; if not p then return nil end

    local yaw = get_prop(p, {"m_angEyeAngles"}, "y") or
                get_prop(p, {"m_angEyeAngles[1]"}, "y") or 0

    local vel = enemy.vel or get_prop(p, {"m_vecVelocity"}) or {x=0,y=0,z=0}
    local spd = hypot(vel.x, vel.y)
    local duck= enemy.duck or get_prop(p, {"m_flDuckAmount"}) or 0

    local spd_th = gget(sl_spdth, MOVE_SPEED_THRESH)
    if spd > spd_th and vel.x and vel.y then
        return (deg_atan2(vel.y, vel.x) + 180) % 360
    end

    local maxo = gget(sl_maxoff, DEFAULT_MAX_OFFSET)
    local step = gget(sl_step,   DEFAULT_STEP)
    local eps  = (gget(sl_eps,   DEFAULT_EXPLORE_PCT) or 0)/100.0

    local bucket = bucket_key(spd, duck)
    local chosen = maxo
    if gget(cb_learn,true) then
        local handle = enemy.handle or enemy.h or enemy.id
        local rec = handle and enemies[handle] or nil
        local retry = rec and rec.retry_count or 0
        chosen = choose_offset(bucket, maxo, step, eps, maxo, retry)
        if rec then
            -- brief cooldown: invert immediately after a miss within cooldown window
            if rec.last_result == false and (now() - (rec.last_time or 0)) < JITTER_COOLDOWN_S then
                chosen = -chosen
            end
            rec.bucket = bucket
            rec.last_offset = chosen
        end
    end

    return (yaw + chosen) % 360
end

-- == EVENTS ==
local function record_result(handle, did_hit)
    if type(handle)~="number" then return end
    local rec = enemies[handle]; if not rec then return end
    learn(rec.bucket, rec.last_offset, did_hit, gget(sl_decay, DEFAULT_DECAY_PCT))
    rec.last_result = did_hit
    rec.last_time = now()
    rec.retry_count = did_hit and 0 or (rec.retry_count + 1)
    if rec.retry_count > (MISS_RETRY_LIMIT+2) then rec.retry_count = MISS_RETRY_LIMIT+2 end
end

local function hook(name, fn)
    if events[name] and events[name].add then events[name]:add(fn) end
end

hook("ragebot_hit",  function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), true) end)
hook("aim_hit",      function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), true) end)
hook("shot_hit",     function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), true) end)
hook("resolver_hit", function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), true) end)

hook("ragebot_miss",  function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), false) end)
hook("aim_miss",      function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), false) end)
hook("shot_miss",     function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), false) end)
hook("resolver_miss", function(ev) record_result(ev and (ev.handle or ev.target_handle or ev.target or ev.entity_handle), false) end)

-- == DEBUG ==
events.present_queue:add(function()
    if gget(cb_dump,false) then
        for b,offs in pairs(memory) do
            for off,data in pairs(offs) do
                print(string.format("[rz] %s | off=%s | hits=%.1f misses=%.1f score=%.1f",
                    b, off, data.hits, data.misses, (data.hits - data.misses)))
            end
        end
        gset(cb_dump,false)
    end
    if gget(cb_clear,false) then
        memory = {}
        for _,rec in pairs(enemies) do rec.retry_count=0; rec.last_result=nil end
        gset(cb_clear,false)
    end
end)

print("[Lua2] Resolver loaded")
