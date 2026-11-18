--[[
DeathNotificationLib~Events.lua

WoW event dispatcher and library initialization.

Registers for all game events relevant to death logging and routes them
to the appropriate handler functions.  Also provides AttachAddon(), the
per-addon registration call that binds an addon's settings, database
references, and callbacks to the multi-addon registry.

Handled events (partial list):
  CHAT_MSG_CHANNEL            – death pings, checksums, duel requests
  COMBAT_LOG_EVENT_UNFILTERED – last-attack-source tracking per unit
  PLAYER_DEAD                 – self-death broadcast (tracked characters), local-only delivery (opted-in addons)
  UNIT_HEALTH                 – party/raid death detection (health → 0)
  CHAT_MSG_SAY/GUILD/PARTY    – captures "last words" for death reports
  PLAYER_ENTERING_WORLD       – channel joins
  HARDCORE_DEATHS             – Blizzard built-in death announcements
  DUEL_TO_THE_DEATH_REQUESTED - duel-to-death state management
  CHAT_MSG_ADDON              – query/response protocol, sync dispatch
  WHO_LIST_UPDATE             – /who result interception
  CHAT_MSG_MONSTER_EMOTE      – Tarnished Soul emotes (via ~BlizzardParser.lua)
--]]

local _dnl = DeathNotificationLib.Internal ---@class _dnl
if not _dnl then return end
local SOURCE = _dnl.SOURCE
local isSecret = _dnl.isSecret

--- Pre-broadcast self-death hooks — called when the local player dies,
--- before the death is broadcast.  Each hook receives a **shallow copy**
--- of the PlayerData table and may mutate it freely.  If the copy still
--- passes validatePlayerData after the hook returns, the changes are
--- accepted; otherwise the copy is discarded and the original is kept.
---@type fun(player_data: PlayerData)[] 
local state = DeathNotificationLib.State
state.hook_self_death_functions = state.hook_self_death_functions or {}
local hook_self_death_functions = state.hook_self_death_functions

local comm_query_locks = {}
local last_playtime = 0
local last_playtime_updated_at = GetServerTime()
local playtime_suppression_counter = 0
local playtime_muted_chat_frames = {}

