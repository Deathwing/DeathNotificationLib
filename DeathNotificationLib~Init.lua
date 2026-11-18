--[[
DeathNotificationLib~Init.lua
--]]

local VERSION = 33

local lib = DeathNotificationLib
if lib and lib.VERSION and (lib.VERSION >= VERSION or not lib.Shutdown) then return end
if lib and lib.Shutdown then
	lib.Shutdown()
end
lib = lib or {}
DeathNotificationLib = lib

local internal = { frames = {}, cleanups = {}, stopped = false }
lib.VERSION = VERSION
lib.State = lib.State or {}
lib.Internal = internal

function lib.Shutdown()
	internal.stopped = true
	for _, cleanup in ipairs(internal.cleanups) do
		cleanup()
	end
	for _, frame in ipairs(internal.frames) do
		frame:UnregisterAllEvents()
		frame:SetScript("OnUpdate", nil)
		frame:Hide()
	end
end

function internal.createFrame(...)
	local frame = CreateFrame(...)
	internal.frames[#internal.frames + 1] = frame
	return frame
end

function internal.after(delay, callback)
	C_Timer.After(delay, function()
		if not internal.stopped then callback() end
	end)
end

function internal.newTicker(interval, callback, iterations)
	return C_Timer.NewTicker(interval, function(ticker)
		if internal.stopped then return ticker:Cancel() end
		callback(ticker)
	end, iterations)
end

function internal.newTimer(delay, callback)
	return C_Timer.NewTimer(delay, function(timer)
		if not internal.stopped then callback(timer) end
	end)
end

function internal.hookSecureFunc(...)
	local args = { ... }
	local callback = args[#args]
	args[#args] = function(...)
		if not internal.stopped then return callback(...) end
	end
	hooksecurefunc(unpack(args))
end

function internal.hookScript(frame, script, callback)
	frame:HookScript(script, function(...)
		if not internal.stopped then return callback(...) end
	end)
end

local _dnl = internal ---@class _dnl

_dnl.IS_FOREVER = WOW_PROJECT_ID == WOW_PROJECT_CAMELOT
_dnl.EXPANSION_LEVEL = _dnl.IS_FOREVER and 0 or (GetExpansionLevel and GetExpansionLevel() or 0)

---@param value any
---@return boolean
function _dnl.isSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

--- Forever blocks addon chat sends in dungeons, raids, battlegrounds and encounters.
---@return boolean
function _dnl.inChatLockdown()
	return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown()
end

-- ── Auto-detect the Interface path to this library folder ────────────
-- debugstack() returns "path/to/file.lua:line: ..." when the chunk loads.
-- We strip the filename to get the directory, which lets media references
-- work regardless of which addon embeds DNL.
do
	local stack = debugstack(1, 1, 0) or ""
	local dir = stack:match("^(.+[/\\])DeathNotificationLib~Init%.lua") or ""
	-- Normalise to backslash (WoW media paths use backslashes)
	dir = dir:gsub("/", "\\")
	-- Strip everything before "Interface\" — PlaySoundFile / SetFont
	-- require paths rooted at "Interface\\" not the full disk path.
	dir = dir:gsub("^.*(Interface\\)", "%1")
	--- Base Interface path to this DeathNotificationLib folder (trailing backslash).
	--- Example: "Interface\\AddOns\\DeathNotificationLib\\"
	---@type string
	_dnl.media_path = dir
	--- Public mirror of the auto-detected base path so embedding addons can build
	--- media references (fonts, sounds, textures) that resolve correctly whether
	--- DNL is installed as its own AddOn or embedded under <Addon>\Libs\.
	--- `Internal` is stripped by the Finalizer, so consumers must use this.
	---@type string
	DeathNotificationLib.MEDIA_PATH = dir
end

_dnl.L = {
    cn = {},
    de = {},
    en = {},
    es = {},
    fr = {},
    it = {},
    ko = {},
    pt = {},
    ru = {}
}

_dnl.D = {}

_dnl.DEBUG = false
_dnl.LOCAL_DEBUG_ONLY = false

---------------------------------------------------------------------------
-- Version comparison utility
---------------------------------------------------------------------------

--- Parse a semantic version string ("major.minor.patch") into a comparable
--- numeric tuple.  Returns nil if the string is not a valid version.
---@param ver string|nil  e.g. "0.4.0", "1.2.3"
---@return number|nil major
---@return number|nil minor
---@return number|nil patch
function _dnl.parseVersion(ver)
	if type(ver) ~= "string" then return nil, nil, nil end
	local major, minor, patch = ver:match("^(%d+)%.(%d+)%.(%d+)$")
	if not major then return nil, nil, nil end
	return tonumber(major), tonumber(minor), tonumber(patch)
end

--- Resolve an ID value which may be a number or an array of numbers.
--- Returns the first ID, or nil if the value is nil.
---@param val number|table|nil
---@return number|nil
function _dnl.resolveId(val)
	if type(val) == "number" then return val end
	if type(val) == "table" then return val[1] end
	return nil
end

--- Compare two semantic version strings.
--- Returns  1 if a > b,  -1 if a < b,  0 if equal,  nil if either is invalid.
---@param a string|nil
---@param b string|nil
---@return number|nil  1, -1, 0, or nil
function _dnl.compareVersions(a, b)
	local a1, a2, a3 = _dnl.parseVersion(a)
	local b1, b2, b3 = _dnl.parseVersion(b)
	if not a1 or not b1 then return nil end
	if a1 ~= b1 then return a1 > b1 and 1 or -1 end
	if a2 ~= b2 then return a2 > b2 and 1 or -1 end
	if a3 ~= b3 then return a3 > b3 and 1 or -1 end
	return 0
end

--- Send via ChatThrottleLib when loaded (it may load after this library), else the client API.
---@param priority "BULK"|"NORMAL"|"ALERT"
---@param prefix string
---@param text string
---@param chatType string
---@param target string|nil
function _dnl.sendAddonMessage(priority, prefix, text, chatType, target)
	local CTL = _G.ChatThrottleLib
	if CTL then
		CTL:SendAddonMessage(priority, prefix, text, chatType, target)
		return
	end
	local send = C_ChatInfo and C_ChatInfo.SendAddonMessage or _G.SendAddonMessage
	if send then
		send(prefix, text, chatType, target)
	end
end

---------------------------------------------------------------------------
-- Shared utility: hide a channel from all chat frames
---------------------------------------------------------------------------

--- Remove a channel from all default chat frames (ChatFrame1–ChatFrame10)
--- so addon traffic never appears in the player's chat windows.
---@param channelName string  Channel name to hide
function _dnl.hideChannelFromChatFrames(channelName)
	if not channelName then return end
	if not _dnl.anyAddonEnables("auto_hide_chat_channels") then return end
	for i = 1, 10 do
		if _G["ChatFrame" .. i] then
			ChatFrame_RemoveChannel(_G["ChatFrame" .. i], channelName)
		end
	end
end

---------------------------------------------------------------------------
-- Blizzard chat-frame filter — prevent HistoryKeeper memory leak
---------------------------------------------------------------------------
-- Blizzard's HistoryKeeper.lua creates a permanent accessID entry for
-- every unique (chatType, chatTarget, chanSender) tuple seen on any
-- channel message.  On a high-traffic channel with hundreds of unique
-- senders this causes monotonically growing memory and CPU cost EVEN IF
-- the addon is doing nothing with the messages.
--
-- ChatFrame_AddMessageEventFilter runs BEFORE HistoryKeeper and the
-- per-frame AddMessage path.  By returning true for messages on our
-- channels we short-circuit the entire Blizzard chat pipeline,
-- eliminating:
--   • ChatHistory_GetAccessID allocations  (the primary leak)
--   • ChatFrame:AddMessage buffer growth
--   • GetColoredName / formatting overhead
--
-- The filter is installed at file-load time so it is active even before
-- the channels are joined (e.g. if the player was still in a channel
-- from a previous session).
--
-- Channel name prefixes (upper-cased for fast comparison):
--   "HCDEATHLOGSYNCCHANNEL"   – sync channel (and fallback suffixed variants)
--   "HCDEATHALERTSCHANNEL"    – death-alerts channel (and fallback variants)
---------------------------------------------------------------------------

local DNL_CHANNEL_PREFIXES = {
	"HCDEATHLOGSYNCCHANNEL",
	"HCDEATHALERTSCHANNEL",
}

--- ChatFrame_AddMessageEventFilter callback.
--- arg9 (11th parameter) is the channel name without number prefix.
---@return boolean true to suppress, false to pass through
local function dnlChannelChatFilter(self, event, arg1, arg2, arg3, arg4,
		arg5, arg6, arg7, arg8, arg9, ...)
	if arg9 then
		local upper = arg9:upper()
		for _, prefix in ipairs(DNL_CHANNEL_PREFIXES) do
			if upper:sub(1, #prefix) == prefix then
				return true  -- suppress: prevent HistoryKeeper + AddMessage processing
			end
		end
	end
	return false
end

local addMessageEventFilter = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or ChatFrame_AddMessageEventFilter
local removeMessageEventFilter = ChatFrameUtil and ChatFrameUtil.RemoveMessageEventFilter or ChatFrame_RemoveMessageEventFilter

if not _dnl.DEBUG then
	local filteredEvents = { "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }
	for _, event in ipairs(filteredEvents) do
		addMessageEventFilter(event, dnlChannelChatFilter)
	end
	_dnl.cleanups[#_dnl.cleanups + 1] = function()
		for _, event in ipairs(filteredEvents) do
			removeMessageEventFilter(event, dnlChannelChatFilter)
		end
	end
end

---------------------------------------------------------------------------
-- Shared hardware-event input dispatcher
---------------------------------------------------------------------------
-- WoW Classic requires a hardware event (mouse click / key press) to send
-- chat messages.  Instead of each module hooking WorldFrame independently,
-- we maintain a single hook and dispatch to registered drain callbacks.
-- Defined here (Init) so every module can call registerInputDrain at load
-- time regardless of their own load order.

local _input_drain_callbacks = {}

function _dnl.registerInputDrain(callback)
	_input_drain_callbacks[#_input_drain_callbacks + 1] = callback
end

local function drainAll()
	for _, cb in ipairs(_input_drain_callbacks) do
		cb()
	end
end

_dnl.hookScript(WorldFrame, "OnMouseDown", function(self, button)
	drainAll()
end)

local input_frame = _dnl.createFrame("Frame", nil, UIParent)
input_frame:SetScript("OnKeyDown", drainAll)
input_frame:SetPropagateKeyboardInput(true)

---------------------------------------------------------------------------
-- Multi-addon registry
---------------------------------------------------------------------------

--- A registered addon entry stored in _dnl.addons.
---@class DNL_RegisteredAddon
---@field name string           Unique addon name (e.g. "Deathlog")
---@field tag string            Exactly 3 characters, unique (e.g. "DLG")
---@field isUnitTracked fun(unit: UnitToken): boolean  Should DNL broadcast deaths for this unit?
---@field isUnitRecordedLocally (fun(unit: UnitToken): boolean)|nil  Keep this unit's untracked deaths for this addon only (SOURCE.LOCAL_SELF)
---@field settings DNL_Settings|nil  Per-addon SavedVariables (optional; all keys have defaults)
---@field db DNL_Database|nil        READ-ONLY by DNL: { [checksum] = PlayerData } for sync/query
---@field db_map DNL_DatabaseMap|nil READ-ONLY by DNL: { [name] = checksum } for sync/query
---@field dev_data DNL_DevData|nil   Optional debug data
---@field addon_version string|nil   Semantic version string (e.g. "0.4.0") for upgrade notifications
---@field newest_detected_version string|nil  Newer version seen from peers
---@field watchlistIconProvider fun(playerName: string): string|nil Optional callback returning a watchlist icon string for a player name
---@field syncWindowDays (fun(days: number): number)|nil  Narrows the configured sync window (never widens it)

--- Registry of all attached addons, keyed by addon name.
---@type table<string, DNL_RegisteredAddon>
lib.State.addons = lib.State.addons or {}
_dnl.addons = lib.State.addons

--- Lookup from 3-char tag to addon name for fast dispatch.
---@type table<string, string>
lib.State.tag_to_addon = lib.State.tag_to_addon or {}
_dnl.tag_to_addon = lib.State.tag_to_addon

--- Per-addon settings. A nil key, or no table at all, means _dnl.SETTING_DEFAULTS; the library never writes them.
--- Shared keys are on when any attached addon with a settings table resolves them on (the defaults when none has one).
---@class DNL_Settings
---@field peer_reporting boolean|nil Shared: accept deaths that other players report, live and legacy (default true)
---@field legacy_messages boolean|nil Shared: accept v0-v2 protocol messages (default false)
---@field addonless_logging boolean|nil Per addon: receive Blizzard-only deaths without class/race (default false)
---@field auto_blizzard_deaths boolean|nil Shared: join HardcoreDeaths and set its CVars (default true)
---@field auto_hide_chat_channels boolean|nil Shared: hide the library's channels from chat frames (default true)
---@field share_playtime boolean|nil Per addon: false strips /played from this addon's copies, never from the outgoing broadcast (default true)
---@field sync_enabled boolean|nil Per addon: sync this addon's db, including HardcoreTBC imports (default true)
---@field sync_window_days number|nil Per addon: sync lookback window in days, -1 = all (default 7)
---@field sync_interval number|nil Shared: watermark interval in seconds, the shortest across attached addons and never above the default (default 300)
---@field sync_max_entries number|nil Per addon: max entries streamed per sync session (default 500)
---@field sync_cooldown number|nil Per addon: cooldown between sync sessions in seconds (default 300)
---@field death_alert_priority number|nil Higher number wins when multiple addons provide settings (unset: 0 if a DeathAlert sub-table is present, else -1; ties broken by addon name)
---@field DeathAlert DNL_DeathAlertSettings|nil Sub-table consumed by ~DeathAlert.lua (auto-populated with defaults)

--- Settings sub-table for the built-in Death Alert widget.
--- All fields are optional; defaults are applied by ~DeathAlert.lua when nil.
---@class DNL_DeathAlertSettings
---@field enable boolean|nil Show death alert popup (default true)
---@field enable_sound boolean|nil Play a sound on death alert (default true)
---@field pos_x number|nil X offset from CENTER (default 0)
---@field pos_y number|nil Y offset from CENTER (default 250)
---@field size_x number|nil Frame width (default 600)
---@field size_y number|nil Frame height (default 200)
---@field style string|nil Visual style key: "boss_banner_basic_small"|"boss_banner_basic_medium"|"boss_banner_enemy_icon_small"|"boss_banner_enemy_icon_medium"|"boss_banner_enemy_icon_animated"|"text_only" (default "boss_banner_enemy_icon_medium")
---@field display_time number|nil Seconds to show the alert (default 6)
---@field font string|nil Font key in shared media or built-in table (default "Nimrod MT")
---@field font_size number|nil Font point size (default 16)
---@field font_color_r number|nil Font red channel 0-1 (default 1)
---@field font_color_g number|nil Font green channel 0-1 (default 1)
---@field font_color_b number|nil Font blue channel 0-1 (default 1)
---@field font_color_a number|nil Font alpha channel 0-1 (default 1)
---@field message string|nil Default death message template
---@field fall_message string|nil Fall death message template
---@field drown_message string|nil Drown death message template
---@field slime_message string|nil Slime death message template
---@field lava_message string|nil Lava death message template
---@field fire_message string|nil Fire death message template
---@field fatigue_message string|nil Fatigue death message template
---@field min_lvl number|nil Minimum victim level to show (default 1)
---@field min_lvl_player boolean|nil Use player level as min_lvl (default false)
---@field max_lvl number|nil Maximum victim level to show (default MAX_PLAYER_LEVEL)
---@field filter_mode string|nil Guild filter: "all"|"guild_only"|"guild_confederation"|"none" (default "all")
---@field accent_color_r number|nil Accent red channel 0-1 (default 1)
---@field accent_color_g number|nil Accent green channel 0-1 (default 1)
---@field accent_color_b number|nil Accent blue channel 0-1 (default 1)
---@field accent_color_a number|nil Accent alpha channel 0-1 (default 1)
---@field current_zone_filter boolean|nil Only show deaths in current zone (default false)
---@field alert_sound string|nil Sound key: "default_hardcore"|"random"|any LSM key (default "default_hardcore")
---@field sound_channel string|nil Audio channel for the alert sound: "Master"|"SFX"|"Ambience"|"Music"|"Dialog" (default "Master")
---@field death_alert_options_parent string|nil Blizzard settings parent category name for the DeathAlert options panel (default "DeathNotificationLib")
---@field alertFilter fun(entry: PlayerData): boolean|nil Optional per-entry veto; return true to suppress the alert. Only the alert-owning addon's filter is consulted.

--- Persistent death entry stored by checksum.
---@alias DNL_DBEntry PlayerData

--- Database keyed by fletcher16 checksum.
---@alias DNL_Database table<string, DNL_DBEntry>

--- Name-to-checksum lookup table for fast query by player name.
---@alias DNL_DatabaseMap table<string, string>

--- Optional debug / analysis outputs populated by testing utilities and addon runtime.
---@class DNL_DevData
---@field map_bounds table|nil
---@field world_map_data table|nil

---------------------------------------------------------------------------
-- Settings helpers (per-addon)
---------------------------------------------------------------------------

_dnl.SETTING_DEFAULTS = {
	peer_reporting          = true,
	legacy_messages         = false,
	addonless_logging       = false,
	share_playtime          = true,
	auto_blizzard_deaths    = true,
	auto_hide_chat_channels = true,
	sync_enabled            = true,
	sync_window_days        = 7,
	sync_interval           = 300,
	sync_max_entries        = 500,
	sync_cooldown           = 300,
}

--- One addon's value for key, or the default when it is nil.
---@param settings DNL_Settings|nil
---@param key string
---@return any
function _dnl.getSetting(settings, key)
	local value = settings and settings[key]
	if value == nil then return _dnl.SETTING_DEFAULTS[key] end
	return value
end

--- True when any attached addon with a settings table resolves key on; the default when none has one.
---@param key string
---@return boolean
function _dnl.anyAddonEnables(key)
	local found = false
	for _, addon in pairs(_dnl.addons) do
		if addon.settings then
			if _dnl.getSetting(addon.settings, key) then return true end
			found = true
		end
	end
	return not found and _dnl.SETTING_DEFAULTS[key] == true
end

--- Return the settings table and addon name from the addon with the highest death_alert_priority.
--- Addons without an explicit priority rank 0 when their settings already
--- carry a DeathAlert sub-table and -1 otherwise; equal ranks are broken by
--- addon name so the result is stable across sessions.
--- Used ONLY by the DeathAlert widget to read/write its sub-table.
--- Returns nil, nil if no addon has settings.
---@return DNL_Settings|nil settings
---@return string|nil addon_name
function _dnl.getDeathAlertOwnerSettings()
	local best_settings = nil
	local best_name = nil
	local best_prio = nil
	for name, addon in pairs(_dnl.addons) do
		local s = addon.settings
		if s then
			-- An explicit death_alert_priority always wins. Without one, an
			-- addon that ships a DeathAlert sub-table (it actually configures
			-- the alert, and its SavedVariables hold the player's choices)
			-- ranks above an addon that only attached with unrelated settings,
			-- e.g. { addonless_logging = true }. Otherwise a helper addon could
			-- become the owner by pairs() luck, the widget would read/write its
			-- throwaway table, and every alert setting reset on /reload.
			local p = s.death_alert_priority
			if p == nil then
				p = (type(s.DeathAlert) == "table") and 0 or -1
			end
			-- Equal ranks tie-break by addon name so the owner never changes
			-- between sessions (pairs() order is not stable).
			if best_prio == nil or p > best_prio or (p == best_prio and name < best_name) then
				best_prio = p
				best_settings = s
				best_name = name
			end
		end
	end
	return best_settings, best_name
end
