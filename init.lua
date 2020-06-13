teleportation = {}
teleportation.version = {}
teleportation.version.major = 1
teleportation.version.minor = 0
teleportation.version.patch = 0
teleportation.version.string = teleportation.version.major .. "." ..
    teleportation.version.minor .. "." ..
    teleportation.version.patch

-- Load settings
teleportation.cooldown_time = minetest.settings:get("teleportation_cooldown_time") or 5
teleportation.sound_enable = minetest.settings:get("teleportation_sound_enable") or true

-- Request mod storage
local storage = minetest.get_mod_storage()

-- Request translator
local S = minetest.get_translator(minetest.get_current_modname())

-- Test which games is active
-- local default_path = core.get_modpath("default") and default
local mineclone_path = core.get_modpath("mcl_core") and mcl_core

-- Define game specific items
local moditems = {}
if mineclone_path then
  moditems.sounds_stone = mcl_sounds.node_sound_stone_defaults
  moditems.iron_item = "mcl_core:iron_ingot"
  moditems.gold_item = "mcl_core:gold_ingot"
  moditems.power_item = "default:mese_crystal"
else
  moditems.sounds_stone = default.node_sound_stone_defaults
  moditems.iron_item = "default:steel_ingot"
  moditems.gold_item = "default:gold_ingot"
  moditems.power_item = "mesecons:redstone"
end
moditems._tt_help = S("Teleport from one teleporter to another")
moditems._doc_items_longdesc = S("Link two teleporters togehter to travel between them.")
moditems._doc_items_usagehelp = S("Each teleporter needs an ID. To establish a link between two teleporters A and B set the target ID of teleporter A to the ID of teleporter B and vice versa.")
moditems._doc_items_hidden = false



