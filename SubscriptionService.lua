--[[
-------------------------------------------------------------
Subscription Service is an easy way to set up and handle subscriptions that take Robux. As you may know,
Roblox implemented a new feature that allows developers to create subscriptions for their games, but to use
this feature, they require ID verification and the game must be a certain age. Subscription Service is a good,
easy to use substitute for this as this modules allows developers to set up subscriptions with no complication.
-------------------------------------------------------------

----- API REFERENCE -----

-------------------------------------------------------------
 Settings
-------------------------------------------------------------
 .     Expiration_Check_Rate (number):        Rate (seconds) for checking subscription expirations.
 .     Handle_Subscription_Purchases (bool):  When true, the module handles Developer Product receipts automatically.
 .     Print_Credits (boolean):               Print credits to console on startup.
 .     Product_Handling_Yield (number):       Yield before setting up the ProcessReceipt handler.
 .     Expiring_Soon_Threshold (number):      Days before expiry at which SubscriptionExpiringSoon fires. Default: 3.


-------------------------------------------------------------
 Signals
-------------------------------------------------------------
 .     SubscriptionExpired:
             Fired when a subscription expires or is revoked.
             Args: (Player: Player, Subscription: table)
                   Subscription: { Name: string, PurchaseDate: number }

 .     SubscriptionPurchased:
             Fired when a subscription is granted for the first time.
             Args: (Player: Player, Subscription: table)
                   Subscription: { Name: string, PurchaseDate: number }

 .     SubscriptionRenewed:
             Fired when a stackable subscription is re-granted (renewed).
             Args: (Player: Player, Subscription: table)
                   Subscription: { Name: string, PurchaseDate: number }

 .     SubscriptionExpiringSoon:
             Fired during the expiration check loop when remaining time drops below Expiring_Soon_Threshold.
             Args: (Player: Player, Subscription: table, RemainingSeconds: number)


-------------------------------------------------------------
 Functions — Date / Time Utilities
-------------------------------------------------------------
 .     Module.UnixToDDMMYY(Timestamp: number)
             return: "31/10/2022"

 .     Module.UnixToMMDDYY(Timestamp: number)
             return: "10/31/2022"

 .     Module.UnixToReadableTime(Timestamp: number)
             return: "22:20"  (UTC)

 .     Module.UnixToFullDateTime(Timestamp: number)
             return: "Oct 31, 2025 at 22:20 UTC"


-------------------------------------------------------------
 Functions — Subscription Queries
-------------------------------------------------------------
 .     Module.FetchPlayerSubscriptionData(Player: Player)
             return: { Name: string, UserId: number, ActiveSubscriptions: table } or nil

 .     Module.FetchSubscriptionInfo(SubscriptionName: string)
             return: { Name: string, ProductId: number, Duration: number, Stackable: boolean } or nil

 .     Module.DoesPlayerOwnSubscription(Player: Player, SubscriptionName: string)
             return: true / false

 .     Module.GetSubscriptionExpiration(Player: Player, SubscriptionName: string)
             return: number (Unix timestamp) or nil

 .     Module.GetTimeUntilExpiration(Player: Player, SubscriptionName: string)
             return: { Days: number, Hours: number, Minutes: number, Seconds: number, TotalSeconds: number }

 .     Module.IsSubscriptionExpiringSoon(Player: Player, SubscriptionName: string, ThresholdDays: number?)
             return: true / false

 .     Module.GetAllSubscribedPlayers(SubscriptionName: string)
             return: { Player, ... }  (loaded players only)

 .     Module.GetSubscriptionPurchaseCount(Player: Player, SubscriptionName: string)
             return: number  (lifetime purchase + renewal count)


-------------------------------------------------------------
 Functions — Subscription Management
-------------------------------------------------------------
 .     Module.RegisterSubscription(SubscriptionData: any)        no return
 .     Module.GrantSubscription(Player: Player, SubscriptionName: string)        no return
 .     Module.RevokeSubscription(Player: Player, SubscriptionName: string)       no return
 .     Module.AdjustSubscription(Player: Player, SubscriptionName: string, Days: number)   no return
 .     Module.PauseSubscription(Player: Player, SubscriptionName: string)        no return
 .     Module.ResumeSubscription(Player: Player, SubscriptionName: string)       no return


-------------------------------------------------------------
 Functions — Player Lifecycle
-------------------------------------------------------------
 .     Module.loadPlayer(Player: Player)      no return
 .     Module.unloadPlayer(Player: Player)    no return
-------------------------------------------------------------
]]

