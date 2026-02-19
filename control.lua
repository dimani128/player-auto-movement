script.on_init(function()
	storage.moving_players = {}
end)

local input_directions = {
	["move-up"] = defines.direction.north,
	["move-right"] = defines.direction.east,
	["move-down"] = defines.direction.south,
	["move-left"] = defines.direction.west,
}

local path_requests = {}

script.on_event("movement-tool-input", function(event)
	local player = game.players[event.player_index]
	if not player or not player.valid then
		return
	end

	player.clear_cursor()
	player.cursor_stack.set_stack({ name = "movement-tool", count = 1 })
	player.cursor_stack_temporary = true
end)

script.on_event(defines.events.on_player_selected_area, function(event)
	if event.item == "movement-tool" then
		local player = game.players[event.player_index]
		if not player or not player.valid then
			return
		end

		local player_character = player.character
		if not player_character or not player_character.valid then
			return
		end

		local player_pos = { x = player_character.position.x, y = player_character.position.y }
		local target_pos
		if event.area and event.area.left_top then
			target_pos = {
				x = (event.area.left_top.x + event.area.right_bottom.x) / 2,
				y = (event.area.left_top.y + event.area.right_bottom.y) / 2,
			}
		elseif event.area and event.area[1] then
			target_pos = { x = event.area[1].x, y = event.area[1].y }
		else
			target_pos = { x = player_pos.x, y = player_pos.y }
		end

		local collision_mask = { -- TODO: fix it pathing through entities
			layers = {
				item = true,
				object = true,
				player = true,
				water_tile = true,
				is_object = true,
				is_lower_object = true,
			},
		}

		local vehicle = player.vehicle
		local pathfind_flags = { cache = false, prefer_straight_paths = true } -- TODO: allowing cache seems to sometimes plan terrible routes

		local path_resolution_modifier = 0
		local max_gap_size = 0

		if vehicle and vehicle.valid then
			if vehicle.type == "car" or vehicle.type == "tank" then
				path_resolution_modifier = 4
			elseif vehicle.type == "spider-vehicle" then
				max_gap_size = 8
			end
		end

		local path_id = player.surface.request_path({
			bounding_box = player_character.bounding_box,
			collision_mask = collision_mask,
			start = player_pos,
			goal = target_pos,
			force = player.force,
			pathfind_flags = pathfind_flags,
			path_resolution_modifier = path_resolution_modifier,
			max_gap_size = max_gap_size,
			entity_to_ignore = player_character,
		})

		if path_id then
			path_requests[path_id] = player.index
			storage.moving_players[player.index] = {
				path_id = path_id,
				path = nil,
				current_waypoint = 1,
				tick_counter = 0,
			}
		else
			player.print("Failed to request path!")
		end
	end
end)

script.on_event(defines.events.on_script_path_request_finished, function(event)
	local player_index = path_requests[event.id]
	if not player_index then
		return
	end

	local player = game.players[player_index]
	if not player or not player.valid then
		path_requests[event.id] = nil
		storage.moving_players[player_index] = nil
		return
	end

	if event.path and #event.path > 1 then
		storage.moving_players[player_index].path = event.path
	else
		player.print("No path found! (reason: " .. (event.reason or "unknown") .. ")")
		storage.moving_players[player_index] = nil
	end

	path_requests[event.id] = nil
end)

local function get_movement_target(player)
	local vehicle = player.vehicle
	if vehicle and vehicle.valid then
		if vehicle.type == "car" or vehicle.type == "tank" then
			return "turning_vehicle", vehicle
		end
	end
	-- spidertron as well
	return "character", player.character
end

-- TODO: needs a complete overhaul
local function apply_vehicle_movement(vehicle, target_direction)
	local current_pos = vehicle.position
	local target_pos = {
		x = current_pos.x + math.cos(target_direction * 0.3927),
		y = current_pos.y + math.sin(target_direction * 0.3927),
	}

	local vehicle_forward = vehicle.orientation * 2 * math.pi
	local target_angle = math.atan2(target_pos.y - current_pos.y, target_pos.x - current_pos.x)
	local angle_diff = target_angle - vehicle_forward
	angle_diff = (angle_diff + math.pi) % (2 * math.pi) - math.pi

	if math.abs(angle_diff) < 0.785 then
		vehicle.riding_state =
			{ acceleration = defines.riding.acceleration.accelerating, direction = defines.riding.direction.straight }
	elseif math.abs(angle_diff) > 2.356 then
		vehicle.riding_state =
			{ acceleration = defines.riding.acceleration.reversing, direction = defines.riding.direction.straight }
	elseif angle_diff > 0 then
		vehicle.riding_state =
			{ acceleration = defines.riding.acceleration.accelerating, direction = defines.riding.direction.right }
	else
		vehicle.riding_state =
			{ acceleration = defines.riding.acceleration.accelerating, direction = defines.riding.direction.left }
	end