-- Check if a str starts with start
local function starts_with(str, start)
    return str:sub(1, #start) == start
end

-- Check if b is on top and in the middle of a
local function is_on_top(a, b)
    if b.x > (a.x - 0.3) and b.x < (a.x + 0.3)
        and b.z > (a.z - 0.3) and b.z < a.z + (0.3)
        and b.y > a.y and b.y < (a.y + 1) then
        return true
    else
        return false
    end
end

-- Replace node at pos with node of type name
local function swap_node(pos, node, name)
	if node.name == name then
		return
	end
	node.name = name
	minetest.swap_node(pos, node)
end

-- Check if the node at pos is not a block which obstructs teleportation
function teleportation.check_obstructed(pos)
	local def = minetest.registered_nodes[minetest.get_node(pos).name]
	-- Allow ladders, signs, wallmounted things and torches to not obstruct
	-- TODO: What about water?
	if def and
	            (def.drawtype == "airlike" or
	            def.drawtype == "signlike" or
	            def.drawtype == "torchlike" or
                (def.drawtype == "nodebox" and def.paramtype2 == "wallmounted")) then
	    return false
	end
	return true
end

-- Check if teleporter is ready and configuration is valid
function teleportation.check_link(pos, meta)
   -- Check if configuration variables are set
    local teleporter_id = meta:get_string("id")
    local target_id = meta:get_string("target")
    if teleporter_id == "" or target_id == "" then
        local error_message = S("Configuration invalid")
        meta:set_string("err", error_message)
        return false
    end

    -- Check if target exists
    local target = storage:get_string(target_id)
    if target == "" then
        local error_message = S("Target teleporter unknown")
        meta:set_string("err", error_message)
        return false
    end

    -- Check if target coordinates are valid
    local target_pos = minetest.string_to_pos(target)
    if target_pos == nil then
        local error_message = S("Target coordinates invalid")
        meta:set_string("err", error_message)
        return false
    end

    -- Check if target is loaded, and load if missing
    local target_clearance = vector.add(target_pos, vector.new(0, 2, 0))
    local target_node = minetest.get_node_or_nil(target_pos)
    if target_node == nil then
        minetest.load_area(target_pos, target_clearance)
        target_node = minetest.get_node_or_nil(target_pos)
        if target_node == nil then
            local error_message = S("Target area can not be loaded")
            meta:set_string("err", error_message)
            minetest.log("warning", "[teleportation] " .. error_message .. " (" .. minetest.pos_to_string(target_pos) .. ")")
            return false
        end
    end

    -- Check if target is really a teleporter
    if not starts_with(target_node.name, "teleportation:teleporter") then
        storage:set_string(target_id, "") -- Remove invalid reference
        local error_message = S("Target teleporter is gone")
        meta:set_string("err", error_message)
        return false
    end

    -- Check if teleporter link is valid
    local target_meta = minetest.env:get_meta(target_pos)
    if target_id ~= target_meta:get_string("id") or target_meta:get_string("target") ~= teleporter_id then
        local error_message = S("Teleporter link mismatch")
        meta:set_string("err", error_message)
        return false
    end

    -- Check if target is not obstructed
    local above1 = {x = target_pos.x, y = target_pos.y + 1, z = target_pos.z}
    local above2 = {x = target_pos.x, y = target_pos.y + 2, z = target_pos.z}
    if teleportation.check_obstructed(above1) or teleportation.check_obstructed(above2) then
        local error_message = S("Target teleporter obstructed")
        meta:set_string("err", error_message)
        return false
    end

    return true, target_pos, target_meta
end

-- on_timer callback for teleporter node
function teleportation.on_timer(pos)
	local node = minetest.get_node(pos)
	local meta = minetest.env:get_meta(pos)

	-- Check if we are on cooldown
	local cooldown = meta:get_int("cooldown")
	if cooldown > 0 then
	    cooldown = cooldown - 1
	    meta:set_int("cooldown", cooldown)
	    return true
	elseif cooldown == 0 and node.name == "teleportation:teleporter_cooldown" then
	    swap_node(pos, node, "teleportation:teleporter_ok")
	    if teleportation.sound_enable then
	        minetest.sound_play("teleportation_ready", {pos = pos, gain = 1.0, max_hear_distance = 10,})
	    end
	    return true
	end

	-- Find first player near the teleporter
	local player
	local objs = minetest.get_objects_inside_radius(pos, 1)
	for _, obj in pairs(objs) do
	    if obj:is_player() and is_on_top(pos, obj:get_pos()) then
	        player = obj
	        break
		end
	end

	-- No player near teleporter, save CPU cycles
	if player == nil then
	    return true
	end

	-- TODO: Check if we have fuel

	-- Check if the link to the target is valid and update node as well as formspec
	local valid_link, target_pos, target_meta = teleportation.check_link(pos, meta)
	if not valid_link then
	    if node.name ~= "teleportation:teleporter_error" and teleportation.sound_enable then
	        minetest.sound_play("teleportation_error", {pos = pos, gain = 1.0, max_hear_distance = 10,})
	    end
	    swap_node(pos, node, "teleportation:teleporter_error")
	    meta:set_string("formspec", teleportation.get_formspec({
	        owner = meta:get_string("owner"),
	        err = meta:get_string("err")
	    }))
	    return true
	else
        swap_node(pos, node, "teleportation:teleporter_ok")
        meta:set_string("err", "")
        meta:set_string("formspec", teleportation.get_formspec({
            owner = meta:get_string("owner"),
            err = meta:get_string("err")
        }))
    end

    -- Calculate teleportation position
	local teleport_vector = vector.subtract(target_pos, pos)
	local teleport_pos = vector.add(player:get_pos(), teleport_vector)

	-- Set teleporter on cooldown
	meta:set_int("cooldown", teleportation.cooldown_time)
	target_meta:set_int("cooldown", teleportation.cooldown_time)
	swap_node(pos, node, "teleportation:teleporter_cooldown")
	swap_node(target_pos, minetest.get_node(target_pos), "teleportation:teleporter_cooldown")


	-- Teleport player
	if teleportation.sound_enable then
	    minetest.sound_play("teleportation_teleport", {pos = pos, gain = 1.0, max_hear_distance = 10,})
	    player:move_to(teleport_pos, false)
	    minetest.sound_play("teleportation_teleport", {pos = target_pos, gain = 1.0, max_hear_distance = 10,})
	else
	    player:move_to(teleport_pos, false)
	end

	minetest.log("action", "[teleportation] " .. player:get_player_name() .. " teleported to " .. minetest.pos_to_string(teleport_pos))

	return true
end

-- Remove teleporter from global list
function teleportation.on_destruct(pos)
    local meta = minetest.env:get_meta(pos)
    storage:set_string(meta:get_string("id"), "")
end

-- Setup teleporter, start node timer
function teleportation.after_place_node(pos, placer)
	local meta = minetest.env:get_meta(pos)
	local name = placer:get_player_name()
	meta:set_string("owner", name)
	meta:set_string("err", S("Unknown"))
	meta:set_string("formspec", teleportation.get_formspec({owner = name, err = "Unknown"}))
	minetest.get_node_timer(pos):start(1.0)
end

-- Generate teleporter formspec from data
function teleportation.get_formspec(data)
    if data.err == "" then
        data.err = S("Teleporter ready")
    end

    return "formspec_version[3]" ..
        "size[11,7]" ..
        "field[1,1;4,1;id;" .. S("Teleporter ID") .. ";${id}]" ..
        "field[1,3;4,1;target;" .. S("Target ID") .. ";${target}]" ..
        "button[1,5;9,1;save;" .. S("Save") .. "]" ..
        "label[6,1;" .. S("Owner") .. ":]" ..
        "label[6,1.5;" .. minetest.formspec_escape(data.owner) .. "]" ..
        "label[6,3;" .. S("Status") .. ":]" ..
        "label[6,3.5;" .. minetest.formspec_escape(data.err) .. "]"
end

-- Update teleporter configuration via from event
function teleportation.on_receive_fields(pos, formname, fields, player)
    if fields.quit then
        return
    end

    -- Only the owner can edit the teleporter
    local meta = minetest.env:get_meta(pos)
    local player_name = player:get_player_name()
    if meta:get_string("owner") ~= player_name then
        minetest.chat_send_player(player_name, S("Can not edit, this is not your teleporter"))
        return
    end

    if fields.save then
        -- Ignore empty values and warn player
        if fields.id == "" or fields.target == "" then
            minetest.chat_send_player(player_name, S("ID or target must not be empty"))
            return
        end

        -- Check if teleporter ID is already in use
        if meta:get_string("id") ~= fields.id and storage:get_string(fields.id) ~= "" then
            minetest.chat_send_player(player_name, S("This teleporter ID is already in use"))
            return
        end

        -- Update teleporter ID if necessary
        if meta:get_string("id") ~= fields.id then
            local old_id = meta:get_string("id")
            meta:set_string("id", fields.id)
            storage:set_string(fields.id, minetest.pos_to_string(pos, 0))
            storage:set_string(old_id, "")
        end

        -- Update target ID no matter what
        meta:set_string("target", fields.target)

        -- Run teleporter test routine and update formspec
        local node = minetest.get_node(pos)
        if not teleportation.check_link(pos, meta) then
	        swap_node(pos, node, "teleportation:teleporter_error")
	        meta:set_string("formspec", teleportation.get_formspec({
	            owner = meta:get_string("owner"),
	            err = meta:get_string("err")
	        }))
	    else
            swap_node(pos, node, "teleportation:teleporter_ok")
            meta:set_string("err", "")
            meta:set_string("formspec", teleportation.get_formspec({
                owner = meta:get_string("owner"),
                err = meta:get_string("err")
            }))
        end
    end
end

minetest.register_node("teleportation:teleporter_ok", {
    description = "Teleporter",
    _tt_help = moditems._tt_help,
    _doc_items_longdesc = moditems._doc_items_longdesc,
    _doc_items_usagehelp = moditems._doc_items_usagehelp,
    _doc_items_hidden = moditems._doc_items_hidden,
    is_ground_content = false,
    on_timer = teleportation.on_timer,
    on_destruct = teleportation.on_destruct,
    after_place_node = teleportation.after_place_node,
    on_receive_fields = teleportation.on_receive_fields,
    tiles = {
        "teleportation_teleporter_up_green.png",    -- y+
        "teleportation_teleporter.png",             -- y-
        "teleportation_teleporter.png",             -- x+
        "teleportation_teleporter.png",             -- x-
        "teleportation_teleporter.png",             -- z+
        "teleportation_teleporter.png",             -- z-
    },
    groups = {pickaxey=1, material_stone=1, cracky=2},
    sounds = moditems.sounds_stone(),
    _mcl_blast_resistance = 3.5,
    _mcl_hardness = 3.5,
})

minetest.register_node("teleportation:teleporter_cooldown", {
    description = "Teleporter",
    _tt_help = moditems._tt_help,
    _doc_items_longdesc = moditems._doc_items_longdesc,
    _doc_items_usagehelp = moditems._doc_items_usagehelp,
    _doc_items_hidden = moditems._doc_items_hidden,
    is_ground_content = false,
    on_timer = teleportation.on_timer,
    on_destruct = teleportation.on_destruct,
    after_place_node = teleportation.after_place_node,
    on_receive_fields = teleportation.on_receive_fields,
    tiles = {
        "teleportation_teleporter_up_yellow.png",    -- y+
        "teleportation_teleporter.png",              -- y-
        "teleportation_teleporter.png",              -- x+
        "teleportation_teleporter.png",              -- x-
        "teleportation_teleporter.png",              -- z+
        "teleportation_teleporter.png",              -- z-
    },
    groups = {pickaxey=1, material_stone=1, cracky=2},
    sounds = moditems.sounds_stone(),
    _mcl_blast_resistance = 3.5,
    _mcl_hardness = 3.5,
})

minetest.register_node("teleportation:teleporter_error", {
    description = "Teleporter",
    _tt_help = moditems._tt_help,
    _doc_items_longdesc = moditems._doc_items_longdesc,
    _doc_items_usagehelp = moditems._doc_items_usagehelp,
    _doc_items_hidden = moditems._doc_items_hidden,
    is_ground_content = false,
    on_timer = teleportation.on_timer,
    on_destruct = teleportation.on_destruct,
    after_place_node = teleportation.after_place_node,
    on_receive_fields = teleportation.on_receive_fields,
    tiles = {
        "teleportation_teleporter_up_red.png",    -- y+
        "teleportation_teleporter.png",           -- y-
        "teleportation_teleporter.png",           -- x+
        "teleportation_teleporter.png",           -- x-
        "teleportation_teleporter.png",           -- z+
        "teleportation_teleporter.png",           -- z-
    },
    groups = {pickaxey=1, material_stone=1, cracky=2},
    sounds = moditems.sounds_stone(),
    _mcl_blast_resistance = 3.5,
    _mcl_hardness = 3.5,
})

minetest.register_craft({
    output = "teleportation:teleporter_error",
    recipe = {
        { moditems.iron_item,   moditems.power_item,    moditems.iron_item },
        { moditems.power_item,  moditems.gold_item,     moditems.power_item },
        { moditems.iron_item,   moditems.power_item,    moditems.iron_item },
    }
})
