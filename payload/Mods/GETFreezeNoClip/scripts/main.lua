-- Granny: Escape Together — Freeze / No-Clip v0.1.2 ALPHA
-- UE4SS 4.0.0 Lua mod, designed against Steam build 26710650 (UE 5.8).
-- No networking, anti-cheat bypasses, changes to saves, or multiplayer lockouts.
-- All Unreal calls happen inside the game thread; failures are logged, not silently assumed.

local PREFIX = "[GETMOD]"
local freeze_on = false
local noclip_on = false
local frozen = {}                  -- actor identity -> saved state
local flight = nil                 -- saved local pawn state
local guarded_player = nil         -- local pawn's original CanBeDamaged flag
local ghost_managers = {}          -- per-instance spawn-manager states
local weapon_actors = {}          -- verified Grandpa-attached gun actors only
local attack_component_class = nil
local attack_component_class_checked = false
local loop_ticks = 0
local poll_error_announced = false
local ghost_suppressed = {}         -- local/script cleanup of ghost actors during F6
local kismet_lib = nil
local kismet_checked = false

local function say(msg)
    print(PREFIX .. " " .. tostring(msg) .. "\n")
end

local function valid(obj)
    if obj == nil then return false end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result == true
end

local function call(obj, method, ...)
    if not valid(obj) then return false, nil end
    local args = {...}
    local ok, result = pcall(function()
        return obj[method](obj, table.unpack(args))
    end)
    return ok, result
end

local function get_prop(obj, prop)
    if not valid(obj) then return nil end
    local ok, result = pcall(function() return obj[prop] end)
    if ok then return result end
    return nil
end

local function set_prop(obj, prop, value)
    if not valid(obj) then return false end
    return pcall(function() obj[prop] = value end)
end

local function class_name(obj)
    if not valid(obj) then return "<invalid>" end
    local ok, result = pcall(function() return obj:GetClass():GetFullName() end)
    if ok and type(result) == "string" then return result end
    return "<unknown>"
end

local function actor_key(obj)
    local ok, result = pcall(function() return obj:GetAddress() end)
    if ok and result then return tostring(result) end
    return nil
end

local function same_world(obj, other)
    if not valid(obj) or not valid(other) then return false end
    local ok, result = pcall(function()
        local a, b = obj:GetWorld(), other:GetWorld()
        return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
    end)
    return ok and result == true
end

-- Use Unreal's local-controller flag; never assume the first controller is ours
-- when acting as the multiplayer host.
local function local_player()
    local ok, controllers = pcall(function() return FindAllOf("PlayerController") end)
    if not ok or not controllers then return nil, nil end
    for _, pc in ipairs(controllers) do
        if valid(pc) then
            local local_ok, is_local = call(pc, "IsLocalController")
            if local_ok and is_local == true then
                local pawn = get_prop(pc, "Pawn")
                if not valid(pawn) then _, pawn = call(pc, "GetPawn") end
                if valid(pawn) then return pc, pawn end
            end
        end
    end
    return nil, nil
end

local function controller_of(actor)
    local ok, controller = call(actor, "GetController")
    if ok and valid(controller) then return controller end
    return get_prop(actor, "Controller")
end

local function is_player_controller(ctrl)
    if not valid(ctrl) then return false end
    local ok, ret = call(ctrl, "IsA", "/Script/Engine.PlayerController")
    if ok and ret == true then return true end
    return class_name(ctrl):lower():find("playercontroller", 1, true) ~= nil
end

local function is_ai_controller(ctrl)
    if not valid(ctrl) then return false end
    local ok, ret = call(ctrl, "IsA", "/Script/AIModule.AIController")
    if ok and ret == true then return true end
    local name = class_name(ctrl):lower()
    return name:find("ai_controller",1,true) ~= nil or
           name:find("aicontroller",1,true) ~= nil
end

-- Static collector evidence: BP_Grandpa, BP_Dog, BP_Spider_Big,
-- BP_Spider_Small. Granny's exact gameplay blueprint needs live inspection.
local function known_enemy_class(lower)
    if lower:find("cinematic",1,true) or lower:find("cutscene",1,true)
       or lower:find("intro",1,true) or lower:find("waypoint",1,true)
       or lower:find("bark_area",1,true) or lower:find("attackarea",1,true)
       or lower:find("spider_hole",1,true) then return false end
    local terms = {"bp_grandpa", "bp_granny", "bp_spider_big", "bp_spider_small",
                   "bp_dog", "bp_crocodile", "monster_child", "bp_monster", "bp_child",
                   "bp_babymonster"}
    for _, term in ipairs(terms) do
        if lower:find(term, 1, true) then return true end
    end
    return false
end

local function is_target(actor)
    if not valid(actor) then return false, "invalid" end
    local ctrl = controller_of(actor)
    -- Multiplayer guests may NOT see other players' PlayerControllers.
    -- Replicated PlayerState and IsPlayerControlled offer extra safeguards.
    if is_player_controller(ctrl) then return false, "human-controlled" end
    local player_state = get_prop(actor, "PlayerState")
    if valid(player_state) then return false, "replicated-playerstate" end
    local controlled_ok, player_controlled = call(actor, "IsPlayerControlled")
    if controlled_ok and player_controlled == true then return false, "player-controlled" end
    local c = class_name(actor):lower()
    -- The granddaughter is NOT frozen in place: doing so trapped its camera
    -- effect. Suppress it and its spawn timer through dedicated ghost handling.
    if c:find("bp_granddaughterghost",1,true) then
        return false, "ghost-suppressed-separately"
    end
    -- Granny may be player-controlled. Her name alone is NOT enough evidence.
    -- Require an actual AIController to freeze Granny, even in a client lobby.
    if c:find("bp_granny",1,true) and not is_ai_controller(ctrl) then
        return false, "granny-needs-ai-controller"
    end
    if known_enemy_class(c) then return true, "asset-class" end
    if is_ai_controller(ctrl) then return true, "ai-controller" end
    return false, "not-ai"
