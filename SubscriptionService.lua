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
 .     Expiration_Check_Rate (number):                   Rate for checking subscription expirations.
 .     Handle_Subscription_Purchases (boolean):          When true, the module will handle the subscription purchases. All you have to do is prompt the player with the Developer product and the module will handle it                                                   
 .     Print_Credits (boolean):                          Print credits to console.
 .     Product_Handling_Yield (number):                  Yield for product handling.


-------------------------------------------------------------
 Signals 
-------------------------------------------------------------
 .     SubscriptionExpired:             Fired when a subscription expires.
             Args: (Player: Player, Subscription: table)
                   Player is just the player object of the subscription owner.
                  
                   Subscription: 
                   {
                        Name = "subscription name here", -- Name of the subscription in a string
                        PurchaseDate = 57939529247 -- The UNIX timestamp of when the subscription was purchased
                   }
 
 
 
 .     SubscriptionPurchased:          Fired when a subscription is purchased.
             Args: (Player: Player, Subscription: table)
             
                    Subscription: 
                   {
                        Name = "subscription name here", -- Name of the subscription in a string
                        PurchaseDate = 57939529247 -- The UNIX timestamp of when the subscription was purchased
                   }
                   
                   
-------------------------------------------------------------
 Functions 
-------------------------------------------------------------
 
 .     Module.UnixToDDMMYY(Timestamp: number): Converts a Unix timestamp to DD/MM/YY format. Useful for making the expiration dates and stuff into readable dates.
             return: 31/10/2022 (the date of a timestamp.)
 
 .     Module.UnixToMMDDYY(Timestamp: number): Converts a Unix timestamp to MM/DD/YY format. Useful for making the expiration dates and stuff into readable dates.
             return: 10/31/2022 (freedom date format. the date of a timestamp)
 
 .     Module.UnixToReadableTime(Timestamp: number): Converts a Unix timestamp to a readable time format (UTC). Useful for making the expiration dates and stuff into readable dates.
             return: 22:20 (the readable time of a timestamp)
 
 .     Module.FetchPlayerSubscriptionData(Player: Player): Fetches subscription data for a player.
             return:
                   {
                     Name = "PlayerName"
                     
                     ActiveSubscriptions = {}
                   }
 
 .     Module.RegisterSubscription(SubscriptionData: any): Registers a subscription.
             no return
 
 .     Module.DoesPlayerOwnSubscription(Player: Player, SubscriptionName: string): Checks if a player owns a subscription.
             return: true/false depending if the player owns the subscription or not
 
 .     Module.GrantSubscription(Player: Player, SubscriptionName: string): Grants a subscription to a player.
             no return
 
 .     Module.RevokeSubscription(Player: Player, SubscriptionName: string): Revokes a subscription from a player.
             no return
 
 
 .     Module.AdjustSubscription(Player: Player, SubscriptionName: string, Days: number): Adjusts the expiration date of a subscription to grant extra days. if the number is negative, it will take days away
             no return
 
 .     Module.FetchSubscriptionInfo(SubscriptionName: string): Fetches subscription information.
              return:
                    {
                    
                     Name = "Test Subscription",
		           ProductId = 1679061197,
		           Duration = 7,
		           Stackable = true,
                    }
 
 .     Module.loadPlayer(Player: Player): Loads player subscription data.
             no return
 
 .     Module.unloadPlayer(Player: Player): Unloads player subscription data.
             no return
-------------------------------------------------------------
]]

-- Services --
local MarketplaceService = game:GetService("MarketplaceService") 
local DataStoreService = game:GetService("DataStoreService")
local HTTPService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Objects --
local SignalModuleObject = script.Parent:WaitForChild("GoodSignal")

-- Tables --
local registeredSubscriptions = {}
local productFunctions = {}

-- Modules --
local Signal = require(SignalModuleObject)

-- Datastore --
local SubscriptionDataStore = DataStoreService:GetDataStore("uj6rtrtrjursjtrsjtrsxrtj")

-- Local Functions --
local function toSeconds(Days: number)
	return Days * 86400
end

local function processReceipt(receiptInfo)
	local userId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId

	local player = Players:GetPlayerByUserId(userId)

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

local function FindSubscriptionByNameInTable(SubscriptionName: string, Table)
	for i, v in ipairs(Table) do
		if v.Name == SubscriptionName then
			return v, i
		end
	end

	return nil
end

local function FindSubscriptionByName(SubscriptionName: string)
	local FoundSubscription = nil

	for i, v in ipairs(registeredSubscriptions) do
		if v.Name == SubscriptionName then 
			FoundSubscription = v
			break 
		end 
	end

	return FoundSubscription
