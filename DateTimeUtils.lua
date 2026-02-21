local MONTH_NAMES = {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
}

local DateTimeUtils = {}

function DateTimeUtils.UnixToDDMMYY(Timestamp: number): string
	local t = os.date("*t", Timestamp)
	return tostring(t.day .. "/" .. t.month .. "/" .. t.year)
end

function DateTimeUtils.UnixToMMDDYY(Timestamp: number): string
	local t = os.date("*t", Timestamp)
	return tostring(t.month .. "/" .. t.day .. "/" .. t.year)
end

function DateTimeUtils.UnixToReadableTime(Timestamp: number): string
	local t = os.date("*t", Timestamp)
	return tostring(t.hour .. ":" .. string.format("%02d", t.min))
end

function DateTimeUtils.UnixToFullDateTime(Timestamp: number): string
	local t = os.date("*t", Timestamp)
	local month = MONTH_NAMES[t.month]
	local hour = string.format("%02d", t.hour)
	local min = string.format("%02d", t.min)
	return month .. " " .. t.day .. ", " .. t.year .. " at " .. hour .. ":" .. min .. " UTC"
end

return DateTimeUtils