end

local function movement_of(actor)
    local move = get_prop(actor, "CharacterMovement")
    if valid(move) then return move end
    local ok, another = call(actor, "GetMovementComponent")
    if ok and valid(another) then return another end
    return nil
end

local function mesh_of(actor)
    local ok, mesh = call(actor, "GetMesh")
    if ok and valid(mesh) then return mesh end
    local mesh2 = get_prop(actor, "Mesh")
    if valid(mesh2) then return mesh2 end
    return nil
end

local function vector3(actor)
    local ok, pos = call(actor, "K2_GetActorLocation")
    if not ok or not pos then return nil end
    local ok2, out = pcall(function()
        return {X=pos.X+0.0, Y=pos.Y+0.0, Z=pos.Z+0.0}
    end)
    if ok2 then return out end
    return nil
end

local function rotation3(actor)
    local ok, rot = call(actor, "K2_GetActorRotation")
    if not ok or not rot then return nil end
    local ok2, out = pcall(function()
        return {Pitch=rot.Pitch+0.0, Yaw=rot.Yaw+0.0, Roll=rot.Roll+0.0}
    end)
    if ok2 then return out end
    return nil
end

-- Determine local-player-world ownership before touching gameplay objects.
-- Fallback to the existing behavior if no local pawn exists during initial spawn.
local function relevant_world(obj)
    local _, lp = local_player()
    if valid(lp) then return same_world(obj, lp) end
    return true
end

local function is_ghost_name(lower)
    return lower:find("bp_granddaughterghost", 1, true) ~= nil
end

local function is_ghost_manager_name(lower)
    return lower:find("bp_granddaughterspawnmanager", 1, true) ~= nil
end

local function is_grandpa_name(lower)
    return lower:find("bp_grandpa", 1, true) ~= nil
           and not lower:find("screamer",1,true)
           and not lower:find("cinematic",1,true)
end

-- Game-specific attack components may run even when an actor's normal tick
-- stops. Only pause attack/weapon named components attached to a known enemy.
local function get_attack_component_class()
    if not attack_component_class_checked then
        attack_component_class_checked = true
        local ok, cls = pcall(function()
            return StaticFindObject("/Script/Engine.ActorComponent")
        end)
        if ok and valid(cls) then attack_component_class = cls end
    end
    return attack_component_class
end

local function component_list(actor)
    local cls = get_attack_component_class()
    if not valid(cls) then return nil end
    local ok, arr = call(actor, "GetComponentsByClass", cls)
    if not ok or not arr then return nil end
    return arr
end

