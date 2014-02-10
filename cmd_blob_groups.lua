function widget:GetInfo()
	return {
		name	= "Blob Groups",
		desc	= "keeps groups together and doing semi-intelligent things",
		author  = "zoggop",
		date 	= "February 2014",
		license	= "whatever",
		layer 	= 0,
		enabled	= true,
		handler = true,
	}
end



-- LOCAL DEFINITIONS

local sqrt = math.sqrt
local random = math.random
local pi = math.pi
local halfPi = pi / 2
local twicePi = pi * 2
local cos = math.cos
local sin = math.sin
local atan2 = math.atan2
local abs = math.abs
local max = math.max
local min = math.min
local ceil = math.ceil

local drawIndicators = true
local mapBuffer = 32

local blobs = {}
local groupsByID = {}
local unitsByID = {}
local infosByDefID = {}
local widgetCommands = {}
local lastCalcFrame = 0
local blobCount = 0

local circleTex = "LuaUI/Images/blobguard/circle.png"

local sizeX = Game.mapSizeX
local sizeZ = Game.mapSizeZ
local bufferedSizeX = sizeX - mapBuffer
local bufferedSizeZ = sizeZ - mapBuffer

-- commands that the group receives
local interruptCmd = {
	[0] = true,
	[10] = true,
	[15] = true,
	[16] = true,
	[20] = true,
	[21] = true,
	[25] = true,
	[40] = true,
	[90] = true,
	[125] = true,
	[130] = true,
}


--- LOCAL FUNCTIONS

local function ConstrainToMap(x, z)
	x = max(min(x, bufferedSizeX), mapBuffer)
	z = max(min(z, bufferedSizeZ), mapBuffer)
	return x, z
end

local function RandomAway(x, z, dist, angle)
	if angle == nil then angle = random() * twicePi end
	local nx = x + dist * cos(angle)
	local nz = z - dist * sin(angle)
	return ConstrainToMap(nx, nz)
end

local function Distance(x1, z1, x2, z2)
	local xd = x1 - x2
	local zd = z1 - z2
	return sqrt(xd*xd + zd*zd)
end

local function ApplyVector(x, z, vx, vz, frames)
	if frames == nil then frames = 30 end
	return ConstrainToMap(x + (vx *frames), z + (vz * frames))
end

local function ManhattanDistance(x1, z1, x2, z2)
	local xd = abs(x1 - x2)
	local yd = abs(z1 - z2)
	return xd + yd
end

local function Pythagorean(a, b)
	return sqrt((a^2) + (b^2))
end

local function AngleDist(angle1, angle2)
	return abs((angle1 + 180 -  angle2) % 360 - 180)
	-- Spring.Echo(math.floor(angleDist * 57.29), math.floor(high * 57.29), math.floor(low * 57.29))
end

local function AngleAtoB(x1, z1, x2, z2)
	local dx = x2 - x1
	local dz = z2 - z1
	return atan2(-dz, dx)
end

local function GetLongestWeaponInfo(unitDef)
	local weapon
	local highestDPS = 0
	local weapons = unitDef["weapons"]
	local death = unitDef.deathExplosion
	for i=1, #weapons do
		local weaponDefID = weapons[i]["weaponDef"]
		local weaponDef = WeaponDefs[weaponDefID]
		local damages = weaponDef["damages"]
		local damage = 0
		local reload = weaponDef["reload"]
		for i, d in pairs(damages) do
			if d > damage then damage = d end
		end
		local dps = damage / reload
		if weaponDef["name"] ~= death and dps > highestDPS then
			weapon = weaponDef
			highestDPS = dps
		end
	end
	if weapon then
		local range = weapon["range"]
		local reload = weapon["reload"]
		local velocity = weapon["projectilespeed"] or 0
		local hightrajectory = weapon["highTrajectory"]
		local air = not weapon["canAttackGround"]
		return range, reload, highestDPS, velocity, hightrajectory, air
	else
		return 0, 0, 0, 0
	end