-- Services --
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService   = game:GetService("DataStoreService")
local HTTPService        = game:GetService("HttpService")
local Players            = game:GetService("Players")

-- Objects --
local SignalModuleObject   = script.Parent:WaitForChild("GoodSignal")
local DateTimeUtilsObject  = script.Parent:WaitForChild("DateTimeUtils")

-- Modules --
local Signal       = require(SignalModuleObject)
local DateTimeUtils = require(DateTimeUtilsObject)

-- Tables --
local registeredSubscriptions = {}
local productFunctions        = {}

-- DataStores --
local SubscriptionDataStore  = DataStoreService:GetDataStore("uj6rtrtrjursjtrsjtrsxrtj")
local PurchaseCountDataStore = DataStoreService:GetDataStore("SubscriptionPurchaseCounts")

-- Local Functions --
local function toSeconds(Days: number): number
	return Days * 86400
end

local function retryAsync(fn: () -> any, maxAttempts: number): (boolean, any)
	local attempts = 0
	repeat
		attempts += 1
		local success, result = pcall(fn)
		if success then
			return true, result
		end
		if attempts < maxAttempts then
			task.wait(2 ^ (attempts - 1))
		else
			warn("DataStore operation failed after " .. maxAttempts .. " attempts: " .. tostring(result))
		end
	until attempts >= maxAttempts
	return false, nil
end

local function incrementPurchaseCount(UserId: number, SubscriptionName: string)
	local key = tostring(UserId) .. "_" .. SubscriptionName
	retryAsync(function()
		PurchaseCountDataStore:UpdateAsync(key, function(current)
			return (current or 0) + 1
		end)
	end, 3)
end

local function processReceipt(receiptInfo)
	local userId   = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local player   = Players:GetPlayerByUserId(userId)

	if player then
		local handler = productFunctions[productId]

		if not handler then
			warn("No handler registered for product ID:", productId)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local success, result = pcall(handler, receiptInfo, player)

		if success then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		else
			warn("Failed to process receipt:", receiptInfo, result)
		end
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function FindSubscriptionByNameInTable(SubscriptionName: string, Table: {any})
	for i, v in ipairs(Table) do
		if v.Name == SubscriptionName then
			return v, i
		end
	end
	return nil
end

local function FindSubscriptionByName(SubscriptionName: string)
	for _, v in ipairs(registeredSubscriptions) do
		if v.Name == SubscriptionName then
			return v
		end
	end
	return nil
end

local function CheckSubscriptionValidity(Subscription: {any}, Duration: number): boolean
	if Subscription.PausedAt ~= nil then
		return true
	end
	return (Subscription.PurchaseDate + toSeconds(Duration)) > os.time()
end

-- Module --
local SubscriptionModule = {
	Expiration_Check_Rate         = 10,
	Handle_Subscription_Purchases = true,
	Print_Credits                 = true,
	Product_Handling_Yield        = 0.5,
	Expiring_Soon_Threshold       = 3,

	-- DO NOT TOUCH BELOW --
	PlayerSubscriptions = {}
}

SubscriptionModule.SubscriptionExpired      = Signal.new()
SubscriptionModule.SubscriptionPurchased    = Signal.new()
SubscriptionModule.SubscriptionRenewed      = Signal.new()
SubscriptionModule.SubscriptionExpiringSoon = Signal.new()

-- Date / Time Utilities (delegated to DateTimeUtils) --
function SubscriptionModule.UnixToDDMMYY(Timestamp: number): string
	return DateTimeUtils.UnixToDDMMYY(Timestamp)
end