end

local function CheckSubscriptionValidity(PurchaseDate, Duration)
	local CurrentTime = os.time()
	local ExpirationDate = PurchaseDate + toSeconds(Duration)

	return ExpirationDate > CurrentTime
end

local SubscriptionModule = {
	-- Presets --
	Expiration_Check_Rate = 10, 
	Handle_Subscription_Purchases = true, 
	Print_Credits = true,
	Product_Handling_Yield = 0.5,

	-- DO NOT TOUCH BELOW --
	PlayerSubscriptions = {}
}

SubscriptionModule.SubscriptionExpired = Signal.new()
SubscriptionModule.SubscriptionPurchased = Signal.new()

-- Functions to handle date and time conversions --
function SubscriptionModule.UnixToDDMMYY(Timestamp: number)
	local t = os.date("*t", Timestamp)

	local DateString = tostring(t.day.."/"..t.month.."/"..t.year)

	return DateString
end

function SubscriptionModule.UnixToMMDDYY(Timestamp: number)
	local t = os.date("*t", Timestamp)

	local DateString = tostring(t.month.."/"..t.day.."/"..t.year)

	return DateString
end

function SubscriptionModule.UnixToReadableTime(Timestamp: number) -- This is in UTC
	local t = os.date("*t", Timestamp)

	return tostring(t.hour..":"..t.min)
end

function SubscriptionModule.FetchPlayerSubscriptionData(Player: Player)
	for Index, Value in ipairs(SubscriptionModule.PlayerSubscriptions) do
		if Value.UserId == Player.UserId then
			return Value, Index
		end
	end

	return nil
end

-- A function to register a subscription using a SubscriptionData object --
function SubscriptionModule.RegisterSubscription(SubscriptionData: any)
	if not SubscriptionData.Name or not SubscriptionData.Duration then
		warn("Incomplete table detected when passing through a table! Are you sure that each subscription table has values called Name and Duration?")
		return
	end

	table.insert(registeredSubscriptions, SubscriptionData)
end

-- A function to check if a player owns a certain subscription (Returns: true/false) --
function SubscriptionModule.DoesPlayerOwnSubscription(Player: Player, SubscriptionName: string)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData ~= nil then
		local SearchingForSubscription = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

		if SearchingForSubscription ~= nil then
			return true
		else
			return false
		end
	else
		warn("Subscription data failed to fetch! ;(")
	end
end

function SubscriptionModule.AdjustSubscription(Player: Player, SubscriptionName: string, Days: number)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData ~= nil then
		local SearchingForSubscription = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

		if SearchingForSubscription ~= nil then
			SearchingForSubscription.PurchaseDate += toSeconds(Days)
		else
			warn(Player.Name.." does not own subscription "..SubscriptionName.."! Try granting the subscription first.")
		end
	else
		warn("Subscription data failed to fetch! ;(;(")
	end
end

-- A function to grant a subscription to a player --
function SubscriptionModule.GrantSubscription(Player: Player, SubscriptionName: string)
	local PlayerSubscriptionData = SubscriptionModule.FetchPlayerSubscriptionData(Player)
	local SubscriptionInfo = FindSubscriptionByName(SubscriptionName)

	if PlayerSubscriptionData == nil then error("Player subscription data was not found for "..Player.Name..". Issue with the module. Please message scope.") end
	if SubscriptionInfo == nil then error('Subscription by the name "'..SubscriptionName..'" has not been found in the list of registered subscriptions. Did you register the intended subscription under the correct name?') end

	local SubscriptionWantedInTable = FindSubscriptionByNameInTable(SubscriptionName, PlayerSubscriptionData.ActiveSubscriptions)

	if SubscriptionWantedInTable == nil then
		local Subscription = {
			Name = SubscriptionName,
			PurchaseDate = os.time(),
		}

		table.insert(PlayerSubscriptionData.ActiveSubscriptions, Subscription)
		SubscriptionModule.SubscriptionPurchased:Fire(Player, Subscription)
	else
		if SubscriptionInfo.Stackable == true then
			SubscriptionWantedInTable.PurchaseDate += toSeconds(SubscriptionInfo.Duration)
			SubscriptionModule.SubscriptionPurchased:Fire(Player, SubscriptionWantedInTable)
		else
			warn(Player.Name.." already owns subscription '"..SubscriptionName.."'!")
		end
	end
end