end

script.on_event(defines.events.on_tick, function(event)
	storage.moving_players = storage.moving_players or {}

	for player_index, movement_data in pairs(storage.moving_players) do
		local player = game.players[player_index]
		if not player or not player.valid or not player.character or not player.character.valid then
			storage.moving_players[player_index] = nil
			goto continue
		end

		local surface = player.surface
		local target_type, target_entity = get_movement_target(player)

		if movement_data.path and movement_data.current_waypoint > #movement_data.path then
			storage.moving_players[player_index] = nil
			player.print("Movement complete!")
			goto continue
		end

		if movement_data.path and movement_data.current_waypoint <= #movement_data.path then
			local target_pos = movement_data.path[movement_data.current_waypoint].position
			local current_pos = target_entity.position
			local distance = math.sqrt((current_pos.x - target_pos.x) ^ 2 + (current_pos.y - target_pos.y) ^ 2)

			if distance <= 1.0 then
				movement_data.current_waypoint = movement_data.current_waypoint + 1
			end

			local path_color = { 1, 1, 0, 0.5 }
			local waypoints_to_render = { current_pos }

			for i = movement_data.current_waypoint, #movement_data.path do
				table.insert(waypoints_to_render, movement_data.path[i].position)
			end

			for i = 1, #waypoints_to_render - 1 do
				rendering.draw_line({
					color = path_color,
					width = 4,
					from = waypoints_to_render[i],
					to = waypoints_to_render[i + 1],
					surface = surface,
					time_to_live = 1,
					players = { player },
					draw_on_ground = true,
				})
			end

			rendering.draw_circle({
				color = { 0, 1, 0, 0.5 }, -- TODO: alpha doesn't seem to change anything?
				radius = 0.3,
				filled = true,
				target = movement_data.path[#movement_data.path].position,
				surface = surface,
				time_to_live = 1,
				players = { player },
				draw_on_ground = true,
			})
		end

		if
			movement_data.path
			and movement_data.current_waypoint <= #movement_data.path
			and target_entity
			and target_entity.valid
		then
			local target_pos = movement_data.path[movement_data.current_waypoint].position
			local current_pos = target_entity.position
			local dx = target_pos.x - current_pos.x
			local dy = target_pos.y - current_pos.y
			local abs_dx = math.abs(dx)
			local abs_dy = math.abs(dy)
			local threshold = 0.1

			if abs_dx > threshold or abs_dy > threshold then
				local direction

				if abs_dx > threshold and abs_dy > threshold then
					if dx > 0 and dy > 0 then
						direction = defines.direction.southeast
					elseif dx < 0 and dy > 0 then
						direction = defines.direction.southwest
					elseif dx > 0 and dy < 0 then
						direction = defines.direction.northeast
					else
						direction = defines.direction.northwest
					end
				elseif abs_dx > threshold then
					if dx > 0 then
						direction = defines.direction.east
					else
						direction = defines.direction.west
					end
				else
					if dy > 0 then
						direction = defines.direction.south
					else
						direction = defines.direction.north
					end
				end

				if target_type == "character" then
					target_entity.walking_state = { walking = true, direction = direction }
				elseif target_type == "turning_vehicle" then
					apply_vehicle_movement(target_entity, direction)
				end
			end
		end

		::continue::
	end
end)

local function queue_input(event)
	local player_index = event.player_index
	if storage.moving_players[player_index] then
		storage.moving_players[player_index] = nil
		local player = game.players[player_index]
		if player and player.valid then
			player.print("Navigation stopped by player input.")
		end
	end
end

script.on_event({ "move-up", "move-right", "move-down", "move-left" }, queue_input)
script.on_event(defines.events.on_player_driving_changed_state, queue_input)