function SubscriptionModule.UnixToMMDDYY(Timestamp: number): string
	return DateTimeUtils.UnixToMMDDYY(Timestamp)
end

function SubscriptionModule.UnixToReadableTime(Timestamp: number): string
	return DateTimeUtils.UnixToReadableTime(Timestamp)
end

function SubscriptionModule.UnixToFullDateTime(Timestamp: number): string
	return DateTimeUtils.UnixToFullDateTime(Timestamp)
end

-- Subscription Queries --
function SubscriptionModule.FetchPlayerSubscriptionData(Player: Player)
	for Index, Value in ipairs(SubscriptionModule.PlayerSubscriptions) do
		if Value.UserId == Player.UserId then
			return Value, Index
		end
	end
	return nil
end

function SubscriptionModule.FetchSubscriptionInfo(SubscriptionName: string)
	return FindSubscriptionByName(SubscriptionName)
end

function SubscriptionModule.DoesPlayerOwnSubscription(Player: Player, SubscriptionName: string): boolean
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData == nil then
		warn("Subscription data failed to fetch!")
		return false
	end

	return FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions) ~= nil
end

function SubscriptionModule.GetSubscriptionExpiration(Player: Player, SubscriptionName: string): number?
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData == nil then
		warn("Subscription data failed to fetch!")
		return nil
	end

	local Subscription    = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)
	local SubscriptionInfo = FindSubscriptionByName(SubscriptionName)

	if Subscription == nil or SubscriptionInfo == nil then
		warn('Subscription "' .. SubscriptionName .. '" not found for ' .. Player.Name)
		return nil
	end

	return Subscription.PurchaseDate + toSeconds(SubscriptionInfo.Duration)
end

function SubscriptionModule.GetTimeUntilExpiration(Player: Player, SubscriptionName: string): {any}
	local Expiration = SubscriptionModule.GetSubscriptionExpiration(Player, SubscriptionName)

	if Expiration == nil then
		return { Days = 0, Hours = 0, Minutes = 0, Seconds = 0, TotalSeconds = 0 }
	end

	local Remaining = math.max(0, Expiration - os.time())

	return {
		Days         = math.floor(Remaining / 86400),
		Hours        = math.floor((Remaining % 86400) / 3600),
		Minutes      = math.floor((Remaining % 3600) / 60),
		Seconds      = Remaining % 60,
		TotalSeconds = Remaining
	}
end

function SubscriptionModule.IsSubscriptionExpiringSoon(Player: Player, SubscriptionName: string, ThresholdDays: number?): boolean
	local Threshold = ThresholdDays or SubscriptionModule.Expiring_Soon_Threshold
	local TimeUntil = SubscriptionModule.GetTimeUntilExpiration(Player, SubscriptionName)
	return TimeUntil.TotalSeconds > 0 and TimeUntil.TotalSeconds < toSeconds(Threshold)
end

function SubscriptionModule.GetAllSubscribedPlayers(SubscriptionName: string): {Player}
	local SubscribedPlayers = {}

	for _, PlayerData in ipairs(SubscriptionModule.PlayerSubscriptions) do
		if FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions) ~= nil then
			local Player = Players:GetPlayerByUserId(PlayerData.UserId)
			if Player then
				table.insert(SubscribedPlayers, Player)
			end
		end
	end

	return SubscribedPlayers
end

function SubscriptionModule.GetSubscriptionPurchaseCount(Player: Player, SubscriptionName: string): number
	local key = tostring(Player.UserId) .. "_" .. SubscriptionName
	local _, count = retryAsync(function()
		return PurchaseCountDataStore:GetAsync(key)
	end, 3)
	return count or 0
end

-- Subscription Management --
function SubscriptionModule.RegisterSubscription(SubscriptionData: any)
	if not SubscriptionData.Name or not SubscriptionData.Duration then
		warn("Incomplete subscription table! Ensure each subscription has a Name and Duration.")
		return
	end
	table.insert(registeredSubscriptions, SubscriptionData)
end