end
local function GetUnitDefInfo(defID)
	if infosByDefID[defID] then return infosByDefID[defID] end
	local uDef = UnitDefs[defID]
	local x = uDef.xsize * 8
	local z = uDef.zsize * 8
	local size = ceil(Pythagorean(x, z))
	local area = x * z
	local range, reload, dps, velocity, hightrajectory, air = GetLongestWeaponInfo(uDef)
	local ratio = (((uDef.health / 10) + uDef.speed + dps + (velocity*2)) / uDef.metalCost) - (range * 0.001) - (reload * 0.15)
	-- Spring.Echo(uDef.humanName, ratio, velocity, hightrajectory, air)
	local isCombatant = ratio > 0.2 and hightrajectory ~= 1 and not air and uDef.canAttack and not uDef.canFly and not uDef.canAssist and not uDef.canRepair
	local info = { isBuilder = #uDef.buildOptions ~= 0, isCombatant = isCombatant, speed = uDef.speed, size = size, area = area, range = range, canMove = uDef.canMove, canAttack = uDef.canAttack, canAssist = uDef.canAssist, canRepair = uDef.canRepair, canFly = uDef.canFly }
	infosByDefID[defID] = info
	return info
end

local function SameCommands(cmd1, cmd2)
	if cmd1.cmdID == cmd2.cmdID then
		local paramsMatch = true
		for pi, param in pairs(cmd1.cmdParams) do
			if cmd2.cmdParams[pi] ~= param then
				paramsMatch = false
				break
			end
		end
		if paramsMatch then
			return true
		end
	end
	return false
end

local function GiveCommand(unitID, cmdID, cmdParams)
	local command = Spring.GiveOrderToUnit(unitID, cmdID, cmdParams, {})
	if command == true then
		local cmd = { unitID = unitID, cmdID = cmdID, cmdParams = cmdParams }
		table.insert(widgetCommands, cmd)
		local unit = unitsByID[unitID]
		if unit then
			if (cmdID == CMD.GUARD or cmdID == CMD.REPAIR) and #cmdParams == 1 then
				unit.targetID = cmdParams[1] -- what is it guarding or repairing
			else
				unit.targetID = nil -- unit has no target
			end
		end
	end
end

local function CloneOrder(unitID, order)
	GiveCommand(unitID, order.cmdID, order.cmdParams)
end

local function SetMoveState(unit, moveState)
	if unit.moveState ~= moveState then
		Spring.GiveOrderToUnit(unit.unitID, CMD.MOVE_STATE, {moveState}, {})
		unit.moveState = moveState
	end
end

local function CreateUnit(unitID)
	local states = Spring.GetUnitStates(unitID)
	local unit = { unitID = unitID, unitDefID = Spring.GetUnitDefID(unitID), initialMoveState = states["movestate"], moveState = states["movestate"] }
	unitsByID[unitID] = unit
	return unit
end

local function ClearBlob(groupID)
	blobs[groupID] = nil
	blobCount = blobCount - 1
end

local function ClearUnit(unitID)
	local unit = unitsByID[unitID]
	if not unit then return false end
	local groupID = Spring.GetUnitGroup(unitID)
	local blob = blobs[groupID]
	if blob then
		if unit.angle then blob.needSlotting = true end
	end
	Spring.GiveOrderToUnit(unit.unitID, CMD.MOVE_STATE, {unit.initialMoveState}, {})
	unitsByID[unitID] = nil
end

local function CreateBlob(groupID)
	if blobs[groupID] then return end
	local blob = { groupID = groupID, guardDistance = 100, speed = 0 }
	blobs[groupID] = blob
	blobCount = blobCount + 1
end

local function EvaluateUnits(blob, gameFrame)
	blob.needsAssist = {}
	blob.needsRepair = {}
	blob.humanOrderCount = 0
	blob.unitCount = 0
	blob.lowestInteriorSpeed = 0
	blob.interiorArea = 0
	local firstOrder
	local ordersAgree = true
	local interiorUnitCount = 0
	local maxSizeInterior = 0
	local minSpeedInterior = 1000
	local minX = 100000
	local maxX = -100000
	local minZ = 100000
	local maxZ = -100000
	local totalVX = 0
	local totalVZ = 0
	local maxVectorSize = 0
	local groupID = blob.groupID
	local sortedUnits = Spring.GetGroupUnitsSorted(blob.groupID)
	-- first just check if there are any noncombatants at all
	blob.hasNoncombatants = false
	for unitDefID, units in pairs(sortedUnits) do
		local info = GetUnitDefInfo(unitDefID)
		if not info.isCombatant then
			blob.hasNoncombatants = true
			break
		end
	end
	for unitDefID, units in pairs(sortedUnits) do
		local info = GetUnitDefInfo(unitDefID)
		for i, unitID in pairs(units) do
			local unit = unitsByID[unitID] or CreateUnit(unitID)
			if unit.humanOrder then
				blob.humanOrderCount = blob.humanOrderCount + 1
				if ordersAgree then
					if not firstOrder then
						firstOrder = unit.humanOrder
					elseif not SameCommands(firstOrder, unit.humanOrder) then
						ordersAgree = false
					end
				end
			end
			if unit.underFire then
				-- unit is no longer under fire after 5 seconds
				if gameFrame > unit.underFire + 150 then unit.underFire = nil end
				if blob.underFire and unit.underFire then
					if unit.underFire > blob.underFire then blob.underFire = unit.underFire end
				else
					blob.underFire = unit.underFire
				end
			end
			if info.isBuilder then
				unit.constructing = nil
				if unit.humanOrder then
					if unit.humanOrder.cmdID < 0 then unit.constructing = true end
				end
				if not unit.constructing then unit.constructing = Spring.GetUnitIsBuilding(unitID) end
				if unit.constructing then table.insert(blob.needsAssist, unitID) end
			end
			local health, maxHealth = Spring.GetUnitHealth(unitID)
			unit.damaged = health < maxHealth
			if unit.damaged then table.insert(blob.needsRepair, unitID) end
			local probablyWillSlot = info.isCombatant and info.speed > blob.speed
			if blob.hasNoncombatants and not unit.interiorize and (unit.angle or unit.willSlot or probablyWillSlot) then
				-- for units on the exterior
			else
				-- for units on the interior
				if info.size > maxSizeInterior then maxSizeInterior = info.size end
				if info.speed < minSpeedInterior then minSpeedInterior = info.speed end
				blob.interiorArea = blob.interiorArea + info.area
				local ux, uy, uz = Spring.GetUnitPosition(unitID)
				if ux > maxX then maxX = ux end
				if ux < minX then minX = ux end
				if uz > maxZ then maxZ = uz end
				if uz < minZ then minZ = uz end
				local vx, vy, vz = Spring.GetUnitVelocity(unitID)
				totalVX = totalVX + vx
				totalVZ = totalVZ + vz
				local vectorSize = Pythagorean(vx, vz)
				if vectorSize > maxVectorSize then maxVectorSize = vectorSize end
				interiorUnitCount = interiorUnitCount + 1
			end
			blob.unitCount = blob.unitCount + 1
			unit.interiorize = nil
		end
	end
	blob.idealRadius = sqrt(blob.interiorArea / pi)
	blob.vx = totalVX / interiorUnitCount
	blob.vz = totalVZ / interiorUnitCount
	blob.vectorAngle = atan2(-blob.vz, blob.vx)
	blob.speed = maxVectorSize * 30
	blob.lowestInteriorSpeed = minSpeedInterior
	local dx = maxX - minX
	local dz = maxZ - minZ
	blob.radius = (Pythagorean(dx, dz) / 2) + (maxSizeInterior / 2)
	blob.x = (maxX + minX) / 2
	blob.z = (maxZ + minZ) / 2
	blob.preVectorX, blob.preVectorZ = blob.x, blob.z
	blob.x, blob.z = ApplyVector(blob.x, blob.z, blob.vx, blob.vz)
	blob.y = Spring.GetGroundHeight(blob.x, blob.z)
	-- get blob target from orders given
	if ordersAgree and firstOrder and blob.humanOrderCount > 1 then
		blob.humanOrder = firstOrder
		local tx, ty, tz
		local cmdParams = blob.humanOrder.cmdParams
		if #cmdParams == 1 then
			tx, ty, tz = Spring.GetUnitPosition(cmdParams[1])
		elseif #cmdParams == 3 or #cmdParams == 4 then
			tx, ty, tz = cmdParams[1], cmdParams[2], cmdParams[3]
		end
		blob.tx, blob.ty, blob.tz = tx, ty, tz
		blob.targetDistance = Distance(blob.x, blob.z, tx, tz)
	else
		blob.tx, blob.ty, blob.tz, blob.targetDistance = nil, nil, nil, nil
	end
end

local function SortUnits(blob)
	blob.ordersByDef = {}
	blob.hasHumanOrder = {}
	blob.willSlot = {}
	blob.slotted = {}
	blob.willAssist = {}
	blob.willRepair = {}
	blob.willGuard = {}
	blob.willWait = {}
	blob.willResume = {}
	local humanOrdersLeft = blob.humanOrderCount + 0
	local distanceCutOff = blob.radius + (blob.guardDistance * 3)
	local waitDistance = blob.idealRadius
	local sortedUnits = Spring.GetGroupUnitsSorted(blob.groupID)
	for unitDefID, units in pairs(sortedUnits) do
		local info = GetUnitDefInfo(unitDefID)
		for i, unitID in pairs(units) do
			local unit = unitsByID[unitID]
			unit.willSlot = false
			if unit then
				local target = unitsByID[unit.targetID]
				unit.interiorize = unit.humanOrder and humanOrdersLeft <= 1
				local exterior = blob.hasNoncombatants and info.isCombatant and info.speed > blob.speed and not unit.interiorize
				if (not unit.humanOrder and not unit.constructing) or (exterior and blob.humanOrder and humanOrdersLeft > 1) then
					if exterior then
						if unit.humanOrder then
							humanOrdersLeft = humanOrdersLeft - 1
							unit.humanOrder = nil
						end
						local gx, gy, gz = Spring.GetUnitPosition(unitID)
						unit.x, unit.y, unit.z = gx, gy, gz
						-- Spring.Echo(blob.x, blob.z, blob.vx, blob.vz, gx, gz, unitID)
						local dist = Distance(blob.x, blob.z, gx, gz)
						if dist > distanceCutOff then
							table.insert(blob.willGuard, unit)
							SetMoveState(unit, 0)
							if unit.angle then blob.needSlotting = true end
							unit.angle = nil
						else
							if unit.angle then
								table.insert(blob.slotted, unit)
							else
								blob.needSlotting = true
								unit.willSlot = true
								table.insert(blob.willSlot, unit)
							end
							if blob.underFire then
								SetMoveState(unit, 2)
							else
								SetMoveState(unit, 1)
							end
						end
					else
						if unit.angle then
							blob.needSlotting = true
							unit.angle = nil
						end
						if info.canRepair and #blob.needsRepair > 0 then
							local repair = true
							if target then
								if target.damaged then repair = false end
							end
							if repair then table.insert(blob.willRepair, unit) end
						elseif info.canAssist and #blob.needsAssist > 0 then
							local assist = true
							if target then
								if target.constructing then assist = false end
							end
							if assist then table.insert(blob.willAssist, unit) end
						else
							if not target then
								table.insert(blob.willGuard, unit)
							elseif not target.constructing and not target.damaged then
								table.insert(blob.willGuard, unit)
							end
						end
					end
				else
					if unit.angle then
						blob.needSlotting = true
						unit.angle = nil
					end
					if unit.humanOrder then
						-- store order for others of this unit def to follow
						if interruptCmd[unit.humanOrder.cmdID] then
							blob.ordersByDef[unitDefID] = unit.humanOrder
						end
						if info.isCombatant and info.speed > blob.lowestInteriorSpeed then
							-- make fast combat units wait for others if necessary
							local stop = false
							if blob.tx and blob.humanOrder then
								-- check if unit needs to stop to wait for others to catch up
								-- or if it needs to resume after waiting
								local x, y, z = Spring.GetUnitPosition(unit.unitID)
								unit.x, unit.y, unit.z = x, y, z
								local dist = Distance(blob.tx, blob.tz, x, z)
								if dist < blob.targetDistance - waitDistance then
									stop = true
								end
							end
							if stop then
								if not unit.stopped then
									table.insert(blob.willWait, unit)
								end
								table.insert(blob.hasHumanOrder, unit)
							else
								if unit.stopped then
									if SameCommands(unit.humanOrder, blob.humanOrder) then
										table.insert(blob.willResume, unit)
										table.insert(blob.hasHumanOrder, unit)
									else
										table.insert(blob.willGuard, unit)
										unit.stopped = nil
										unit.humanOrder = nil
									end
								else
									table.insert(blob.hasHumanOrder, unit)
								end
							end
						elseif blob.tx and blob.humanOrder and humanOrdersLeft > 1 and info.speed > blob.lowestInteriorSpeed then
							table.insert(blob.willGuard, unit)
							unit.humanOrder = nil
							humanOrdersLeft = humanOrdersLeft - 1
						else
							table.insert(blob.hasHumanOrder, unit)
						end
					end
				end
			end
		end
	end
end

local function SlotUnit(unit, blob, ax, az, guardDist)
	local info = GetUnitDefInfo(unit.unitDefID)
	blob.guardCircumfrence = blob.guardCircumfrence + info.size
	local attacking
	local cmdQueue = Spring.GetUnitCommands(unit.unitID, 1)
	if cmdQueue[1] then
		if cmdQueue[1].id == CMD.ATTACK then attacking = true end
	end
	local maxDist = info.size * 0.5
	if attacking then
		if blob.underFire then
			maxDist = ((info.range * 0.5) + info.speed) * 0.5
		else
			maxDist = ((info.range * 0.5) + info.speed)
		end
	end
	-- move into position if needed
	if guardDist == nil then guardDist = blob.radius + blob.guardDistance end
	if ax == nil then ax, az = RandomAway(blob.x, blob.z, guardDist, unit.angle) end
	local slotDist = Distance(unit.x, unit.z, ax, az)
	if slotDist > maxDist then
		local ay = Spring.GetGroundHeight(ax, az)
		GiveCommand(unit.unitID, CMD.MOVE, {ax, ay, az})
	end
end

local function AssignCombat(blob)
	-- find angle slots if needed and move units to them
	local divisor = #blob.slotted + #blob.willSlot
	if divisor > 0 then
		if divisor < 3 and (blob.lastVX ~= blob.vx or blob.lastVZ ~= blob.vz) then blob.needSlotting = true end -- one or two guards should unit in front of unit first
		local angleAdd, angle
		if blob.needSlotting then
			-- if we need to result, get a starting angle and division
			angleAdd = twicePi / divisor
			if divisor < 3 and blob.speed > 0 then 
				 -- one or two guards should unit in front of unit first
				angle = blob.vectorAngle
				blob.lastAngle = angle
			elseif blob.lastAngle then
				angle = blob.lastAngle
			elseif #blob.slotted > 0 then
				-- grab an angle from an already slotted unit
				angle = blob.slotted[1].angle
				blob.lastAngle = angle
			elseif blob.willSlot[1].x then
				-- angle from a unit's position
				angle = AngleAtoB(blob.x, blob.z, blob.willSlot[1].x, blob.willSlot[1].z)
			else
				-- random angle
				angle = random() * twicePi
				blob.lastAngle = angle
			end
		end
		local guardDist = blob.radius + blob.guardDistance
		if blob.underFire then guardDist = blob.radius + (blob.guardDistance * 0.5) end
		blob.guardCircumfrence = 0
		local emptyAngles = {}
		-- calculate all angles and assign to unslotted first
		for i = 1, divisor do
			local unit
			local ax, az
			if blob.needSlotting then
				-- if we need to reslot, find the nearest unslotted unit to this angle
				local a = angle + (angleAdd * (i - 1))
				if a > twicePi then a = a - twicePi end
				if #blob.willSlot > 0 then
					ax, az = RandomAway(blob.x, blob.z, guardDist, a)
					local leastDist = 10000
					local bestGuard = 1
					for gi, g in pairs(blob.willSlot) do
						local dist = Distance(g.x, g.z, ax, az)
						if dist < leastDist then
							leastDist = dist
							bestGuard = gi
						end
					end
					unit = table.remove(blob.willSlot, bestGuard)
					unit.angle = a
				else
					table.insert(emptyAngles, a)
				end
			else
				unit = table.remove(blob.slotted)
			end
			if unit ~= nil then SlotUnit(unit, blob, ax, az, guardDist) end
		end
		-- assign the rest to already slotted
		for i, a in pairs(emptyAngles) do
			local ax, az = RandomAway(blob.x, blob.z, guardDist, a)
			local leastDist = 10000
			local bestGuard = 1
			for gi, g in pairs(blob.slotted) do
				local angleDist = AngleDist(g.angle, a)
				local dist = 2 * abs(sin(angleDist / 2)) * guardDist
				if dist < leastDist then
					leastDist = dist
					bestGuard = gi
				end
			end
			local unit = table.remove(blob.slotted, bestGuard)
			unit.angle = a
			if unit ~= nil then SlotUnit(unit, blob, ax, az, guardDist) end
		end
		blob.guardDistance = max(100, ceil(blob.guardCircumfrence / 7.5))
	end
	blob.needSlotting = false
end

local function AssignAssist(blob)
	if #blob.needsAssist == 0 or #blob.willAssist == 0 then return end
	local quota = 1
	if #blob.needsAssist == 1 then
		quota = #blob.willAssist
	else
		quota = math.floor(#blob.needsAssist / #blob.willAssist)
	end
	for ti, unitID in pairs(blob.needsAssist) do
		if ti == #blob.needsAssist then quota = #blob.willAssist end
		for i = 1, quota do
			local unit = table.remove(blob.willAssist)
			GiveCommand(unit.unitID, CMD.GUARD, {unitID})
		end
		if #blob.willAssist == 0 then break end
	end
end

local function AssignRepair(blob)
	if #blob.needsRepair == 0 or #blob.willRepair == 0 then return end
	local quota = 1
	if #blob.needsRepair == 1 then
		quota = #blob.willRepair
	else
		quota = math.floor(#blob.needsRepair / #blob.willRepair)
	end
	for ti, unitID in pairs(blob.needsRepair) do
		if ti == #blob.needsRepair then quota = #blob.willRepair end
		for i = 1, quota do
			local unit = table.remove(blob.willRepair)
			if unit then
				GiveCommand(unit.unitID, CMD.REPAIR, {unitID})
			end
		end
		if #blob.willRepair == 0 then break end
	end
end

local function AssignWait(blob)
	for ui, unit in pairs(blob.willWait) do
		GiveCommand(unit.unitID, CMD.STOP, {})
		unit.stopped = true
	end
end

local function AssignResume(blob)
	for ui, unit in pairs(blob.willResume) do
		CloneOrder(unit.unitID, unit.humanOrder)
		unit.stopped = false
	end
end


local function AssignRemaining(blob)
	if #blob.willGuard == 0 then return end
	for ui, unit in pairs(blob.willGuard) do
		local order = blob.ordersByDef[unit.unitDefID]
		if order ~= nil then
			CloneOrder(unit.unitID, order)
		else
			local unitID
			if #blob.hasHumanOrder == 0 then
				if #blob.willGuard > 1 then
					for ti = 1, #blob.willGuard do
						local target = blob.willGuard[ti]
						if target ~= unit then
							unitID = target.unitID
							break
						end
					end
				end
			else
				local ti = random(1, #blob.hasHumanOrder)
				unitID = blob.hasHumanOrder[ti].unitID
			end
			if unitID then GiveCommand(unit.unitID, CMD.GUARD, {unitID}) end
		end
	end
end


-- SPRING CALLINS

function widget:Initialize()
	-- make sure we start with all the groups registered
	local groups = Spring.GetGroupList()
	for groupID, unitCount in pairs(groups) do
		CreateBlob(groupID)
	end
end

function widget:GroupChanged(groupID)
	local count = Spring.GetGroupUnitsCount(groupID)
	if count == 0 then
		ClearBlob(groupID)
	else
		CreateBlob(groupID) -- only creates if it's not already
	end
end

function widget:UnitCommand(unitID, unitDefID, unitTeam, cmdID, cmdOpts, cmdParams, cmdTag)
	if not interruptCmd[cmdID] and cmdID >= 0 then return end
	-- check if this unit is in a group
	local unit = unitsByID[unitID]
	if not unit then return end
	-- check if this is a command issued from this widget
	for ci, cmd in pairs(widgetCommands) do
		if unitID == cmd.unitID and cmdID == cmd.cmdID then
			local paramsMatch = true
			for pi, param in pairs(cmdParams) do
				if cmd.cmdParams[pi] ~= param then
					paramsMatch = false
					break
				end
			end
			if paramsMatch then
				table.remove(widgetCommands, ci)
				return
			end
		end
	end
	-- below is not a widget command
	unit.humanOrder = { cmdID = cmdID, cmdParams = cmdParams, cmdOpts = cmdOpts }
	unit.stopped = nil
end

function widget:UnitIdle(unitID, unitDefID, teamID)
	local unit = unitsByID[unitID]
	if not unit then return end
	if not unit.stopped then unit.humanOrder = nil end
end

function widget:UnitMoveFailed(unitID, unitDefID, unitTeam)
	widget:UnitIdle(unitID, unitDefID, unitTeam)
end

function widget:UnitCreated(unitID, unitDefID, teamID, builderID)
	local unit = unitsByID[builderID]
	if not unit then return end
	local register = false
	if unit.humanOrder then
		if unit.humanOrder.cmdID ~= -unitDefID then
			register = true
		end
	else
		register = true
	end
	if register then unit.humanOrder = { cmdID = -unitDefID, cmdParams = { unitID, unitDefID }, cmdOpts = {} } end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID, attackerID, attackerDefID, attackerTeamID)
	ClearUnit(unitID)
end

function widget:UnitTaken(unitID, unitDefID, unitTeam, newTeam)
	ClearUnit(unitID)
end

function widget:GameFrame(gameFrame)
	if gameFrame % 30 == 0 then
		-- check for changes in units from group to group or removed from group
		for unitID, unit in pairs(unitsByID) do
			local groupID = Spring.GetUnitGroup(unitID)
			if groupID ~= unit.lastGroupID and unit.angle then
				local blob = blobs[unit.lastGroupID]
				if blob then blob.needSlotting = true end
				unit.angle = nil
			end
			if groupID == nil then ClearUnit(unitID) end
			unit.lastGroupID = groupID
		end
		for groupID, blob in pairs(blobs) do
			local unitCount = Spring.GetGroupUnitsCount(groupID)
			if unitCount > 1 then
				if blob.underFire then
					-- blob is no longer under fire after 5 seconds
					if gameFrame > blob.underFire + 150 then blob.underFire = nil end
				end
				EvaluateUnits(blob, gameFrame) -- find blob speed, position, radius and who needs what
				SortUnits(blob) -- dole out who will do what
				AssignCombat(blob) -- put combatant guards into circle slots
				AssignAssist(blob)
				AssignRepair(blob)
				AssignWait(blob)
				AssignResume(blob)
				AssignRemaining(blob)
				blob.lastVX = blob.vx
				blob.lastVZ = blob.vz
				if blob.radius and blob.lastRadius then
					blob.expansionRate = (blob.radius - blob.lastRadius) / 30
				end
				blob.lastRadius = blob.radius + 0
			end
		end
		lastCalcFrame = gameFrame
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	local unit = unitsByID[unitID]
	if unit then unit.underFire = Spring.GetGameFrame() end
end

function widget:DrawWorldPreUnit()
	if not drawIndicators then return end
	if blobCount == 0 then return end
	local alt, ctrl, meta, shift = Spring.GetModKeyState()
	if not shift then return end
	local gameFrame = Spring.GetGameFrame()
	local framesSince = gameFrame - lastCalcFrame
	local divisor = 60 - framesSince
	gl.PushMatrix()
	-- gl.DepthTest(true)
	gl.Texture(circleTex)
	gl.Color(0, 0, 1, 0.25)
	for groupID, blob in pairs(blobs) do
		if blob.x and blob.vx and blob.radius then
			if Spring.IsSphereInView(blob.x, blob.y, blob.z, blob.radius) then
				if blob.lastDrawFrame then
					if blob.lastDrawFrame + 10 < gameFrame then
						blob.displayX = nil
						blob.displayZ = nil
						blob.displayRadius = nil
					end
				end
				local x, z
				if blob.displayX then
					local adjustmentX = (blob.x - blob.displayX) / divisor
					local adjustmentZ = (blob.z - blob.displayZ) / divisor
					x, z = ApplyVector(blob.displayX, blob.displayZ, adjustmentX, adjustmentZ, 1)
				else
					x, z = ApplyVector(blob.preVectorX, blob.preVectorZ, blob.vx, blob.vz, framesSince)
				end
				local y = Spring.GetGroundHeight(x, z)
				local radius
				if blob.displayRadius then
					local adjustment = (blob.radius - blob.displayRadius) / divisor
					radius = blob.displayRadius + adjustment
				else
					radius = blob.radius
				end
				local sx, sy, sz = Spring.WorldToScreenCoords(x, y, z)
				local sx1, sy1, sz1
				local screenX, screenY = Spring.GetScreenGeometry()
				if sx < screenX / 2 then
					sx1, sy1, sz1 = Spring.WorldToScreenCoords(x+radius, y, z-radius)
				else
					sx1, sy1, sz1 = Spring.WorldToScreenCoords(x-radius, y, z-radius) -- so it doesn't squish at the right screen edge
				end
				local srx = abs(sx1 - sx)
				local sry = (sy1 - sy)
				local yRad = (sry / srx) * radius
				gl.Translate(x,y,z)
				gl.Billboard()			
				gl.TexRect(-radius,-yRad,radius,yRad)
				blob.displayRadius = radius
				blob.displayX, blob.displayZ = x, z
				blob.lastDrawFrame = gameFrame
			end
		end
	end
	gl.Texture(false)
	-- gl.DepthTest(false)
	gl.PopMatrix()
end
