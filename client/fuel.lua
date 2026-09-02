local config = require 'config'
local state = require 'client.state'
local utils = require 'client.utils'
local fuel = {}

local nozzleModel = `prop_cs_fuel_nozle`

local function getNearestPump()
    local coords = GetEntityCoords(cache.ped)
    local closestPump
    local closestDistance

    for i = 1, #config.pumpModels do
        local pump = GetClosestObjectOfType(
            coords.x,
            coords.y,
            coords.z,
            3.0,
            config.pumpModels[i],
            false,
            false,
            false
        )

        if pump ~= 0 then
            local distance = #(coords - GetEntityCoords(pump))

            if not closestDistance or distance < closestDistance then
                closestPump = pump
                closestDistance = distance
            end
        end
    end

    return closestPump
end

local function createFuelNozzle(pump)
    if not pump or not DoesEntityExist(pump) then return end

    lib.requestModel(nozzleModel)

    local nozzle = CreateObject(
        nozzleModel,
        0.0,
        0.0,
        0.0,
        true,
        true,
        false
    )

    AttachEntityToEntity(
        nozzle,
        cache.ped,
        GetPedBoneIndex(cache.ped, 0x49D9),
        0.11,
        0.02,
        0.02,
        -80.0,
        -90.0,
        15.0,
        true,
        true,
        false,
        true,
        1,
        true
    )

    SetModelAsNoLongerNeeded(nozzleModel)

    RopeLoadTextures()

    while not RopeAreTexturesLoaded() do
        Wait(0)
    end

    local pumpCoords = GetEntityCoords(pump)

    local rope = AddRope(
        pumpCoords.x,
        pumpCoords.y,
        pumpCoords.z,
        0.0,
        0.0,
        0.0,
        3.0,
        1,
        1000.0,
        0.0,
        1.0,
        false,
        false,
        false,
        1.0,
        true
    )

    ActivatePhysics(rope)

    Wait(50)

    local nozzleCoords = GetOffsetFromEntityInWorldCoords(
        nozzle,
        0.0,
        -0.033,
        -0.195
    )

    AttachEntitiesToRope(
        rope,
        pump,
        nozzle,
        pumpCoords.x,
        pumpCoords.y,
        pumpCoords.z + 1.45,
        nozzleCoords.x,
        nozzleCoords.y,
        nozzleCoords.z,
        5.0,
        false,
        false,
        nil,
        nil
    )

    return nozzle, rope
end

local function deleteFuelNozzle(nozzle, rope)
    if nozzle and DoesEntityExist(nozzle) then
        DeleteEntity(nozzle)
    end

    if rope then
        DeleteRope(rope)
    end

    RopeUnloadTextures()
end

---@param vehState StateBag
---@param vehicle integer
---@param amount number
---@param replicate? boolean
function fuel.setFuel(vehState, vehicle, amount, replicate)
	if DoesEntityExist(vehicle) then
		amount = math.clamp(amount, 0, 100)

		SetVehicleFuelLevel(vehicle, amount)
		vehState.fuel = amount

		if replicate and NetworkGetEntityIsNetworked(vehicle) then TriggerServerEvent('ox_fuel:setFuel', amount) end
	end
end

function fuel.getPetrolCan(coords, refuel)
	TaskTurnPedToFaceCoord(cache.ped, coords.x, coords.y, coords.z, config.petrolCan.duration)
	Wait(500)

	if lib.progressCircle({
			duration = config.petrolCan.duration,
			useWhileDead = false,
			canCancel = true,
			disable = {
				move = true,
				car = true,
				combat = true,
			},
			anim = {
				dict = 'timetable@gardener@filling_can',
				clip = 'gar_ig_5_filling_can',
				flags = 49,
			}
		}) then
		if refuel and exports.ox_inventory:GetItemCount('WEAPON_PETROLCAN') then
			return TriggerServerEvent('ox_fuel:fuelCan', true, config.petrolCan.refillPrice)
		end

		TriggerServerEvent('ox_fuel:fuelCan', false, config.petrolCan.price)
	end

	ClearPedTasks(cache.ped)
end

function fuel.startFueling(vehicle, isPump)
	local vehState = Entity(vehicle).state
	local fuelAmount = vehState.fuel or GetVehicleFuelLevel(vehicle)
	local duration = math.ceil((100 - fuelAmount) / config.refillValue) * config.refillTick
	local price, moneyAmount
	local durability = 0

	if 100 - fuelAmount < config.refillValue then
		return lib.notify({ type = 'error', description = locale('tank_full') })
	end

	if isPump then
		price = 0
		moneyAmount = utils.getMoney()

		if config.priceTick > moneyAmount then
			return lib.notify({
				type = 'error',
				description = locale('not_enough_money', config.priceTick)
			})
		end
	elseif not state.petrolCan then
		return lib.notify({ type = 'error', description = locale('petrolcan_not_equipped') })
	elseif state.petrolCan.metadata.ammo <= config.durabilityTick then
		return lib.notify({
			type = 'error',
			description = locale('petrolcan_not_enough_fuel')
		})
	end

	state.isFueling = true

	TaskTurnPedToFaceEntity(cache.ped, vehicle, duration)
	Wait(500)

	local nozzle
	local rope

	if isPump then
		local pump = getNearestPump()

		if not pump then
			state.isFueling = false

			return lib.notify({
				type = 'error',
				description = 'Fuel pump not found.'
			})
		end

		nozzle, rope = createFuelNozzle(pump)
	end

	CreateThread(function()
		lib.progressCircle({
			duration = duration,
			useWhileDead = false,
			canCancel = true,
			disable = {
				move = true,
				car = true,
				combat = true,
			},
			anim = {
				dict = isPump and 'timetable@gardener@filling_can' or 'weapon@w_sp_jerrycan',
				clip = isPump and 'gar_ig_5_filling_can' or 'fire',
			} or nil,
		})

		state.isFueling = false
	end)

	while state.isFueling do
		if isPump then
			price += config.priceTick

			if price + config.priceTick >= moneyAmount and lib.progressActive() then
				lib.cancelProgress()
			end
		elseif state.petrolCan then
			durability += config.durabilityTick

			if durability >= state.petrolCan.metadata.ammo then
				lib.cancelProgress()
				durability = state.petrolCan.metadata.ammo
				break
			end
		else
			break
		end

		fuelAmount += config.refillValue

		if fuelAmount >= 100 then
			state.isFueling = false
			fuelAmount = 100.0
		end

		Wait(config.refillTick)
	end

	ClearPedTasks(cache.ped)

	if isPump then
		deleteFuelNozzle(nozzle, rope)

		TriggerServerEvent(
			'ox_fuel:pay',
			price,
			fuelAmount,
			NetworkGetNetworkIdFromEntity(vehicle)
		)
	else
		TriggerServerEvent(
			'ox_fuel:updateFuelCan',
			durability,
			NetworkGetNetworkIdFromEntity(vehicle),
			fuelAmount
		)
	end
end

return fuel