function SubscriptionModule.GrantSubscription(Player: Player, SubscriptionName: string)
	local PlayerSubscriptionData = SubscriptionModule.FetchPlayerSubscriptionData(Player)
	local SubscriptionInfo       = FindSubscriptionByName(SubscriptionName)

	if PlayerSubscriptionData == nil then
		error("Player subscription data was not found for " .. Player.Name .. ". Issue with the module.")
	end
	if SubscriptionInfo == nil then
		error('Subscription "' .. SubscriptionName .. '" has not been registered. Did you call RegisterSubscription?')
	end

	local ExistingSubscription = FindSubscriptionByNameInTable(SubscriptionName, PlayerSubscriptionData.ActiveSubscriptions)

	if ExistingSubscription == nil then
		local Subscription = { Name = SubscriptionName, PurchaseDate = os.time() }
		table.insert(PlayerSubscriptionData.ActiveSubscriptions, Subscription)
		SubscriptionModule.SubscriptionPurchased:Fire(Player, Subscription)
		task.spawn(incrementPurchaseCount, Player.UserId, SubscriptionName)
	else
		if SubscriptionInfo.Stackable == true then
			ExistingSubscription.PurchaseDate += toSeconds(SubscriptionInfo.Duration)
			SubscriptionModule.SubscriptionRenewed:Fire(Player, ExistingSubscription)
			task.spawn(incrementPurchaseCount, Player.UserId, SubscriptionName)
		else
			warn(Player.Name .. " already owns subscription '" .. SubscriptionName .. "'!")
		end
	end
end

function SubscriptionModule.RevokeSubscription(Player: Player, SubscriptionName: string)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData == nil then
		warn("Subscription data failed to fetch!")
		return
	end

	local Subscription, PositionInTable = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

	if Subscription ~= nil then
		SubscriptionModule.SubscriptionExpired:Fire(Player, { Name = SubscriptionName, PurchaseDate = Subscription.PurchaseDate })
		table.remove(PlayerData.ActiveSubscriptions, PositionInTable)
	else
		warn(Player.Name .. " does not own subscription '" .. SubscriptionName .. "', nothing to revoke.")
	end
end

function SubscriptionModule.AdjustSubscription(Player: Player, SubscriptionName: string, Days: number)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData == nil then
		warn("Subscription data failed to fetch!")
		return
	end

	local Subscription = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

	if Subscription ~= nil then
		Subscription.PurchaseDate += toSeconds(Days)
	else
		warn(Player.Name .. " does not own subscription '" .. SubscriptionName .. "'. Grant it first.")
	end
end

function SubscriptionModule.PauseSubscription(Player: Player, SubscriptionName: string)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData == nil then
		warn("Subscription data failed to fetch!")
		return
	end

	local Subscription = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

	if Subscription == nil then
		warn(Player.Name .. " does not own subscription '" .. SubscriptionName .. "'!")
		return
	end

	if Subscription.PausedAt ~= nil then
		warn("Subscription '" .. SubscriptionName .. "' is already paused for " .. Player.Name)
		return
	end

	Subscription.PausedAt = os.time()
end

function SubscriptionModule.ResumeSubscription(Player: Player, SubscriptionName: string)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData == nil then
		warn("Subscription data failed to fetch!")
		return
	end

	local Subscription = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

	if Subscription == nil then
		warn(Player.Name .. " does not own subscription '" .. SubscriptionName .. "'!")
		return
	end

	if Subscription.PausedAt == nil then
		warn("Subscription '" .. SubscriptionName .. "' is not paused for " .. Player.Name)
		return
	end

	Subscription.PurchaseDate += os.time() - Subscription.PausedAt
	Subscription.PausedAt = nil
end