local function pause_attack_components(actor, saved)
    saved.attack_components = saved.attack_components or {}
    local arr = component_list(actor)
    if not arr then return 0 end
    local ok, count = pcall(function() return math.min(#arr, 100) end)
    if not ok then return 0 end
    local n = 0
    for i = 1, count do
        local comp_ok, comp = pcall(function() return arr[i] end)
        if comp_ok and valid(comp) then
            local key = actor_key(comp)
            if key and not saved.attack_components[key] then
                local full_ok, fullname = pcall(function() return comp:GetFullName() end)
                local cname = (class_name(comp) .. " " ..
                    (full_ok and tostring(fullname) or "")):lower()
                if cname:find("shotgun",1,true) or cname:find("weapon",1,true)
                   or cname:find("attack",1,true) or cname:find("guncomponent",1,true)
                   or cname:find("firecomponent",1,true) then
                    local tick_ok, was_enabled = call(comp, "IsComponentTickEnabled")
                    if tick_ok and type(was_enabled) == "boolean" then
                        saved.attack_components[key] = {obj=comp, tick=was_enabled}
                        if was_enabled then call(comp, "SetComponentTickEnabled", false) end
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

local function restore_attack_components(saved)
    for _, c in pairs(saved.attack_components or {}) do
        if valid(c.obj) and type(c.tick) == "boolean" then
            call(c.obj, "SetComponentTickEnabled", c.tick)
        end
    end
end

local function pause_brain(state)
    local ctrl = state.ctrl
    if not valid(ctrl) or not is_ai_controller(ctrl) then return end
    if not valid(state.brain) then
        local brain = get_prop(ctrl, "BrainComponent")
        if not valid(brain) then _, brain = call(ctrl, "GetBrainComponent") end
        if valid(brain) then
            state.brain = brain
            local ok, running = call(brain, "IsRunning")
            state.brain_was_running = ok and running == true
            if state.brain_was_running then
                local stopped = call(brain, "StopLogic", "GETFreezeNoClip: F6")
                say("ATTACK control: " .. state.label ..
                    " BrainComponent StopLogic " .. (stopped and "sent" or "unavailable"))
            end
        end
    end
    if state.ctrl_tick == nil then
        local ok, tick = call(ctrl, "IsActorTickEnabled")
        if ok and type(tick) == "boolean" then
            state.ctrl_tick = tick
            if tick then call(ctrl, "SetActorTickEnabled", false) end
        end
    end
end

local function hold_brain(state)
    if not valid(state.brain) then return end
    local ok, running = call(state.brain, "IsRunning")
    if ok and running == true then
        call(state.brain, "StopLogic", "GETFreezeNoClip: F6 hold")
    end
end

local function restore_brain(state)
    -- Never restart an AI controller that has since become a human controller.
    if valid(state.ctrl) then
        if type(state.ctrl_tick) == "boolean" then
            call(state.ctrl, "SetActorTickEnabled", state.ctrl_tick)
        end
        local current = controller_of(state.actor)
        if current == state.ctrl and is_ai_controller(current)
           and state.brain_was_running and valid(state.brain) then
            call(state.brain, "RestartLogic")
        end
    end
end

local function set_damage_permission(pawn, allowed)
    local ok = call(pawn, "SetCanBeDamaged", allowed)
    if ok then return true end
    return set_prop(pawn, "bCanBeDamaged", allowed)
end

local function release_player_guard()
    if not guarded_player then return end
    if valid(guarded_player.pawn) then
        set_damage_permission(guarded_player.pawn, guarded_player.original)
    end
    guarded_player = nil
    say("FREEZE damage guard OFF (local pawn original value restored)")
end

local function hold_player_guard()
    if not freeze_on then release_player_guard(); return end
    local has_enemy = false
    for _, st in pairs(frozen) do
        if valid(st.actor) and relevant_world(st.actor) then
            has_enemy = true; break
        end
    end
    if not has_enemy then release_player_guard(); return end
    local _, pawn = local_player()
    if not valid(pawn) then release_player_guard(); return end
    if guarded_player and guarded_player.pawn ~= pawn then release_player_guard() end
    if not guarded_player then
        local previous = get_prop(pawn, "bCanBeDamaged")
        if type(previous) ~= "boolean" then
            local ok, ret = call(pawn, "CanBeDamaged")
            if ok and type(ret) == "boolean" then previous = ret end
        end
        if type(previous) ~= "boolean" then
            say("WARN: local damage guard not available (cannot read previous state)")
            return
        end
        if not set_damage_permission(pawn, false) then
            say("WARN: local damage guard could not be applied")
            return
        end
        guarded_player = {pawn=pawn, original=previous}
        say("FREEZE damage guard ON (local pawn only; normal damage API; original="..
            tostring(previous)..")")
    elseif loop_ticks % 8 == 0 then
        local enabled = get_prop(pawn, "bCanBeDamaged")
        if enabled == true then set_damage_permission(pawn, false) end
    end
end

-- v0.1.2: the ghost is a timed *effect* rather than a normal moving enemy.
-- Freezing its actor (v0.1.1) stranded the player's pulse/scare effect. Instead,
-- prevent new appearances and ask the game's own ghost to clean itself up.
-- All state changes are scoped to a granddaughter manager in the local world.
local function get_kismet_library()
    if not kismet_checked then
        kismet_checked=true
        for _,path in ipairs({"/Script/Engine.Default__KismetSystemLibrary",
                              "Default__KismetSystemLibrary"}) do
            local ok, obj = pcall(function() return StaticFindObject(path) end)
            if ok and valid(obj) then kismet_lib=obj; break end
        end
    end
    return kismet_lib
end

local function pause_manager_timer(actor, name, state)
    local lib=get_kismet_library()
    local handle=get_prop(actor,name)
    if not valid(lib) or handle == nil then return false end
    local exists_ok,exists=call(lib,"K2_TimerExistsHandle",actor,handle)
    if not exists_ok or exists~=true then return false end
    local was_ok,was_paused=call(lib,"K2_IsTimerPausedHandle",actor,handle)
    if not was_ok or type(was_paused)~="boolean" then return false end
    if not was_paused then
        local paused=call(lib,"K2_PauseTimerHandle",actor,handle)
        if not paused then return false end
        local check_ok,now_paused=call(lib,"K2_IsTimerPausedHandle",actor,handle)
        if not (check_ok and now_paused==true) then return false end
        state.timers[name]={handle=handle, library=lib, was_paused=false}
        say("GHOST spawn timer PAUSED: "..name)
    end
    return true
end

local function clear_ghost_camera_shakes()
    local pc=local_player()
    if not valid(pc) then return end
    local camera=get_prop(pc,"PlayerCameraManager")
    if not valid(camera) then _,camera=call(pc,"GetPlayerCameraManager") end
    if valid(camera) then
        -- This is local-only and deliberately called only on F6 ON / ghost cleanup.
        -- Some games use post-process materials instead, which this cannot stop.
        local ok=call(camera,"StopAllCameraShakes",true)
        if ok then say("GHOST local camera-shake reset requested") end
    end
end

local function suppress_ghost(actor)
    if not freeze_on or not valid(actor) or not relevant_world(actor) then return end
    if not is_ghost_name(class_name(actor):lower()) then return end
    local key=actor_key(actor)
    if not key then return end
    local old=ghost_suppressed[key]
    if old and valid(old.actor) and old.actor==actor then return end
    ghost_suppressed[key]={actor=actor}
    -- Use the game's own explicit cleanup before destroying the appearance.
    -- The F8 scan identified both of these BP functions on the ghost class.
    local cleared=call(actor,"ClearTwitchTimer")
    local cleaned=call(actor,"GhostMustBeDeletted")
    -- These are optional reflected methods. If the game doesn't handle them,
    -- DestroyActor prevents the actor from persisting as a frozen scare source.
    local destroyed=false
    if valid(actor) then destroyed=call(actor,"K2_DestroyActor") end
    if valid(actor) and not destroyed then
        -- A game-specific blueprint may not expose K2_DestroyActor. A tiny
        -- lifespan is a fallback: don't make the appearance immortal again.
        call(actor,"SetLifeSpan",0.05)
        call(actor,"SetActorHiddenInGame",true)
    end
    clear_ghost_camera_shakes()
    say("GHOST suppressed during F6: twitch_cleanup="..tostring(cleared)..
        "; blueprint_cleanup="..tostring(cleaned)..
        "; destroy_requested="..tostring(destroyed))
end

local function suppress_existing_ghosts()
    local ok,actors=pcall(function() return FindAllOf("BP_GranddaughterGhost_C") end)
    if ok and actors then
        for _,actor in ipairs(actors) do pcall(suppress_ghost,actor) end
    end
end

local function freeze_ghost_manager(actor)
    if not valid(actor) or not relevant_world(actor) then return end
    local c=class_name(actor):lower()
    if not is_ghost_manager_name(c) then return end
    local key=actor_key(actor)
    if not key then return end
    local state=ghost_managers[key]
    if state and state.actor~=actor then state=nil; ghost_managers[key]=nil end
    if not state then
        state={actor=actor, label=class_name(actor), flags={},timers={}}
        ghost_managers[key]=state
        -- Save and restore only the manager's own flags, not global time.
        for _,name in ipairs({"bGlobalCooldownActive","bOtherScreamerActive"}) do
            local prev=get_prop(actor,name)
            if type(prev)=="boolean" then
                if set_prop(actor,name,true) then state.flags[name]=prev end
            end
        end
        local tick_ok,tick=call(actor,"IsActorTickEnabled")
        if tick_ok and type(tick)=="boolean" then
            state.tick=tick
            if tick then call(actor,"SetActorTickEnabled",false) end
        end
        local dilation=get_prop(actor,"CustomTimeDilation")
        if type(dilation)=="number" then
            state.dilation=dilation
            set_prop(actor,"CustomTimeDilation",0.0001)
        end
        local p1=pause_manager_timer(actor,"TryPrepareSpawnTimerHandle",state)
        local p2=pause_manager_timer(actor,"InitialSpawnTimerHandle",state)
        if not p1 and not p2 then
            say("NOTE: ghost timer handles not paused; cooldown flags + new-spawn cleanup remain active")
        end
        say("GHOST spawn manager suppressed: "..state.label)
    else
        -- Some BP timers may be recreated while F6 is ON; keep manager-specific
        -- flags enforced but never touch the world's timers.
        for name in pairs(state.flags) do
            if get_prop(actor,name)~=true then set_prop(actor,name,true) end
        end
        for _,name in ipairs({"TryPrepareSpawnTimerHandle","InitialSpawnTimerHandle"}) do
            if not state.timers[name] then pause_manager_timer(actor,name,state) end
        end
    end
    local ghost=get_prop(actor,"CurrentGhost")
    if valid(ghost) then suppress_ghost(ghost) end
end

local function release_ghost_manager(state)
    if not valid(state.actor) then return end
    -- Restore timer state first; do not unpause timers that were already paused.
    for name, entry in pairs(state.timers or {}) do
        if valid(entry.library) and entry.was_paused==false then
            local ok=call(entry.library,"K2_UnPauseTimerHandle",state.actor,entry.handle)
            if not ok then say("WARN: ghost timer resume unavailable: "..name) end
        end
    end
    for name,old in pairs(state.flags or {}) do set_prop(state.actor,name,old) end
    if type(state.tick)=="boolean" then call(state.actor,"SetActorTickEnabled",state.tick) end
    if type(state.dilation)=="number" then set_prop(state.actor,"CustomTimeDilation",state.dilation) end
end

local function linked_to_frozen_grandpa(actor)
    local relatives = {}
    local _, a = call(actor,"GetOwner")
    local _, b = call(actor,"GetAttachParentActor")
    relatives[1],relatives[2]=a,b
    for _, owner in pairs(relatives) do
        if valid(owner) then
            local key=actor_key(owner)
            if key and frozen[key] and is_grandpa_name(class_name(owner):lower()) then
                return true
            end
        end
    end
    return false
end

local function freeze_grandpa_weapon(actor)
    if not valid(actor) or not relevant_world(actor) then return end
    local cname=class_name(actor):lower()
    if not (cname:find("bp_gun",1,true) or cname:find("bp_shotgun",1,true)) then return end
    if not linked_to_frozen_grandpa(actor) then return end
    local key=actor_key(actor)
    if not key or weapon_actors[key] then return end
    local state={actor=actor, label=class_name(actor)}
    local ok,tick=call(actor,"IsActorTickEnabled")
    if ok and type(tick)=="boolean" then
        state.tick=tick
        if tick then call(actor,"SetActorTickEnabled",false) end
    end
    pause_attack_components(actor,state)
    weapon_actors[key]=state
    say("GRANDPA attached gun actor paused: "..state.label)
end

local function release_grandpa_weapon(state)
    if valid(state.actor) and type(state.tick)=="boolean" then
        call(state.actor,"SetActorTickEnabled",state.tick)
    end
    restore_attack_components(state)
end

local function freeze_actor(actor)
    if is_ghost_name(class_name(actor):lower()) then
        suppress_ghost(actor)
        return false
    end
    local target, reason = is_target(actor)
    if not target or not relevant_world(actor) then return false end
    local key = actor_key(actor)
    if not key then return false end
    if frozen[key] and valid(frozen[key].actor) and frozen[key].actor == actor then return false end
    local ctrl = controller_of(actor)
    local move = movement_of(actor)
    local mesh = mesh_of(actor)
    local state = {
        actor = actor, ctrl = ctrl, move = move, mesh = mesh,
        pos = vector3(actor), rot = rotation3(actor),
        original_collision = nil, reason = reason,
        label = class_name(actor),
    }
    if valid(move) then
        state.speed = get_prop(move, "MaxWalkSpeed")
        state.acceleration = get_prop(move, "MaxAcceleration")
        state.mode = get_prop(move, "MovementMode")
    end
    if valid(mesh) then state.pause_anims = get_prop(mesh, "bPauseAnims") end
    local tick_ok, tick_enabled = call(actor, "IsActorTickEnabled")
    if tick_ok and type(tick_enabled) == "boolean" then state.tick = tick_enabled end
    frozen[key] = state
    pause_brain(state)
    local paused_components = pause_attack_components(actor, state)
    if paused_components > 0 then
        say("ATTACK control: "..state.label.." paused "..paused_components.." attack components")
    end

    if valid(ctrl) and is_ai_controller(ctrl) then call(ctrl, "StopMovement") end
    if valid(move) then
        call(move, "StopMovementImmediately")
        if type(state.speed) == "number" then set_prop(move, "MaxWalkSpeed", 0) end
        if type(state.acceleration) == "number" then set_prop(move, "MaxAcceleration", 0) end
        if type(state.mode) == "number" then call(move, "DisableMovement") end
    end
    if valid(mesh) and type(state.pause_anims) == "boolean" then
        set_prop(mesh, "bPauseAnims", true)
    end
    if type(state.tick) == "boolean" and state.tick == true then
        call(actor, "SetActorTickEnabled", false)
    end
    say("FREEZE acquired: " .. state.label .. " via " .. reason)
    return true
end

local function unfreeze_actor(state)
    if not state or not valid(state.actor) then return end
    local actor = state.actor
    if valid(state.move) then
        local m = state.move
        if type(state.speed) == "number" then set_prop(m, "MaxWalkSpeed", state.speed) end
        if type(state.acceleration) == "number" then set_prop(m, "MaxAcceleration", state.acceleration) end
        if type(state.mode) == "number" then call(m, "SetMovementMode", state.mode, 0) end
    end
    if valid(state.mesh) and type(state.pause_anims) == "boolean" then
        set_prop(state.mesh, "bPauseAnims", state.pause_anims)
    end
    if type(state.tick) == "boolean" then
        call(actor, "SetActorTickEnabled", state.tick)
    end
    restore_attack_components(state)
    restore_brain(state)
end

local function thaw_all()
    local n = 0
    for key, state in pairs(frozen) do
        local ok, err = pcall(unfreeze_actor, state)
        if not ok then say("WARN: unfreeze problem: " .. tostring(err)) end
        frozen[key] = nil
        n = n + 1
    end
    for key,st in pairs(ghost_managers) do
        pcall(release_ghost_manager,st)
        ghost_managers[key]=nil
    end
    for key,st in pairs(weapon_actors) do
        pcall(release_grandpa_weapon,st)
        weapon_actors[key]=nil
    end
    ghost_suppressed = {}
    release_player_guard()
    say("FREEZE OFF; released " .. n .. " saved AI actors and ghost/weapon managers")
end

local function acquire_pawns()
    -- FindAllOf("Pawn") includes derived pawns (NPCs, player pawns). We explicitly
    -- check human PlayerControllers in is_target before modifying anything.
    local ok, found = pcall(function() return FindAllOf("Pawn") end)
    if ok and found then
        for _, actor in ipairs(found) do pcall(freeze_actor, actor) end
    end
end

local function acquire_named_nonpawns()
    -- Some animal actors may not inherit from Pawn. This asset-driven list
    -- supplements the AIController-based discovery and doesn't scan all actors.
    local candidates = {"BP_Grandpa_C", "BP_Granny_C", "BP_Dog_C",
                        "BP_Spider_Big_C", "BP_Spider_Small_C",
                        "BP_Crocodile_C", "BP_Monster_C", "BP_Child_C",
                        "BP_BabyMonster_C"}
    for _, cls in ipairs(candidates) do
        local ok, found = pcall(function() return FindAllOf(cls) end)
        if ok and found then
            for _, actor in ipairs(found) do pcall(freeze_actor, actor) end
        end
    end
end

local function acquire_ghost_managers()
    local ok,actors=pcall(function() return FindAllOf("BP_GranddaughterSpawnManager_C") end)
    if ok and actors then
        for _,actor in ipairs(actors) do pcall(freeze_ghost_manager,actor) end
    end
end

local function acquire_grandpa_weapons()
    for _,cls in ipairs({"BP_Gun_C", "BP_Gun_FirstPerson_C"}) do
        local ok,actors=pcall(function() return FindAllOf(cls) end)
        if ok and actors then
            for _,actor in ipairs(actors) do pcall(freeze_grandpa_weapon,actor) end
        end
    end
end

local function hold_frozen()
    for key, st in pairs(frozen) do
        if not valid(st.actor) then
            frozen[key] = nil
        else
            local still_ai, reason = is_target(st.actor)
            -- Granny briefly drops her AIController during animation/respawn.
            -- A transient nil controller is not evidence of human possession.
            local transient_granny = reason == "granny-needs-ai-controller"
                and is_grandpa_name(st.label:lower()) == false
                and st.label:lower():find("bp_granny",1,true) ~= nil
            if not still_ai and not transient_granny then
                -- Role/possession changes in multiplayer: stop immediately.
                pcall(unfreeze_actor, st)
                frozen[key] = nil
                say("UNFREEZE role changed or target lost ("..reason.."): " .. st.label)
            else
                local actual_ctrl = controller_of(st.actor)
                if not valid(st.ctrl) and is_ai_controller(actual_ctrl) then
                    st.ctrl = actual_ctrl
                    pause_brain(st)
                end
                hold_brain(st)
                local ctrl = actual_ctrl
                if is_ai_controller(ctrl) then call(ctrl, "StopMovement") end
                if valid(st.move) then call(st.move, "StopMovementImmediately") end
                -- Re-anchor any replicated movement, root motion, or AI teleports.
                -- Only attempt if it actually moved; reduce needless net updates.
                if st.pos and st.rot then
                    local now = vector3(st.actor)
                    if now then
                        local dx,dy,dz = now.X-st.pos.X,now.Y-st.pos.Y,now.Z-st.pos.Z
                        if dx*dx+dy*dy+dz*dz > 4 then
                            call(st.actor,"K2_TeleportTo",st.pos,st.rot)
                        end
                    end
                end
            end
        end
    end
end

local function set_flight_speed(speed)
    if flight and valid(flight.move) then
        set_prop(flight.move, "MaxFlySpeed", speed)
    end
end

local function end_flight()
    if not flight then noclip_on=false; return end
    local st = flight
    if valid(st.pawn) then
        if type(st.collision) == "boolean" then
            call(st.pawn, "SetActorEnableCollision", st.collision)
        else
            call(st.pawn, "SetActorEnableCollision", true)
        end
    end
    if valid(st.move) then
        if type(st.fly_speed) == "number" then set_prop(st.move, "MaxFlySpeed", st.fly_speed) end
        if type(st.jump_velocity) == "number" then set_prop(st.move,"JumpZVelocity",st.jump_velocity) end
        if type(st.cheat_flying) == "boolean" then set_prop(st.move,"bCheatFlying",st.cheat_flying) end
        if type(st.mode) == "number" then
            call(st.move,"SetMovementMode",st.mode,0)
        else
            -- Falling is safer than forcing Walking if the player is mid-air.
            call(st.move,"SetMovementMode",3,0)
        end
    end
    flight = nil
    noclip_on = false
    say("NOCLIP OFF (local pawn restored)")
end

local function start_flight()
    local pc, pawn = local_player()
    if not valid(pc) or not valid(pawn) then
        say("NOCLIP refused: local possessed player pawn not found; enter a level first")
        return
    end
    local move = movement_of(pawn)
    if not valid(move) then
        say("NOCLIP refused: player has no detectable movement component")
        return
    end
    local collision_ok, collision = call(pawn,"GetActorEnableCollision")
    local original_collision = nil
    if collision_ok and type(collision)=="boolean" then original_collision = collision end
    flight = {
        pc=pc, pawn=pawn, move=move, space_observed=false,
        collision = original_collision,
        mode=get_prop(move,"MovementMode"),
        fly_speed=get_prop(move,"MaxFlySpeed"),
        jump_velocity=get_prop(move,"JumpZVelocity"),
        cheat_flying=get_prop(move,"bCheatFlying"),
    }
    -- Keep the local player pawn only. Do not modify any other player's state.
    call(pawn,"SetActorEnableCollision",false)
    set_prop(move,"bCheatFlying",true)
    local ok = call(move,"SetMovementMode",5,0)  -- MOVE_Flying
    if not ok then
        say("WARN: SetMovementMode(5) unavailable; flight may need further work")
    end
    if type(flight.jump_velocity)=="number" then
        -- Suppress the normal jump impulse while Space is used for vertical fly.
        set_prop(move,"JumpZVelocity",0)
    end
    set_flight_speed(900.0)
    noclip_on=true
    local has_auth,auth = call(pawn,"HasAuthority")
    say("NOCLIP ON (local only; host-authority=" .. tostring(has_auth and auth or "unknown") .. ")")
end

local function step_vertical(direction, amount)
    if not noclip_on or not flight or not valid(flight.pawn) then return false end
    local loc, rot = vector3(flight.pawn), rotation3(flight.pawn)
    if not loc or not rot then return false end
    loc.Z = loc.Z + direction*amount
    local ok, success = call(flight.pawn,"K2_TeleportTo",loc,rot)
    return ok and success ~= false
end

-- Optional held-key reading from reflected PlayerController::IsInputKeyDown.
-- If this Unreal build cannot construct FKey through Lua, tap-to-rise/fall
-- still works via UE4SS keybinds (Space / Ctrl / PageDown).
local function held(pc, unreal_name)
    if not valid(pc) then return false, false end
    local ok, value = call(pc, "IsInputKeyDown", {KeyName=FName(unreal_name)})
    if not ok then return false,false end
    return true,value == true
end

local function flight_watch()
    if not noclip_on then return end
    local pc,pawn = local_player()
    if not valid(pc) or not valid(pawn) or not flight or pawn ~= flight.pawn then
        end_flight()
        say("NOCLIP stopped on respawn / map transition / possession change")
        return
    end
    -- Server-side correction of a client pawn remains possible online.
    -- This logic has NO multiplayer-session lockout.
    if valid(flight.move) then
        local mm=get_prop(flight.move,"MovementMode")
        if type(mm)=="number" and mm~=5 then call(flight.move,"SetMovementMode",5,0) end
    end
    local down_ok, down=held(pc,"LeftControl")
    if down_ok == false then down_ok,down=held(pc,"RightControl") end
    local sprint_ok,sprint=held(pc,"LeftShift")
    if sprint_ok == false then sprint_ok,sprint=held(pc,"RightShift") end
    if sprint_ok then set_flight_speed(sprint and 1600 or 900) end
    if down_ok and down then step_vertical(-1, sprint and 120 or 65) end
end

-- A separate ~25 Hz loop provides controlled ascent while Space is held.
-- Keep Ctrl descent on the original 125ms path since that already felt right.
local function flight_rise_watch()
    if not noclip_on or not flight then return end
    local pc,pawn=local_player()
    if not valid(pc) or pawn~=flight.pawn then return end
    local ok, up=held(pc,"SpaceBar")
    if not ok or not up then
        -- GetInputKeyTimeDown is a separate reflected UE5.8 input API.
        local key={KeyName=FName("SpaceBar")}
        local time_ok,down_time=call(pc,"GetInputKeyTimeDown",key)
        if time_ok and type(down_time)=="number" then
            ok=true; up=up or (down_time>0)
        end
    end
    if ok and up then
        if not flight.space_observed then
            flight.space_observed=true
            say("NOCLIP Space held: smooth ascent enabled (150 cm/s)")
        end
        -- Prevent built-in Character Jump from repeating while in flying mode.
        call(pawn,"StopJumping")
        step_vertical(1,6.0)  -- 6 cm every 40 ms = 150 cm/s (1.5 m/s)
    elseif not ok and not poll_error_announced then
        poll_error_announced=true
        say("NOTE: continuous Space input unavailable; tap Space to ascend instead")
    end
end

local function toggle_freeze()
    freeze_on = not freeze_on
    if freeze_on then
        say("FREEZE ON (no multiplayer lockout; player-controlled characters excluded)")
        acquire_pawns()
        acquire_named_nonpawns()
        acquire_ghost_managers()
        suppress_existing_ghosts()
        clear_ghost_camera_shakes()
        acquire_grandpa_weapons()
        hold_player_guard()
        local n=0; for _ in pairs(frozen) do n=n+1 end
        say("FREEZE acquired initial count="..n)
    else
        thaw_all()
    end
end

-- F8-only introspection: discover relevant game-specific methods and timer
-- properties, without touching or invoking them. Output has no player data.
local function scan_class_details(actor, scanned)
    if not valid(actor) then return end
    local cls = actor:GetClass()
    if not valid(cls) then return end
    local c=class_name(actor)
    if scanned[c] then return end
    scanned[c]=true
    local lower = c:lower()
    if not (is_grandpa_name(lower) or is_ghost_name(lower) or
            is_ghost_manager_name(lower)) then return end
    local match_words = {"shoot","shot","fire","attack","spawn","ghost",
                         "timer","delay","kill","damage","death","despawn",
                         "destroy","scream","cooldown","visible"}
    local function relevant(name)
        local n=name:lower()
        for _,term in ipairs(match_words) do
            if n:find(term,1,true) then return true end
        end
        return false
    end
    local n_functions=0
    local ok_f = pcall(function()
        cls:ForEachFunction(function(fn)
            local name=fn:GetFName():ToString()
            if type(name)=="string" and relevant(name) and n_functions<40 then
                say("SCAN member function: class="..c.."; name="..name)
                n_functions=n_functions+1
            end
        end)
    end)
    local n_properties=0
    local ok_p = pcall(function()
        cls:ForEachProperty(function(prop)
            local name=prop:GetFName():ToString()
            if type(name)=="string" and relevant(name) and n_properties<40 then
                say("SCAN member property: class="..c.."; name="..name)
                n_properties=n_properties+1
            end
        end)
    end)
    say("SCAN class members: "..c.."; functions="..n_functions..
        " (API="..tostring(ok_f).."); properties="..n_properties..
        " (API="..tostring(ok_p)..")")
end

local function scan_snapshot()
    local _, local_pawn = local_player()
    say("SCAN BEGIN (live pawn classes; only game class names, no Steam IDs)")
    local seen={}
    local scanned_classes={}
    local ok,actors=pcall(function() return FindAllOf("Pawn") end)
    if ok and actors then
        local count=0
        for _,a in ipairs(actors) do
            if valid(a) and count<90 then
                local c=class_name(a)
                local ct=controller_of(a)
                local cc=valid(ct) and class_name(ct) or "<none>"
                local target,why=is_target(a)
                local localmark=valid(local_pawn) and (a==local_pawn)
                local line=string.format("SCAN pawn: class=%s; controller=%s; target=%s(%s); local=%s",c,cc,tostring(target),why,tostring(localmark))
                if not seen[line] then say(line); seen[line]=true; count=count+1 end
                scan_class_details(a,scanned_classes)
            end
        end
        say("SCAN pawn instances="..#actors)
    else say("SCAN failed: FindAllOf(Pawn)") end
    for _,name in ipairs({"BP_Grandpa_C","BP_Granny_C","BP_Dog_C","BP_Spider_Big_C","BP_Spider_Small_C",
                          "BP_GranddaughterGhost_C","BP_GranddaughterSpawnManager_C",
                          "BP_Gun_C","BP_Gun_FirstPerson_C"}) do
        local good,group=pcall(function() return FindAllOf(name) end)
        say("SCAN asset="..name.."; instances="..tostring(good and group and #group or 0))
        if good and group and (name == "BP_GranddaughterGhost_C" or
                             name == "BP_GranddaughterSpawnManager_C" or
                             name == "BP_Gun_C") then
            for i=1,math.min(#group,8) do
                local a=group[i]
                if valid(a) then
                    local o_ok,o=call(a,"GetOwner")
                    local owner=o_ok and valid(o) and class_name(o) or "<none>"
                    local t_ok,t=call(a,"IsActorTickEnabled")
                    local l_ok,l=call(a,"GetLifeSpan")
                    scan_class_details(a,scanned_classes)
                    if is_ghost_name(class_name(a):lower()) then
                        say("SCAN ghost bAttackTriggered="..tostring(get_prop(a,"bAttackTriggered")))
                    elseif is_ghost_manager_name(class_name(a):lower()) then
                        say("SCAN manager cooldown="..tostring(get_prop(a,"bGlobalCooldownActive"))..
                            "; other_screamer="..tostring(get_prop(a,"bOtherScreamerActive"))..
                            "; current_ghost="..tostring(valid(get_prop(a,"CurrentGhost"))))
                    end
                    say("SCAN detail: "..class_name(a).."; owner="..owner..
                        "; tick="..tostring(t_ok and t or "unknown")..
                        "; lifespan="..tostring(l_ok and l or "unknown"))
                end
            end
        end
    end
    say("SCAN END")
end

local function on_game_thread(fn)
    local ok, err=pcall(function()
        ExecuteInGameThread(function()
            local inner_ok, inner_err=pcall(fn)
            if not inner_ok then say("ERROR in game-thread action: "..tostring(inner_err)) end
        end)
    end)
    if not ok then say("ERROR scheduling game-thread action: "..tostring(err)) end
end

RegisterKeyBind(Key.F6, function() on_game_thread(toggle_freeze) end)
RegisterKeyBind(Key.F7, function()
    on_game_thread(function() if noclip_on then end_flight() else start_flight() end end)
end)
RegisterKeyBind(Key.F8, function() on_game_thread(scan_snapshot) end)
RegisterKeyBind(Key.SPACE, function()
    on_game_thread(function()
        if noclip_on and flight then
            local can,_=held(flight.pc,"SpaceBar")
            if not can then step_vertical(1,15) end
        end
    end)
end)
-- VK_CONTROL = 0x11, UE4SS keys are Windows virtual key codes.
RegisterKeyBind(0x11, function()
    on_game_thread(function()
        if noclip_on and flight then
            local can,_=held(flight.pc,"LeftControl")
            if not can then step_vertical(-1,110) end
        end
    end)
end)
RegisterKeyBind(Key.PAGE_DOWN, function()
    on_game_thread(function() if noclip_on then step_vertical(-1,110) end end)
end)

-- Hook actors that spawn after F6 was pressed (including level transitions).
-- UE4SS v4 supports this hook, but the periodic scan is the fallback.
if type(RegisterBeginPlayPostHook)=="function" then
    local ok,err=pcall(function()
        RegisterBeginPlayPostHook(function(actor)
            if freeze_on then
                local worked,why=pcall(function()
                    local name=class_name(actor):lower()
                    if is_ghost_manager_name(name) then
                        freeze_ghost_manager(actor)
                    elseif is_ghost_name(name) then
                        suppress_ghost(actor)
                    else
                        freeze_actor(actor)
                    end
                    freeze_grandpa_weapon(actor)
                end)
                if not worked then say("WARN spawn hook: "..tostring(why)) end
            end
        end)
    end)
    if not ok then say("NOTE: BeginPlay hook unavailable: "..tostring(err)) end
end

-- New, game-thread-safe timer API added in UE4SS v4. Keep work bounded.
if type(LoopInGameThreadWithDelay)=="function" then
    LoopInGameThreadWithDelay(125,function()
        local ok,err=pcall(function()
            loop_ticks=loop_ticks+1
            if freeze_on then
                hold_frozen()
                if loop_ticks%16==0 then
                    acquire_pawns(); acquire_named_nonpawns()
                    acquire_ghost_managers(); suppress_existing_ghosts()
                    acquire_grandpa_weapons()
                end
                -- The manager may change cooldown flags from a delayed BP event.
                -- Maintain suppression without touching timers for other actors.
                if loop_ticks % 4 == 0 then acquire_ghost_managers() end
                hold_player_guard()
            else
                release_player_guard()
            end
            flight_watch()
        end)
        if not ok then say("ERROR in control loop: "..tostring(err)) end
    end)
else
    say("WARNING: expected UE4SS v4 game-thread timer unavailable; F6 may not persist")
end

if type(LoopInGameThreadWithDelay)=="function" then
    LoopInGameThreadWithDelay(40,function()
        local ok,err=pcall(flight_rise_watch)
        if not ok then say("WARN: flight-rise loop: "..tostring(err)) end
    end)
end

say("Loaded v0.1.2 ALPHA; F6 AI freeze + granddaughter suppression | F7 smoother rise | F8 scan")
say("Target: Granny Escape Together, Steam build 26710650, UE5.8. Private consenting co-op only.")