local function muteTimePlayedChatFrames()
	for i = 1, NUM_CHAT_WINDOWS or 10 do
		local frame = _G["ChatFrame" .. i]
		if frame and frame:IsEventRegistered("TIME_PLAYED_MSG") then
			frame:UnregisterEvent("TIME_PLAYED_MSG")
			playtime_muted_chat_frames[#playtime_muted_chat_frames + 1] = frame
		end
	end
end

local function unmuteTimePlayedChatFrames()
	for i = #playtime_muted_chat_frames, 1, -1 do
		playtime_muted_chat_frames[i]:RegisterEvent("TIME_PLAYED_MSG")
		playtime_muted_chat_frames[i] = nil
	end
end

_dnl.hookSecureFunc("StaticPopup_Show", function(which, text_arg1, text_arg2, data)
	if data and type(data) == "string" and not isSecret(data) then
		if string.find(data, _dnl.DEATH_ALERTS_CHANNEL_BASE) == 1 or string.find(data, _dnl.SYNC_CHANNEL_BASE) == 1 then
			StaticPopup_Hide(which)
		end
	end
end)

local function getPlaytime()
	return last_playtime + (GetServerTime() - last_playtime_updated_at)
end

local function requestTimePlayed()
	muteTimePlayedChatFrames()
	playtime_suppression_counter = playtime_suppression_counter + 1
	RequestTimePlayed()
end

---------------------------------------------------------------------------
-- Multi-addon broadcast decision
---------------------------------------------------------------------------

--- Check if ANY registered addon wants to track deaths for this unit.
--- Returns true if at least one addon's isUnitTracked callback says yes.
---@param unit UnitToken
---@return boolean
function _dnl.shouldBroadcastDeath(unit)
	for _, addon in pairs(_dnl.addons) do
		if addon.isUnitTracked(unit) then
			return true
		end
	end
	return false
end

--- Names of the attached addons whose isUnitRecordedLocally callback says yes, or nil.
---@param unit UnitToken
---@return string[]|nil
function _dnl.localRecorders(unit)
	local names
	for name, addon in pairs(_dnl.addons) do
		if addon.isUnitRecordedLocally and addon.isUnitRecordedLocally(unit) then
			names = names or {}
			names[#names + 1] = name
		end
	end
	return names
end

--- true to broadcast the local player's death, the addons that keep it locally, or nil to ignore it.
---@return true|string[]|nil
local function selfDeathRecipients()
	if _dnl.shouldBroadcastDeath("player") then
		return true
	end
	return _dnl.localRecorders("player")
end

local SELF_DEATH_REPEAT_WINDOW = 10
local self_death_at

--- The client can fire PLAYER_DEAD twice for one death: true for a repeat while the player has stayed dead.
---@return boolean
local function isRepeatedSelfDeath()
	local now = GetTime()
	if self_death_at and now - self_death_at < SELF_DEATH_REPEAT_WINDOW and UnitIsDeadOrGhost("player") then
		return true
	end
	self_death_at = now
	return false
end

local function onPlayerAlive()
	if self_death_at and not UnitIsDeadOrGhost("player") then
		self_death_at = nil
	end
end

--- Deliver an untracked death to the opted-in addons only: no broadcast, LRU, self-death hooks or alert.
---@param player_data PlayerData
---@param recorders string[]
local function recordLocalDeath(player_data, recorders)
	-- Marks a normal-mode death, so anything that ever leaks it can still be told apart.
	player_data["extra_data"] = player_data["extra_data"] or {}
	player_data["extra_data"]["m"] = "n"
	local checksum = _dnl.fletcher16(player_data)
	for _, name in ipairs(recorders) do
		_dnl.createEntry(player_data, checksum, 0, nil, SOURCE.LOCAL_SELF, name)
	end
end

---------------------------------------------------------------------------
-- Channel management
---------------------------------------------------------------------------

--- Blizzard's _G.HARDCORE_DEATHS is the localized *display* label for the
--- Hardcore death channel ("Hardcore Deaths", with a space on enUS). It is NOT a
--- valid argument to JoinChannelByName — a channel name containing a space is
--- rejected (the call returns nil) and the channel is never joined. The joinable
--- identifier is the space-free name EnumerateServerChannels reports
--- ("HardcoreDeaths"); match on the space-stripped, lower-cased form so this
--- stays correct across locales.
local function resolveHardcoreDeathsChannel()
	local displayName = _G["HARDCORE_DEATHS"]
	if not displayName or not EnumerateServerChannels then return nil end
	local want = displayName:gsub("%s", ""):lower()
	for _, name in ipairs({ EnumerateServerChannels() }) do
		if name:gsub("%s", ""):lower() == want then
			return name
		end
	end
	return nil
end

--- Re-check CVars, Blizzard Hardcore death channel membership, and keep our
--- addon channels hidden on every zone change so nothing drifts.
local function updateChannels()
	local channelName = resolveHardcoreDeathsChannel()

	if channelName and _dnl.anyAddonEnables("auto_blizzard_deaths") then
		if GetChannelName(channelName) == 0 then
			_dnl.after(2.5, function()
				if GetChannelName(channelName) == 0 then
					JoinChannelByName(channelName, nil, nil, false)
				end
			end)
		end
---@diagnostic disable: param-type-mismatch
		SetCVar("hardcoreDeathAlertType", 2)
		SetCVar("hardcoreDeathChatType", 1)
---@diagnostic enable: param-type-mismatch
	end

	_dnl.hideChannelFromChatFrames(_dnl.death_alerts_channel or _dnl.DEATH_ALERTS_CHANNEL_BASE)
	if _dnl.sync_channel then
		_dnl.hideChannelFromChatFrames(_dnl.sync_channel or _dnl.SYNC_CHANNEL_BASE)
	end
end

---@param arg table
local function onChatMsgChannel(arg)
	if isSecret(arg[1]) or isSecret(arg[2]) or isSecret(arg[12]) then return end
	local _, channel_name = string.split(" ", arg[4])

	if channel_name == _dnl.sync_channel then
		_dnl.handleSyncChannelMessage(arg)
		return
	end

	if channel_name ~= _dnl.death_alerts_channel then
		return
	end
	local command, msg, _doublechecksum = string.split(_dnl.COMM_COMMAND_DELIM, arg[1])

	if command == _dnl.COMM_COMMANDS["BROADCAST_DEATH_PING_CHECKSUM"] then
		local player_name_short, _ = string.split("-", arg[2])
		if _dnl.throttleCheck(player_name_short) then return end

		_dnl.deathlogReceiveChannelMessageChecksum(player_name_short, msg)
		if _dnl.DEBUG then
			print("checksum", msg)
		end
		return
	end

	if command == _dnl.COMM_COMMANDS["BROADCAST_DEATH_PING"] then
		local player_name_short, _ = string.split("-", arg[2])
		if _dnl.throttleCheck(player_name_short) then return end

		-- arg[12] is the server-stamped sender GUID: unforgeable, survives renames.
		-- arg[11] is the chat line ID, needed to file a message (spam/chat) report;
		-- it is only valid this session, so it is never persisted.
		local sender_guid = arg[12]
		local chat_line_id = arg[11]
		local test_decoded, test_ver = _dnl.decodeMessage(msg)
		if test_decoded then
			_dnl.handleDeathBroadcast(player_name_short, msg, sender_guid, chat_line_id)
		else
--#region Backwards compatible API

			if _dnl.anyAddonEnables("legacy_messages") then
				_dnl.handleV2DeathBroadcast(player_name_short, msg)
			end

--#endregion
		end
		if _dnl.DEBUG then
			print("death ping", msg)
		end
		return
	end

	if command == _dnl.COMM_COMMANDS["REQUEST_DUEL_TO_DEATH"] then
		local player_name_short, _ = string.split("-", arg[2])
		if _dnl.throttleCheck(player_name_short) then return end

		local checksum, players = string.split(_dnl.COMM_FIELD_DELIM, msg)
		local player_one, player_two = string.split("_", players)
		if player_one == UnitName("player") then
			_dnl.pvp_state.duel_to_death_player = player_two
		elseif player_two == UnitName("player") then
			_dnl.pvp_state.duel_to_death_player = player_one
		end
		return
	end

	if command == _dnl.COMM_COMMANDS["WATCHLIST_QUERY"] then
		local sender_full = arg[2]
		local player_name_short, _ = string.split("-", sender_full)
		if _dnl.throttleCheck(player_name_short) then return end
		-- Don't respond to our own queries
		if player_name_short == UnitName("player") then return end

		-- Parse: TAG~name1,name2,...
		local query_tag, name_list = nil, msg
		if msg and #msg > 4 and msg:sub(4, 4) == _dnl.COMM_FIELD_DELIM then
			query_tag = msg:sub(1, 3)
			name_list = msg:sub(5)
		end
		if not query_tag or not _dnl.tag_to_addon[query_tag] then return end

		local addon_entry = _dnl.addons[_dnl.tag_to_addon[query_tag]]
		if not addon_entry or not addon_entry.db_map or not addon_entry.db then return end

		local response_count = 0
		local MAX_RESPONSES = 10
		for query_name in name_list:gmatch("([^,]+)") do
			if response_count >= MAX_RESPONSES then break end
			local checksum = addon_entry.db_map[query_name]
			if checksum and addon_entry.db[checksum] then
				local found_data = addon_entry.db[checksum]
				local response_data = _dnl.playerData(
					found_data.name, found_data.guild, found_data.source_id, found_data.race_id, found_data.class_id,
					found_data.level, found_data.instance_id, found_data.map_id, found_data.map_pos,
					found_data.date, found_data.played, found_data.last_words, found_data.extra_data
				)
				local tag_overhead = 4  -- "TAG~" = 4 bytes
				local encoded = _dnl.encodeMessage(response_data, tag_overhead)
				if encoded then
					local resp_prefix = query_tag .. _dnl.COMM_FIELD_DELIM
					local commMessage = _dnl.COMM_QUERY_ACK .. _dnl.COMM_COMMAND_DELIM .. resp_prefix .. encoded
					_dnl.sendAddonMessage("BULK", _dnl.COMM_NAME, commMessage, "WHISPER", sender_full)
					response_count = response_count + 1
				end
			end
		end
		if _dnl.DEBUG then
			print("[DNL] Watchlist query from", player_name_short, "- responded with", response_count, "entries")
		end
		return
	end

--#region Backwards compatible API

	if _dnl.backwards_dispatch[command] and _dnl.anyAddonEnables("legacy_messages") then
		local player_name_short, _ = string.split("-", arg[2])
		if _dnl.throttleCheck(player_name_short) then return end

		_dnl.backwards_dispatch[command](player_name_short, msg)
		if _dnl.DEBUG then
			print("backwards compat command", command, msg)
		end
		return
	end

--#endregion
end

---@param arg table
local function onCombatLogEventUnfiltered(arg)
	local _, ev, _, source_guid, source_name, _, _, target_guid, _, _, _, environmental_type, _, _, _, _, _ =
		CombatLogGetCurrentEventInfo()

	if ev == "ENVIRONMENTAL_DAMAGE" then
		local target = UnitTokenFromGUID(target_guid)
		if _dnl.canUseUnitStates(target) then
			local unit_state = _dnl.getUnitState(target)
			unit_state.last_attack_source_name = environmental_type
			unit_state.last_attack_source_guid = nil
			unit_state.last_attack_source_health = nil
		end
	elseif source_guid ~= target_guid then
		if ev ~= "DAMAGE_SHIELD_MISSED" and string.find(ev, "DAMAGE") ~= nil then
			local target = UnitTokenFromGUID(target_guid)
			if _dnl.canUseUnitStates(target) then
				if source_guid == "" then source_guid = nil end
				local source_token = source_guid and UnitTokenFromGUID(source_guid)
				local source = source_name or (source_token and UnitName(source_token)) or UNKNOWN

				local unit_state = _dnl.getUnitState(target)
				unit_state.last_attack_source_name = source
				unit_state.last_attack_source_guid = source_guid
				unit_state.last_attack_source_health = _dnl.getUnitHealthText(source_token)
			end
		end
	end
end

---@param unit_state table
---@return boolean
local function applyDeathRecapSource(unit_state)
	local events = C_DeathRecap.GetRecapEvents()
	local killing_blow = events and events[1]
	if not killing_blow then return false end
	local timestamp = killing_blow.timestamp
	if isSecret(timestamp) then
		unit_state.last_attack_source_name, unit_state.last_attack_source_guid, unit_state.last_attack_source_health = nil, nil, nil
		return true
	end
	if not timestamp or math.abs(GetServerTime() - timestamp) > 60 then
		return false
	end

	local environmental_type = killing_blow.environmentalType
	if not isSecret(killing_blow.event) and killing_blow.event == "ENVIRONMENTAL_DAMAGE" and environmental_type and not isSecret(environmental_type) then
		environmental_type = environmental_type:lower()
		unit_state.last_attack_source_name = environmental_type:sub(1, 1):upper() .. environmental_type:sub(2)
		unit_state.last_attack_source_guid = nil
	else
		local source_name, source_guid = killing_blow.sourceName, killing_blow.sourceGUID
		unit_state.last_attack_source_name = not isSecret(source_name) and source_name or nil
		unit_state.last_attack_source_guid = not isSecret(source_guid) and source_guid or nil
	end
	unit_state.last_attack_source_health = nil
	return true
end

---@return table
local function snapshotPlayerDeath()
	local instance_id, map, position = _dnl.guessLocationForUnit("player")
	return {
		level = UnitLevel("player"),
		guild = GetGuildInfo("player"),
		instance_id = instance_id,
		map = map,
		pos_str = position and string.format("%.4f,%.4f", position.x, position.y) or nil,
		time = GetServerTime(),
		recent_msg = _dnl.getUnitState("player").recent_msg,
	}
end

---@param arg table
---@param snapshot table|nil  death-time values captured by the deferred recap path
---@param recipients true|string[]|nil  routing decided with the snapshot; a list keeps the death local
local function onPlayerDead(arg, snapshot, recipients)
	if not snapshot then
		if isRepeatedSelfDeath() then return end
		recipients = selfDeathRecipients()
		if not recipients then return end
		snapshot = snapshotPlayerDeath()
	end

	local userState = _dnl.getUnitState("player")

	local death_source, extra_data = _dnl.resolveDeathSource(userState.last_attack_source_name, userState.last_attack_source_guid, userState.last_attack_source_health)

	local _, _, race_id = UnitRace("player")
	local _, _, class_id = UnitClass("player")

	local player_data = _dnl.playerData(
		UnitName("player"),
		snapshot.guild,
		death_source,
		race_id,
		class_id,
		snapshot.level,
		snapshot.instance_id,
		snapshot.map,
		snapshot.pos_str,
		snapshot.time,
		getPlaytime(),
		snapshot.recent_msg,
		extra_data
	)

	if type(recipients) == "table" then
		recordLocalDeath(player_data, recipients)
		return
	end

	for _, f in ipairs(hook_self_death_functions) do
		local copy = _dnl.deepCopy(player_data)
		f(copy)

		local ok = _dnl.validatePlayerData(copy)
		if ok then
			player_data = copy
		end
	end

	_dnl.broadcastDeath(player_data)
end

---@param arg table
local function onUnitHealth(arg)
	local target = arg[1]
	if target == "player" then
		onPlayerAlive()
		return
	end
	if not _dnl.canUseUnitStates(target) then return end
	local health = UnitHealth(target)
	if (UnitIsDeadOrGhost(target) or (not isSecret(health) and health == 0)) and not UnitIsFeignDeath(target) and _dnl.shouldBroadcastDeath(target) then
		_dnl.reportPartyRaidDeath(target)
	end
end

---Shared handler for CHAT_MSG_SAY, CHAT_MSG_GUILD, CHAT_MSG_PARTY
---@param arg table
local function onChatMsg(arg)
	local text = arg[1]
	local senderGUID = arg[12]
	if isSecret(text) or isSecret(senderGUID) then return end
	local automated_text_found = string.find(text, "Our brave")
	local questie_text_found = string.find(text, "Questie")
	if automated_text_found == nil and questie_text_found == nil then
		local target = UnitTokenFromGUID(senderGUID)
		if not isSecret(target) and _dnl.canUseUnitStates(target) then
			_dnl.getUnitState(target).recent_msg = text
		end
	end
end

local _pew_fired = false
local _pew_initialized = false

--- Run first-time initialization only once both conditions are met:
---   1. PLAYER_ENTERING_WORLD has fired
---   2. At least one addon has called AttachAddon
local function initializeOnFirstReady()
	if _pew_initialized then return end
	if not _pew_fired then return end
	if not next(_dnl.addons) then return end

	_pew_initialized = true
	_dnl.refreshGuildMembers()
	requestTimePlayed()
	_dnl.after(0.5, function()
		_dnl.deathlogJoinChannel()
		_dnl.joinSyncChannel()
	end)
	_dnl.newTicker(60, requestTimePlayed)
	-- Next frame, so addons attaching in the same PLAYER_ENTERING_WORLD count for the shared settings.
	_dnl.after(0, updateChannels)
	_dnl.versionCheckOnSocialJoin()
end

---@param arg table
local function onPlayerEnteringWorld(arg)
	if _pew_initialized then
		updateChannels()
		return
	end
	_pew_fired = true
	initializeOnFirstReady()
end

---@param arg table
local function onZoneChangedNewArea(arg)
	updateChannels()
end

---@param arg table
local function onHardcoreDeaths(arg)
	if isSecret(arg[1]) then return end
	_dnl.onBlizzardChat(arg[1])
end

---@param arg table
local function onDuelToTheDeathRequested(arg)
	_dnl.pvp_state.duel_to_death_player = arg[1]

	local guildName = GetGuildInfo("player")
	if guildName == nil then
		guildName = ""
	end
	local player_data =
		_dnl.playerData(UnitName("player"), guildName, nil, nil, nil, UnitLevel("player"), nil, nil, nil, nil, nil, nil)
	local checksum = _dnl.fletcher16(player_data)
	local msg = checksum
		.. _dnl.COMM_FIELD_DELIM
		.. (UnitName("player") .. "_" .. _dnl.pvp_state.duel_to_death_player)
		.. _dnl.COMM_FIELD_DELIM
		.. _dnl.PROTOCOL_VERSION
		.. _dnl.COMM_FIELD_DELIM
	table.insert(_dnl.deathlog_request_duel_to_death_queue, {msg, GetServerTime()})
end

---@param arg table
local function onChatMsgAddon(arg)
	if arg[1] == _dnl.SYNC_COMM_NAME then
		_dnl.handleSyncAddonMessage(arg)
		return
	end

	if arg[1] == _dnl.VERSION_CHECK_COMM_NAME then
		_dnl.handleVersionCheckAddonMessage(arg)
		return
	end

	if arg[1] ~= _dnl.COMM_NAME then
		return
	end
	local command, msg = string.split(_dnl.COMM_COMMAND_DELIM, arg[2])
	if command == _dnl.COMM_QUERY then
		local query_sender = arg[4]
		if comm_query_locks[query_sender] then
			return
		end
		comm_query_locks[query_sender] = _dnl.newTimer(3, function()
			comm_query_locks[query_sender]:Cancel()
			comm_query_locks[query_sender] = nil
		end)
		-- Extract tag from query: "Q$TAG~name" → tag = first 3 chars of msg, name = rest after ~
		local query_tag, query_name = nil, msg
		if msg and #msg > 4 and msg:sub(4, 4) == _dnl.COMM_FIELD_DELIM then
			query_tag = msg:sub(1, 3)
			query_name = msg:sub(5)
		end
		-- Tag is required — reject tagless or unknown-tag queries
		if not query_tag or not _dnl.tag_to_addon[query_tag] then return end
		local found_data = nil
		local found_tag = nil
		local addon_entry = _dnl.addons[_dnl.tag_to_addon[query_tag]]
		if addon_entry and addon_entry.db_map and addon_entry.db and addon_entry.db_map[query_name] and addon_entry.db[addon_entry.db_map[query_name]] then
			found_data = addon_entry.db[addon_entry.db_map[query_name]]
			found_tag = query_tag
		end
		if found_data then
			local response_data = _dnl.playerData(
				found_data.name, found_data.guild, found_data.source_id, found_data.race_id, found_data.class_id,
				found_data.level, found_data.instance_id, found_data.map_id, found_data.map_pos,
				found_data.date, found_data.played, found_data.last_words, found_data.extra_data
			)
			local tag_overhead = found_tag and 4 or 0  -- "TAG~" = 4 bytes
			local encoded = _dnl.encodeMessage(response_data, tag_overhead)
			if encoded then
				local resp_prefix = found_tag and (found_tag .. _dnl.COMM_FIELD_DELIM) or ""
				local commMessage = _dnl.COMM_QUERY_ACK .. _dnl.COMM_COMMAND_DELIM .. resp_prefix .. encoded
				_dnl.sendAddonMessage("BULK", _dnl.COMM_NAME, commMessage, "WHISPER", arg[4])
			end
		end
	elseif command == _dnl.COMM_QUERY_ACK then
		-- Strip tag prefix: "TAG~encoded..." → tag + encoded data
		local ack_tag, ack_data = nil, msg
		if msg and #msg > 4 and msg:sub(4, 4) == _dnl.COMM_FIELD_DELIM then
			ack_tag = msg:sub(1, 3)
			ack_data = msg:sub(5)
		end
		local _player_data, _protocol_version = _dnl.decodeMessage(ack_data)
		if _protocol_version and (_protocol_version < _dnl.MIN_SUPPORTED_PROTOCOL_VERSION or _protocol_version > _dnl.PROTOCOL_VERSION) then
			return
		end
		if _player_data and _player_data["name"] and _dnl.expect_ack[_player_data["name"]] then
			-- Tag is required to route the response to the correct addon
			if not ack_tag or not _dnl.tag_to_addon[ack_tag] then return end
			if _dnl.isValidEntry(_player_data) then
				_dnl.createEntry(_player_data, nil, 0, nil, SOURCE.QUERY, _dnl.tag_to_addon[ack_tag])
			end
			_dnl.expect_ack[_player_data["name"]] = nil
		end
	end
end

---@param arg table
local function onWhoListUpdate(arg)
	_dnl.handleWhoListUpdate()
end

---@param arg table
local function onTimePlayedMsg(arg)
	last_playtime = arg[1]
	last_playtime_updated_at = GetServerTime()

	_dnl.after(0, function()
		if playtime_suppression_counter > 0 then
			playtime_suppression_counter = playtime_suppression_counter - 1

			if _dnl.DEBUG then
				print("Received new time played:", last_playtime)
			end
		end
		if playtime_suppression_counter == 0 then
			unmuteTimePlayedChatFrames()
		end
	end)
end

---@param arg table
local function onGroupRosterUpdate(arg)
	_dnl.versionCheckOnSocialJoin()
end

---@param arg table
local function onChatMsgMonsterEmote(arg)
	local message = arg[1]
	local player_name = arg[2]
	local player_guid = arg[12]

	if not _dnl.parseTarnishedSoulEmote(message) then
		return
	end

	if player_name == UnitName("player") then
		return
	end

	if _dnl.DEBUG then
		print("Soul of Iron death detected via emote:", player_name, "GUID:", player_guid)
	end

	local _, englishClass, _, englishRace, _, _, _ = GetPlayerInfoByGUID(player_guid)
	local class_id = englishClass and _dnl.D.CLASS_FILE_TO_ID[englishClass] or nil
	local race_id = englishRace and _dnl.D.RACE_FILE_TO_ID[englishRace] or nil

	local found_unit = _dnl.findPlayerTokenByName(player_name)
	local level = nil
	local guild = nil

	if found_unit then
		local unit_level = UnitLevel(found_unit)
		level = (unit_level and unit_level > 0) and unit_level or nil
		guild = GetGuildInfo(found_unit)
	end

	if _dnl.isNameAlreadyCommitted(player_name, level) then
		return
	end

	local instance_id, map, position = _dnl.guessLocationForUnit(found_unit)
	local pos_str = position and string.format("%.4f,%.4f", position.x, position.y) or nil

	local reported_time = GetServerTime()
	local function doReportedDeathBroadcast(_level, _guild, _race_id, _class_id)
		local _player_data = _dnl.playerData(
			player_name,
			_guild,
			-1,
			_race_id,
			_class_id,
			_level,
			instance_id,
			map,
			pos_str,
			reported_time,
			nil,
			nil
		)
		_dnl.broadcastDeath(_player_data)
	end

	if level and race_id and class_id then
		doReportedDeathBroadcast(level, guild, race_id, class_id)
	else
		local invoked = false

		local function reportOrEnqueue()
			if invoked then return end
			invoked = true

			if level and race_id and class_id then
				doReportedDeathBroadcast(level, guild, race_id, class_id)
			else
				local queued = false
				for _, hook in ipairs(_dnl.hook_queue_player_functions) do
					if hook(player_name, player_guid, race_id, class_id, guild, map, pos_str, instance_id) then
						queued = true
					end
				end
				if not queued then
					doReportedDeathBroadcast(level, guild, race_id, class_id)
				end
			end
		end

		local cancelWho = _dnl.enqueueWhoPlayer(player_name, function(who_info)
			if who_info then
				level = level or who_info.level
				guild = guild or (who_info.fullGuildName and _dnl.normalize(who_info.fullGuildName) or nil)
				class_id = class_id or (who_info.filename and _dnl.D.CLASS_FILE_TO_ID[who_info.filename] or nil)
				race_id = race_id or (who_info.raceStr and _dnl.D.RACE_NAME_TO_ID[who_info.raceStr] or nil)
			end

			reportOrEnqueue()
		end)

		_dnl.after(5.0, function()
			cancelWho()
			reportOrEnqueue()
		end)
	end
end

local dispatch = {
	["CHAT_MSG_CHANNEL"]             = onChatMsgChannel,
	["COMBAT_LOG_EVENT_UNFILTERED"]  = onCombatLogEventUnfiltered,
	["PLAYER_DEAD"]                  = onPlayerDead,
	["PLAYER_ALIVE"]                 = onPlayerAlive,
	["PLAYER_UNGHOST"]               = onPlayerAlive,
	["UNIT_HEALTH"]                  = onUnitHealth,
	["CHAT_MSG_SAY"]                 = onChatMsg,
	["CHAT_MSG_GUILD"]               = onChatMsg,
	["CHAT_MSG_PARTY"]               = onChatMsg,
	["PLAYER_ENTERING_WORLD"]        = onPlayerEnteringWorld,
	["ZONE_CHANGED_NEW_AREA"]        = onZoneChangedNewArea,
	["HARDCORE_DEATHS"]              = onHardcoreDeaths,
	["DUEL_TO_THE_DEATH_REQUESTED"]  = onDuelToTheDeathRequested,
	["CHAT_MSG_ADDON"]               = onChatMsgAddon,
	["WHO_LIST_UPDATE"]              = onWhoListUpdate,
	["TIME_PLAYED_MSG"]              = onTimePlayedMsg,
	["GROUP_ROSTER_UPDATE"]          = onGroupRosterUpdate,
}

if _dnl.IS_SOUL_OF_IRON_REALM then
    dispatch["CHAT_MSG_MONSTER_EMOTE"] = onChatMsgMonsterEmote
end

local function handleEvent(self, event, ...)
	local handler = dispatch[event]
	if handler then
		handler({ ... })
	end
end

if not CombatLogGetCurrentEventInfo then
	dispatch["COMBAT_LOG_EVENT_UNFILTERED"] = nil

	if C_DeathRecap and C_DeathRecap.GetRecapEvents then
		local RECAP_POLL_INTERVAL, RECAP_POLL_ATTEMPTS = 0.25, 12
		_dnl.PLAYER_DEAD_SETTLE_DELAY = RECAP_POLL_INTERVAL * RECAP_POLL_ATTEMPTS
		dispatch["PLAYER_DEAD"] = function(arg)
			if isRepeatedSelfDeath() then return end
			local recipients = selfDeathRecipients()
			if not recipients then return end
			local snapshot = snapshotPlayerDeath()
			local attempts = 0
			local function report()
				attempts = attempts + 1
				if not applyDeathRecapSource(_dnl.getUnitState("player")) and attempts < RECAP_POLL_ATTEMPTS then
					_dnl.after(RECAP_POLL_INTERVAL, report)
					return
				end
				onPlayerDead(arg, snapshot, recipients)
			end
			report()
		end
	end
end

local death_notification_lib_event_handler = _dnl.createFrame("Frame")
for event, _ in pairs(dispatch) do
    pcall(death_notification_lib_event_handler.RegisterEvent, death_notification_lib_event_handler, event)
end

if _dnl.DEBUG then
	_dnl.handleEvent = handleEvent
	_dnl.event_handler = death_notification_lib_event_handler
end

death_notification_lib_event_handler:SetScript("OnEvent", handleEvent)
_dnl.cleanups[#_dnl.cleanups + 1] = unmuteTimePlayedChatFrames
if IsLoggedIn() then
	_pew_fired = true
	initializeOnFirstReady()
end
C_ChatInfo.RegisterAddonMessagePrefix(_dnl.COMM_NAME)
C_ChatInfo.RegisterAddonMessagePrefix(_dnl.SYNC_COMM_NAME)
C_ChatInfo.RegisterAddonMessagePrefix(_dnl.VERSION_CHECK_COMM_NAME)

if RaidWarningFrame and _dnl.canParseBlizzardDeaths() then
	RaidWarningFrame:UnregisterEvent("HARDCORE_DEATHS")
end

---------------------------------------------------------------------------
-- AttachAddon
---------------------------------------------------------------------------

--- Register an addon with DeathNotificationLib.
--- May be called multiple times by different addons; each gets its own
--- entry in the multi-addon registry.
---
---@class DNL_AttachAddonOptions
---@field name string                          Unique addon name (e.g. "Deathlog")
---@field tag string                           Exactly 3 characters, unique across addons (e.g. "DLG")
---@field isUnitTracked fun(unit: UnitToken): boolean  REQUIRED — should DNL broadcast deaths for this unit?
---@field isUnitRecordedLocally (fun(unit: UnitToken): boolean)|nil  Opt-in, asked for "player" only when no addon tracks the death: true delivers it to this addon alone as SOURCE.LOCAL_SELF (extra_data.m = "n"), never broadcast
---@field settings DNL_Settings|nil            Per-addon settings (all keys have defaults)
---@field db DNL_Database|nil                  READ-ONLY by DNL: { [checksum] = PlayerData } for sync/query
---@field db_map DNL_DatabaseMap|nil           READ-ONLY by DNL: { [name] = checksum } for sync/query
---@field dev_data DNL_DevData|nil             Optional debug data
---@field addon_version string|nil             Semantic version string (e.g. "0.4.0") for upgrade notifications
---@field watchlistIconProvider fun(playerName: string): string|nil Optional callback returning a watchlist icon string for a player name
---@field syncWindowDays (fun(days: number): number)|nil  Optional: given the configured sync window (-1 = all), return a narrower one (1-30 days) this addon should sync; wider results are ignored
---@param options DNL_AttachAddonOptions
function _dnl.attachAddon(options)
	assert(type(options) == "table", "[DNL] AttachAddon: options must be a table")
	assert(type(options.name) == "string" and options.name ~= "", "[DNL] AttachAddon: name is required")
	assert(type(options.tag) == "string" and #options.tag == 3, "[DNL] AttachAddon: tag must be exactly 3 characters")
	assert(type(options.isUnitTracked) == "function", "[DNL] AttachAddon: isUnitTracked function is required")
	assert(options.isUnitRecordedLocally == nil or type(options.isUnitRecordedLocally) == "function", "[DNL] AttachAddon: isUnitRecordedLocally must be a function when provided")
	assert(options.watchlistIconProvider == nil or type(options.watchlistIconProvider) == "function", "[DNL] AttachAddon: watchlistIconProvider must be a function when provided")
	assert(options.syncWindowDays == nil or type(options.syncWindowDays) == "function", "[DNL] AttachAddon: syncWindowDays must be a function when provided")
	assert(not _dnl.addons[options.name], "[DNL] AttachAddon: addon '" .. options.name .. "' already registered")
	assert(not _dnl.tag_to_addon[options.tag], "[DNL] AttachAddon: tag '" .. options.tag .. "' already in use by '" .. (_dnl.tag_to_addon[options.tag] or "") .. "'")

	-- If db is provided, db_map must also be provided (and vice versa)
	if options.db or options.db_map then
		assert(options.db and options.db_map, "[DNL] AttachAddon: db and db_map must both be provided together")
	end

	---@type DNL_RegisteredAddon
	local addon = {
		name              = options.name,
		tag               = options.tag,
		isUnitTracked     = options.isUnitTracked,
		isUnitRecordedLocally = options.isUnitRecordedLocally,
		settings          = options.settings,
		db                = options.db,
		db_map            = options.db_map,
		dev_data          = options.dev_data,
		addon_version     = options.addon_version,
		watchlistIconProvider = options.watchlistIconProvider,
		syncWindowDays    = options.syncWindowDays,
	}

	_dnl.addons[options.name] = addon
	_dnl.tag_to_addon[options.tag] = options.name

	initializeOnFirstReady()

	if _dnl.DEBUG then
		print(string.format("[DNL] Addon registered: %s (tag=%s, db=%s, settings=%s)",
			options.name, options.tag,
			options.db and "yes" or "no",
			options.settings and "yes" or "no"))
	end
end

--#region API

DeathNotificationLib.AttachAddon = _dnl.attachAddon

---Return the newest addon version string detected from peers for the
---given registered addon, or nil if no newer version has been seen yet.
---@param addonName string  The name used in AttachAddon (e.g. "Deathlog")
---@return string|nil newerVersion  e.g. "0.5.0", or nil
DeathNotificationLib.GetNewerAddonVersion = function(addonName)
	local addon = _dnl.addons[addonName]
	if addon then return addon.newest_detected_version end
	return nil
end

--- Callbacks registered via HookOnNewerVersion.
---@type fun(addonName: string, newerVersion: string, currentVersion: string)[]
state.hook_newer_version_functions = state.hook_newer_version_functions or {}
local hook_newer_version_functions = state.hook_newer_version_functions
_dnl.hook_newer_version_functions = hook_newer_version_functions

---Register a hook that fires when a confirmed newer addon version is
---detected from peers.  The callback receives the addon name, the newer
---version string, and the current local version string.
---@param fn fun(addonName: string, newerVersion: string, currentVersion: string)
DeathNotificationLib.HookOnNewerVersion = function(fn)
	hook_newer_version_functions[#hook_newer_version_functions + 1] = fn
end

---Register a hook that fires when the local player dies, before broadcast.
---The hook receives a **shallow copy** of the PlayerData table.  Mutate it
---in place to enrich it (e.g. add extra_data fields).  If the copy fails
---validatePlayerData after your hook returns, the changes are silently
---discarded and the original data is broadcast unchanged.
---@param fn fun(player_data: PlayerData)
DeathNotificationLib.HookOnSelfDeath = function(fn) hook_self_death_functions[#hook_self_death_functions + 1] = fn end

--#endregion