-- Player Lifecycle --
local function startExpirationListener(Player: Player)
	local listener = coroutine.create(function()
		repeat
			task.wait(SubscriptionModule.Expiration_Check_Rate)
			if Player == nil then break end

			local SubscriptionTable = SubscriptionModule.FetchPlayerSubscriptionData(Player)
			if SubscriptionTable == nil then break end

			for i = #SubscriptionTable.ActiveSubscriptions, 1, -1 do
				local Subscription    = SubscriptionTable.ActiveSubscriptions[i]
				local SubscriptionInfo = FindSubscriptionByName(Subscription.Name)

				if SubscriptionInfo == nil then
					warn("Subscription '" .. Subscription.Name .. "' not found while checking expiration.")
					continue
				end

				if Subscription.PausedAt ~= nil then continue end

				if not CheckSubscriptionValidity(Subscription, SubscriptionInfo.Duration) then
					SubscriptionModule.SubscriptionExpired:Fire(Player, {
						Name         = Subscription.Name,
						PurchaseDate = Subscription.PurchaseDate
					})
					table.remove(SubscriptionTable.ActiveSubscriptions, i)
				elseif SubscriptionModule.IsSubscriptionExpiringSoon(Player, Subscription.Name) then
					local RemainingSeconds = SubscriptionModule.GetTimeUntilExpiration(Player, Subscription.Name).TotalSeconds
					SubscriptionModule.SubscriptionExpiringSoon:Fire(Player, Subscription, RemainingSeconds)
				end
			end
		until Player == nil
	end)

	coroutine.resume(listener)
end

function SubscriptionModule.loadPlayer(Player: Player)
	local PlayerSubscriptions = {
		Name               = Player.Name,
		UserId             = Player.UserId,
		ActiveSubscriptions = {}
	}

	local success, PlayerData = retryAsync(function()
		return SubscriptionDataStore:GetAsync(Player.UserId)
	end, 3)

	if success and PlayerData then
		local decodedData = HTTPService:JSONDecode(PlayerData)

		for _, v in ipairs(decodedData.ActiveSubscriptions) do
			local SubscriptionInfo = FindSubscriptionByName(v.Name)
			if SubscriptionInfo == nil then continue end

			if CheckSubscriptionValidity(v, SubscriptionInfo.Duration) then
				table.insert(PlayerSubscriptions.ActiveSubscriptions, {
					Name         = v.Name,
					PurchaseDate = v.PurchaseDate,
					PausedAt     = v.PausedAt
				})
			else
				SubscriptionModule.SubscriptionExpired:Fire(Player, v)
			end
		end
	end

	table.insert(SubscriptionModule.PlayerSubscriptions, PlayerSubscriptions)
	startExpirationListener(Player)
end

function SubscriptionModule.unloadPlayer(Player: Player)
	local SubscriptionTable, Index = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if SubscriptionTable == nil then
		error(Player.Name .. " not found in PlayerSubscriptions during save. Module error.")
	end

	local SubscriptionsOwnedByPlayer = {}

	for _, Subscription in ipairs(SubscriptionTable.ActiveSubscriptions) do
		if FindSubscriptionByName(Subscription.Name) == nil then
			warn("Subscription '" .. Subscription.Name .. "' not found in the saving process.")
		end

		table.insert(SubscriptionsOwnedByPlayer, {
			Name         = Subscription.Name,
			PurchaseDate = Subscription.PurchaseDate,
			PausedAt     = Subscription.PausedAt
		})
	end

	local EncodedData = HTTPService:JSONEncode({ ActiveSubscriptions = SubscriptionsOwnedByPlayer })

	retryAsync(function()
		SubscriptionDataStore:UpdateAsync(Player.UserId, function()
			return EncodedData
		end)
	end, 3)

	table.remove(SubscriptionModule.PlayerSubscriptions, Index)
end

do
	if SubscriptionModule.Handle_Subscription_Purchases == true then
		task.spawn(function()
			task.wait(SubscriptionModule.Product_Handling_Yield)

			for _, Subscription in ipairs(registeredSubscriptions) do
				productFunctions[Subscription.ProductId] = function(receipt, player)
					SubscriptionModule.GrantSubscription(player, Subscription.Name)
				end
			end

			MarketplaceService.ProcessReceipt = processReceipt
		end)
	end

	if SubscriptionModule.Print_Credits == true then
		print("SubscriptionService")
	end
end

return SubscriptionModule