-- A function that that handles overall revoking of a subscription --
function SubscriptionModule.RevokeSubscription(Player: Player, SubscriptionName: string)
	local PlayerData = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if PlayerData ~= nil then
		local SearchingForSubscription, PositionInTable = FindSubscriptionByNameInTable(SubscriptionName, PlayerData.ActiveSubscriptions)

		if SearchingForSubscription ~= nil then
			SubscriptionModule.SubscriptionExpired:Fire(Player, {Name = SubscriptionName, PurchaseDate = SearchingForSubscription.PurchaseDate})
			table.remove(PlayerData.ActiveSubscriptions, PositionInTable)
		else
			warn(Player.Name.." does not own subscription "..SubscriptionName.." so there is no point in revoking the subscription!")
		end
	else
		warn("Subscription data failed to fetch! ;(")
	end
end

function SubscriptionModule.FetchSubscriptionInfo(SubscriptionName: string)
	return FindSubscriptionByName(SubscriptionName)
end

function SubscriptionModule.loadPlayer(Player: Player) -- creates the subscription storage and filters whichever ones the player has and whichever ones are expired
	local PlayerData = SubscriptionDataStore:GetAsync(Player.UserId)

	local PlayerSubscriptions = {
		Name = Player.Name,
		UserId = Player.UserId,
		ActiveSubscriptions = {}
	}

	if PlayerData then
		local decodeddata = HTTPService:JSONDecode(PlayerData)

		for i, v in ipairs(decodeddata.ActiveSubscriptions) do
			local SubscriptionInfo = nil

			SubscriptionInfo = FindSubscriptionByName(v.Name)

			if SubscriptionInfo == nil then continue end

			if CheckSubscriptionValidity(v.PurchaseDate, SubscriptionInfo.Duration) == true then
				local Subscription = {
					Name = v.Name,
					PurchaseDate = v.PurchaseDate
				}

				table.insert(PlayerSubscriptions.ActiveSubscriptions, Subscription)
			else
				SubscriptionModule.SubscriptionExpired:Fire(Player, v)
			end
		end
	end

	table.insert(SubscriptionModule.PlayerSubscriptions, PlayerSubscriptions)

	local SubscriptionExpirationListener = coroutine.create(function() -- listens to every subscription that the player has and checks if it has expired
		repeat
			task.wait(SubscriptionModule.Expiration_Check_Rate)
			if Player == nil then break end

			local SubscriptionTable = SubscriptionModule.FetchPlayerSubscriptionData(Player)

			if SubscriptionTable == nil then break end

			-- Iterate backwards to safely remove while iterating
			for i = #SubscriptionTable.ActiveSubscriptions, 1, -1 do
				local Subscription = SubscriptionTable.ActiveSubscriptions[i]
				local SubscriptionInfo = FindSubscriptionByName(Subscription.Name)

				if SubscriptionInfo == nil then
					warn("Subscription by the name '"..Subscription.Name.."' was not found while listening for expiration.")
					continue
				end

				if Subscription.PurchaseDate ~= nil then
					if not CheckSubscriptionValidity(Subscription.PurchaseDate, SubscriptionInfo.Duration) then
						SubscriptionModule.SubscriptionExpired:Fire(Player, {
							Name = Subscription.Name,
							PurchaseDate = Subscription.PurchaseDate
						})

						table.remove(SubscriptionTable.ActiveSubscriptions, i)
					end
				end
			end
		until Player == nil
	end)

	coroutine.resume(SubscriptionExpirationListener)
end

function SubscriptionModule.unloadPlayer(Player: Player)
	local SubscriptionTable, Index = SubscriptionModule.FetchPlayerSubscriptionData(Player)

	if SubscriptionTable == nil then error(Player.Name.." not found in the main table of the SubscriptionService while saving data: Module error.") end

	local SubscriptionsOwnedByPlayer = {}

	for _, Subscription in ipairs(SubscriptionTable.ActiveSubscriptions) do
		local SubscriptionInfo = FindSubscriptionByName(Subscription.Name)

		if SubscriptionInfo == nil then warn("Subscription by the name '"..Subscription.Name.."' was not found in the saving process.") end

		table.insert(SubscriptionsOwnedByPlayer, {Name = Subscription.Name, PurchaseDate = Subscription.PurchaseDate})
	end

	local PlayerData = {
		ActiveSubscriptions = SubscriptionsOwnedByPlayer
	}

	local EncodedData = HTTPService:JSONEncode(PlayerData)

	SubscriptionDataStore:SetAsync(Player.UserId, EncodedData)
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
