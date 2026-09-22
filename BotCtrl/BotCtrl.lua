-- BotCtrl 1.5.0 — WotLK 3.3.5a (Interface 30300)
-- Playerbot commander. Names come from the party roster; roles are assigned
-- here, not hardcoded in macros. Combat keys never send autogear or leave.
-- Gear / maintenance lives on a second page, toggled from the header.
-- Pack marking (old PackMark) lives on the Fight page: Mark + Clear.

local ADDON = "BotCtrl"

BINDING_HEADER_BOTCTRL = "BotCtrl"
BINDING_NAME_BOTCTRL_FOLLOW   = "Party: Follow"
BINDING_NAME_BOTCTRL_STAY     = "Party: Hold / stay"
BINDING_NAME_BOTCTRL_SUMMON   = "Party: Summon"
BINDING_NAME_BOTCTRL_DRINK    = "Party: Sit and drink"
BINDING_NAME_BOTCTRL_FLEE     = "Party: Run / flee"
BINDING_NAME_BOTCTRL_TANKHOLD = "Tank: Come and hold"
BINDING_NAME_BOTCTRL_TANKPULL = "Tank: Open the pack"
BINDING_NAME_BOTCTRL_TANKGO   = "Tank: Go / attack"
BINDING_NAME_BOTCTRL_ATTACK   = "DPS: Kill my target"
BINDING_NAME_BOTCTRL_BURN     = "DPS: Burn (max dps)"
BINDING_NAME_BOTCTRL_SKULL    = "Kill order: skull + attack"
BINDING_NAME_BOTCTRL_WATER    = "Mage: Conjure water"
BINDING_NAME_BOTCTRL_LOOP     = "Dungeon loop: next step"
BINDING_NAME_BOTCTRL_SETUP    = "Setup roles (once per session)"
BINDING_NAME_BOTCTRL_MARK     = "Toggle pack marking"
BINDING_NAME_BOTCTRL_CLEAR    = "Clear raid marks"

-- Class is a weak hint only. Fury warrior must not beat prot paladin.
local TANK_CLASSES = {
	WARRIOR = true,
	PALADIN = true,
	DEATHKNIGHT = true,
	DRUID = true,
}

-- WotLK 3.3.5 spellIds (enUS client).
local TANK_AURA = {
	[71] = true,    -- Defensive Stance
	[25780] = true, -- Righteous Fury
	[48263] = true, -- Frost Presence (DK tank presence)
	[9634] = true,  -- Dire Bear Form
	[5487] = true,  -- Bear Form
}

local DPS_STANCE = {
	[2458] = true,  -- Berserker Stance (fury)
	[48265] = true, -- Unholy Presence
	[48266] = true, -- Blood Presence
}

local AUTO_TANK_MIN = 40 -- need a real tank signal (aura or shield), not just class

local OVERRIDE_KEYS = {
	{ key = "1",       cmd = "BOTCTRL_FOLLOW" },
	{ key = "2",       cmd = "BOTCTRL_STAY" },
	{ key = "3",       cmd = "BOTCTRL_SUMMON" },
	{ key = "4",       cmd = "BOTCTRL_DRINK" },
	{ key = "5",       cmd = "BOTCTRL_FLEE" },
	{ key = "SHIFT-1", cmd = "BOTCTRL_TANKHOLD" },
	{ key = "SHIFT-2", cmd = "BOTCTRL_TANKPULL" },
	{ key = "SHIFT-3", cmd = "BOTCTRL_TANKGO" },
	{ key = "CTRL-1",  cmd = "BOTCTRL_ATTACK" },
	{ key = "CTRL-2",  cmd = "BOTCTRL_BURN" },
	{ key = "CTRL-3",  cmd = "BOTCTRL_SKULL" },
	{ key = "CTRL-4",  cmd = "BOTCTRL_WATER" },
	{ key = "CTRL-5",  cmd = "BOTCTRL_LOOP" },
}

-- Dungeon loop. After the opener, pack clears jump back to tank-pull.
local LOOP = {
	{ id = "summon", label = "Summon",      hint = "after a wipe / instance" },
	{ id = "follow", label = "Follow",      hint = "stack on you" },
	{ id = "drink",  label = "Drink",       hint = "you drink too" },
	{ id = "pull",   label = "Tank pull",   hint = "target the pack first" },
	{ id = "skull",  label = "Skull+kill",  hint = "mark target, rti, attack" },
	{ id = "stay",   label = "Stay",        hint = "if they chain" },
	{ id = "drink2", label = "Drink",       hint = "mana break" },
	{ id = "follow2",label = "Follow",      hint = "next pack" },
}

local defaults = {
	locked = false,
	shown = true,
	useBinds = false,
	point = "CENTER",
	relPoint = "CENTER",
	x = 0,
	y = -260,
	roles = {}, -- [name] = "tank"|"dps"|"heal"
	markEnabled = false,
	markMelee = true,
	clearOnCombatEnd = true,
}

local db
local ui
local setupDone = false
local loopIndex = 1
local lastCmd = ""
local bindsPending = false
local queue = {}
local qElapsed = 0
local rosterCache = { tank = nil, dps = {}, heal = {}, mage = {}, all = {} }

local driver = CreateFrame("Frame")

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100BotCtrl|r: " .. tostring(msg))
end

local function CopyDefaults(src, dst)
	if type(dst) ~= "table" then dst = {} end
	for k, v in pairs(src) do
		if dst[k] == nil then
			if type(v) == "table" then
				dst[k] = CopyDefaults(v, {})
			else
				dst[k] = v
			end
		end
	end
	return dst
end

local function InGroup()
	return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

local function ChatChan()
	if GetNumRaidMembers() > 0 then
		return "RAID"
	end
	return "PARTY"
end

local function ClassColor(classFile)
	local c = RAID_CLASS_COLORS and classFile and RAID_CLASS_COLORS[classFile]
	if not c then
		return "|cffffffff"
	end
	return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function ShortName(name)
	if not name then return "?" end
	if #name > 9 then
		return name:sub(1, 9)
	end
	return name
end

local function EachMember(fn)
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local u = "raid" .. i
			if UnitExists(u) and not UnitIsUnit(u, "player") and UnitIsPlayer(u) then
				local name = UnitName(u)
				local _, classFile = UnitClass(u)
				if name then
					fn(u, name, classFile)
				end
			end
		end
	else
		for i = 1, GetNumPartyMembers() do
			local u = "party" .. i
			if UnitExists(u) and UnitIsPlayer(u) then
				local name = UnitName(u)
				local _, classFile = UnitClass(u)
				if name then
					fn(u, name, classFile)
				end
			end
		end
	end
end

-----------------------------------------------------------------------
-- Chat queue (bots drop stacked whispers if they arrive same tick)
-----------------------------------------------------------------------

local function Enqueue(msg, chan, target)
	queue[#queue + 1] = { msg = msg, chan = chan, target = target }
end

local function Party(msg)
	if not InGroup() then
		Print("Not in a party.")
		return false
	end
	Enqueue(msg, ChatChan(), nil)
	lastCmd = "/p " .. msg
	return true
end

local function Whisper(name, msg)
	if not name then
		Print("No target bot for: " .. tostring(msg))
		return false
	end
	Enqueue(msg, "WHISPER", name)
	lastCmd = "/w " .. name .. " " .. msg
	return true
end

local function FlushQueue(dt)
	if #queue == 0 then
		qElapsed = 0
		return
	end
	qElapsed = qElapsed + dt
	if qElapsed < 0.18 then
		return
	end
	qElapsed = 0
	local item = table.remove(queue, 1)
	if item.chan == "WHISPER" then
		SendChatMessage(item.msg, "WHISPER", nil, item.target)
	else
		SendChatMessage(item.msg, item.chan)
	end
	if ui and ui.RefreshStatus then
		ui:RefreshStatus()
	end
end

-----------------------------------------------------------------------
-- Roster / roles
-----------------------------------------------------------------------

local function HasAuraId(unit, idset)
	if not unit or not UnitExists(unit) then return false end
	for i = 1, 40 do
		local name, _, _, _, _, _, _, _, _, _, spellId = UnitBuff(unit, i)
		if not name then break end
		if spellId and idset[spellId] then
			return true
		end
	end
	return false
end

local function HasShield(unit)
	local link = GetInventoryItemLink(unit, 17)
	if not link then return false end
	local _, _, _, _, _, _, _, _, loc = GetItemInfo(link)
	return loc == "INVTYPE_SHIELD"
end

-- Real tank signals beat class. Prot pala (RF + shield) outranks fury warrior.
local function TankScore(unit, classFile)
	local score = 0
	local tankAura = HasAuraId(unit, TANK_AURA)
	local dpsStance = HasAuraId(unit, DPS_STANCE)
	local shield = HasShield(unit)

	if tankAura then
		score = score + 100
	elseif TANK_CLASSES[classFile] then
		score = score + 15
	end
	if shield then
		score = score + 50
	end
	if dpsStance then
		score = score - 40
	end
	if (classFile == "WARRIOR" or classFile == "PALADIN") and not shield and not tankAura then
		score = score - 35
	end
	return score, tankAura, shield
end

local function RebuildRoster()
	local all = {}
	local mages = {}
	local named = {}
	local prevTank = rosterCache.tank and rosterCache.tank.name

	EachMember(function(unit, name, classFile)
		local rec = {
			unit = unit,
			name = name,
			class = classFile,
			role = db and db.roles[name] or nil,
		}
		all[#all + 1] = rec
		named[name] = rec
		if classFile == "MAGE" then
			mages[#mages + 1] = rec
		end
	end)

	-- Clicked /slash role is the only lock. Never prefer "warrior" just because.
	local tank
	for i = 1, #all do
		if all[i].role == "tank" then
			tank = all[i]
			break
		end
	end

	if not tank then
		local best, bestScore = nil, -999
		for i = 1, #all do
			local rec = all[i]
			if rec.role ~= "dps" and rec.role ~= "heal" then
				local score = TankScore(rec.unit, rec.class)
				rec.tankScore = score
				if score > bestScore or (score == bestScore and prevTank == rec.name) then
					best = rec
					bestScore = score
				end
			end
		end
		if best and bestScore >= AUTO_TANK_MIN then
			tank = best
			if prevTank and prevTank ~= tank.name then
				Print("Tank auto: " .. tank.name .. " (stance / Righteous Fury / shield). Click a name to lock.")
			end
		end
	end

	local dps, heal = {}, {}
	for i = 1, #all do
		local rec = all[i]
		if tank and rec.name == tank.name then
			rec.role = "tank"
		elseif rec.role == "heal" then
			heal[#heal + 1] = rec
		else
			rec.role = "dps"
			dps[#dps + 1] = rec
		end
	end

	if tank and db then
		db.tankName = tank.name
	end

	rosterCache = {
		tank = tank,
		dps = dps,
		heal = heal,
		mage = mages,
		all = all,
		named = named,
	}
	return rosterCache
end

local function TankName()
	local r = rosterCache.tank
	return r and r.name or nil
end

local function SetRole(name, role)
	if not db or not name then return end
	if role == "tank" then
		for n, r in pairs(db.roles) do
			if r == "tank" and n ~= name then
				db.roles[n] = "dps"
			end
		end
		db.roles[name] = "tank"
		db.tankName = name
	else
		db.roles[name] = role
		if db.tankName == name and role ~= "tank" then
			db.tankName = nil
		end
	end
	setupDone = false
	RebuildRoster()
	if ui and ui.Refresh then
		ui:Refresh()
	end
end

local function ResolveName(raw)
	if not raw or raw == "" then return nil end
	RebuildRoster()
	local lower = raw:lower()
	if rosterCache.named then
		for name in pairs(rosterCache.named) do
			if name:lower() == lower then
				return name
			end
		end
	end
	return raw
end

-----------------------------------------------------------------------
-- Pack marking (folded in from PackMark)
-- Hover nameplates: casters/healers get skull. Fight-page Mark / Clear.
-- Skull/rti will not steal an existing pack skull onto your target.
-----------------------------------------------------------------------

local MARK_ORDER = { 8, 7, 6, 5, 3, 4, 1, 2 }
local SCAN_UNITS = {
	"mouseover", "target", "focus", "pettarget",
	"party1target", "party2target", "party3target", "party4target",
}
local HEALER_WORDS = {
	"healer", "priest", "medic", "cleric", "druid", "shaman", "restorer",
	"mender", "oracle", "soothsayer", "bishop", "confessor", "apothecary",
	"high priest", "witch doctor", "medicine", "surgeon", "acolyte",
	"adherent", "templar", "vicar", "hierophant",
}
local CASTER_WORDS = {
	"mage", "sorcer", "wizard", "warlock", "necro", "shadowcaster",
	"darkweaver", "invoker", "conjur", "channeler", "geomancer",
	"pyromancer", "cryomancer", "arcanist", "spellweaver", "runecaster",
	"hexer", "witch", "cultist", "magus", "evoker", "enchanter",
	"thaumaturge", "occultist", "summoner", "ritualist", "illusionist",
	"elementalist", "stormcaller", "archmage", "battlemage", "shadowmage",
	"spellbinder", "cabalist", "theurgist", "adept", "diviner", "prophet",
	"lich", "bonecaster", "voidweaver", "soulweaver", "animator",
	"necrolyte", "spellfury", "hexweaver", "darkmage", "bloodmage",
	"deathweaver", "scholar", "apostle", "seer", "mystic", "siren",
	"magelord", "spelllord", "frostweaver", "fireweaver", "plaguebringer",
	"shadow priest", "dark priest", "necromancer",
}
local CASTER_CLASSES = {
	MAGE = true, PRIEST = true, WARLOCK = true, SHAMAN = true,
	DRUID = true, PALADIN = true,
}
local HEALER_CLASSES = {
	PRIEST = true, SHAMAN = true, DRUID = true, PALADIN = true,
}

local pack = {}
local seenCast = {}
local markElapsed = 0
local announcedGroup = false

local function RaidIconPath(index)
	return "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. tostring(index)
end

local function InRaid()
	return GetNumRaidMembers() > 0
end

local function CanMark()
	if InRaid() then
		return IsRaidLeader() or IsRaidOfficer()
	end
	return true
end

local function IsCreatureGUID(guid)
	if type(guid) ~= "string" or #guid < 5 then return false end
	local prefix = guid:sub(3, 5)
	return prefix == "F13" or prefix == "F15"
end

local function NameHasWord(name, list)
	if not name then return false end
	for i = 1, #list do
		if name:find(list[i], 1, true) then
			return true
		end
	end
	return false
end

local function IsSkippable(unit)
	if not UnitExists(unit) then return true end
	if UnitIsPlayer(unit) then return true end
	if UnitPlayerControlled(unit) then return true end
	if UnitIsDead(unit) or UnitIsCorpse(unit) then return true end
	if not UnitCanAttack("player", unit) then return true end
	if UnitIsFriend("player", unit) then return true end
	local ctype = UnitCreatureType(unit)
	if ctype == "Critter" or ctype == "Not specified" then return true end
	local n = UnitName(unit)
	if n and n:find("Totem") then return true end
	if UnitClassification(unit) == "trivial" then return true end
	return false
end

local function ScoreUnit(unit)
	local guid = UnitGUID(unit)
	local rawName = UnitName(unit) or "?"
	local name = rawName:lower()
	local score = 10
	local reason = "melee"
	local _, classFile = UnitClass(unit)

	if NameHasWord(name, HEALER_WORDS) or (classFile and HEALER_CLASSES[classFile]) then
		score = 100
		reason = "healer"
	elseif NameHasWord(name, CASTER_WORDS) or (classFile and CASTER_CLASSES[classFile]) then
		score = 90
		reason = "caster"
	elseif seenCast[guid] == "heal" then
		score = 100
		reason = "healing"
	elseif seenCast[guid] == "cast" then
		score = 80
		reason = "casting"
	else
		local ptype = UnitPowerType(unit)
		local pmax = UnitPowerMax(unit, 0)
		if ptype == 0 and pmax and pmax > 0 then
			score = 75
			reason = "mana"
		end
	end

	local classif = UnitClassification(unit)
	if classif == "worldboss" or classif == "rareelite" then
		score = score + 15
	elseif classif == "elite" then
		score = score + 8
	elseif classif == "rare" then
		score = score + 5
	end

	return score, reason, rawName, guid
end

local function VisibleUnits()
	local list = {}
	for i = 1, #SCAN_UNITS do
		list[#list + 1] = SCAN_UNITS[i]
	end
	if InRaid() then
		local n = GetNumRaidMembers()
		if n > 25 then n = 25 end
		for i = 1, n do
			list[#list + 1] = "raid" .. i .. "target"
		end
	end
	return list
end

local function Remember(unit)
	if IsSkippable(unit) then return end
	local score, reason, name, guid = ScoreUnit(unit)
	if not guid then return end
	local rec = pack[guid]
	if rec then
		if score > rec.score then
			rec.score = score
			rec.reason = reason
		end
		rec.name = name
		rec.seen = GetTime()
	else
		pack[guid] = {
			score = score,
			reason = reason,
			name = name,
			seen = GetTime(),
			guid = guid,
		}
	end
end

local function PackList()
	local now = GetTime()
	local list = {}
	for guid, rec in pairs(pack) do
		if (now - rec.seen) > 20 then
			pack[guid] = nil
		else
			list[#list + 1] = rec
		end
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.mark and b.mark then
			return a.mark > b.mark
		end
		return a.seen < b.seen
	end)
	return list
end

local function NextFreeMark(used)
	for i = 1, #MARK_ORDER do
		local m = MARK_ORDER[i]
		if not used[m] then
			return m
		end
	end
	return nil
end

-- Assign once. Do not reshuffle every sweep — that is what spammed
-- "sets skull / X" between Earthborer and the elemental.
-- Skull may move onto a caster/healer that scores clearly higher.
local function RankPack()
	local list = PackList()
	local used = {}
	local skullHolder
	for i = 1, #list do
		local rec = list[i]
		if rec.mark then
			used[rec.mark] = rec
			if rec.mark == 8 then
				skullHolder = rec
			end
		end
	end

	local best = list[1]
	if best and best.score >= 80 and (not skullHolder or (skullHolder.guid ~= best.guid and skullHolder.score + 15 < best.score)) then
		if skullHolder then
			local old = best.mark
			skullHolder.mark = old
			if old then
				used[old] = skullHolder
			end
		end
		best.mark = 8
		used[8] = best
		used = {}
		for i = 1, #list do
			if list[i].mark then
				used[list[i].mark] = list[i]
			end
		end
	end

	for i = 1, #list do
		local rec = list[i]
		if not rec.mark then
			if (not db or db.markMelee) or rec.score >= 65 then
				local m = NextFreeMark(used)
				if m then
					rec.mark = m
					used[m] = rec
				end
			end
		end
	end
	return list
end

-- Painting skull must not start a fight. Leftover "rti skull" from the last
-- Kill would send bots into the new caster as soon as Mark assigns skull.
local function ClearRti()
	if InGroup() then
		Enqueue("rti none", ChatChan(), nil)
		lastCmd = "/p rti none"
	end
end

local function ApplyVisible()
	if not db or not db.markEnabled then return end
	if not CanMark() then
		if InRaid() and not announcedGroup then
			Print("Need raid lead or assist to mark.")
			announcedGroup = true
		end
		return
	end

	local units = VisibleUnits()
	local visGuids = {}
	local visCount = 0
	local overlap = false
	for i = 1, #units do
		local unit = units[i]
		if not IsSkippable(unit) then
			local guid = UnitGUID(unit)
			if guid and not visGuids[guid] then
				visGuids[guid] = unit
				visCount = visCount + 1
				if pack[guid] then
					overlap = true
				end
			end
		end
	end

	-- Need a real new pack (2+ unseen mobs). One tank-target swap must not
	-- wipe Earthborer + elemental and reshuffle icons.
	if visCount >= 2 and not overlap and next(pack) then
		wipe(pack)
		ClearRti()
	end

	if not UnitAffectingCombat("player") then
		for guid, unit in pairs(visGuids) do
			Remember(unit)
		end
		RankPack()
	end

	for guid, unit in pairs(visGuids) do
		local rec = pack[guid]
		local want = rec and rec.mark
		local have = GetRaidTargetIndex(unit) or 0
		if want and have ~= want then
			SetRaidTarget(unit, want)
		end
	end

	if ui and ui.RefreshStatus then
		ui:RefreshStatus()
	end
end

local function ClearMarks()
	local units = {
		"player", "target", "focus", "mouseover", "pet",
		"party1", "party2", "party3", "party4",
		"party1target", "party2target", "party3target", "party4target",
	}
	if InRaid() then
		for i = 1, GetNumRaidMembers() do
			units[#units + 1] = "raid" .. i
			units[#units + 1] = "raid" .. i .. "target"
		end
	end
	for i = 1, #units do
		local u = units[i]
		if UnitExists(u) and (GetRaidTargetIndex(u) or 0) > 0 then
			SetRaidTarget(u, 0)
		end
	end
	wipe(pack)
	if ui and ui.RefreshStatus then
		ui:RefreshStatus()
	end
end

local function WipePack()
	wipe(pack)
	wipe(seenCast)
	if db and db.clearOnCombatEnd then
		ClearMarks()
	elseif ui and ui.RefreshStatus then
		ui:RefreshStatus()
	end
end

local function HasPackSkull()
	for _, rec in pairs(pack) do
		if rec.mark == 8 then
			return true
		end
	end
	local units = VisibleUnits()
	for i = 1, #units do
		local u = units[i]
		if UnitExists(u) and (GetRaidTargetIndex(u) or 0) == 8 then
			return true
		end
	end
	return false
end

local function MarkStatusText()
	if not db or not db.markEnabled then
		return nil
	end
	local ranked = PackList()
	local parts = {}
	local n = #ranked
	if n > 3 then n = 3 end
	for i = 1, n do
		local rec = ranked[i]
		if rec.mark then
			local iconTex = "|T" .. RaidIconPath(rec.mark) .. ":12:12|t"
			local short = rec.name or "?"
			if #short > 8 then
				short = short:sub(1, 8)
			end
			parts[#parts + 1] = iconTex .. "|cffffdd66" .. short .. "|r"
		end
	end
	if #parts == 0 then
		return "|cff888888hover plates (V)|r"
	end
	return table.concat(parts, " ")
end

local function NoteCast(subevent, sourceGUID, destGUID)
	if subevent == "UNIT_DIED" then
		if destGUID and pack[destGUID] then
			pack[destGUID] = nil
			seenCast[destGUID] = nil
			if db and db.markEnabled then
				ApplyVisible()
			end
		end
	elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
		if IsCreatureGUID(sourceGUID) then
			seenCast[sourceGUID] = "heal"
		end
	elseif subevent == "SPELL_CAST_START" then
		if IsCreatureGUID(sourceGUID) and seenCast[sourceGUID] ~= "heal" then
			seenCast[sourceGUID] = "cast"
		end
	end
end

-----------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------

local function NeedGroup()
	if InGroup() then return true end
	Print("Not in a party.")
	return false
end

local function NeedTank()
	RebuildRoster()
	local name = TankName()
	if name then return name end
	Print("No tank. Click a name on the bar, or /bot tank Name")
	return nil
end

local function CmdFollow()
	if Party("follow") then
		Print("Follow")
		return true
	end
end

local function CmdStay()
	if Party("stay") then
		Print("Hold")
		return true
	end
end

local function CmdSummon()
	if Party("summon") then
		Print("Summon")
		return true
	end
end

local function CmdDrink()
	if Party("drink") then
		Print("Drink - you drink too.")
		return true
	end
end

local function CmdFlee()
	if Party("flee") then
		Print("Run")
		return true
	end
end

local function CmdTankHold()
	local name = NeedTank()
	if not name then return end
	Whisper(name, "follow")
	Whisper(name, "stay")
	Print("Tank " .. name .. ": come and hold")
	return true
end

local function CmdTankPull()
	local name = NeedTank()
	if not name then return end
	if not UnitExists("target") then
		Print("Target the pack first.")
		return
	end
	Whisper(name, "pull")
	Print("Tank " .. name .. ": pull")
	return true
end

local function CmdTankGo()
	if Party("tank attack") then
		Print("Tank go")
		return true
	end
end

local function CmdAttack()
	if Party("attack") then
		Print("Kill my target")
		return true
	end
end

local function CmdBurn()
	if Party("max dps") then
		Print("Burn")
		return true
	end
end

local function CmdSkull()
	if not NeedGroup() then return end
	if HasPackSkull() then
		Party("rti skull")
		Party("attack")
		Print("RTI skull (pack mark kept) -> attack")
		return true
	end
	if not UnitExists("target") or UnitIsFriend("player", "target") then
		Print("Need an enemy target to skull, or hover-mark the pack first.")
		return
	end
	SetRaidTarget("target", 8)
	Party("rti skull")
	Party("attack")
	Print("Skull -> rti skull -> attack")
	return true
end

local function CmdMarkToggle()
	if not db then return end
	db.markEnabled = not db.markEnabled
	announcedGroup = false
	if db.markEnabled then
		ClearRti()
		Print("Mark ON - hover nameplates (V). Icons only, no attack. Pull / Go / Kill to fight.")
		ApplyVisible()
	else
		Print("Mark OFF")
	end
	if ui and ui.Refresh then
		ui:Refresh()
	end
	return true
end

local function CmdMarkClear()
	ClearMarks()
	ClearRti()
	Print("Marks cleared.")
	return true
end

local function CmdWater()
	RebuildRoster()
	if #rosterCache.mage == 0 then
		Print("No mage in the party.")
		return
	end
	for i = 1, #rosterCache.mage do
		Whisper(rosterCache.mage[i].name, "cast conjure water")
	end
	Print("Mage: conjure water")
	return true
end

local function CmdSetup()
	if not NeedGroup() then return end
	RebuildRoster()
	local tank = TankName()
	if not tank then
		Print("Pick a tank first (click a name).")
		return
	end
	Whisper(tank, "co +tank")
	Whisper(tank, "nc +follow")
	for i = 1, #rosterCache.dps do
		Whisper(rosterCache.dps[i].name, "co +dps")
	end
	for i = 1, #rosterCache.heal do
		Whisper(rosterCache.heal[i].name, "co +heal")
	end
	setupDone = true
	Print("Roles sent. Tank " .. tank .. " (follow out of combat). Once per session.")
	if ui and ui.Refresh then
		ui:Refresh()
	end
	return true
end

local function CmdPrep(msg, label)
	if Party(msg) then
		Print(label or msg)
		return true
	end
end

local function CmdAutogear()
	return CmdPrep("autogear", "Autogear")
end

local function CmdMaint()
	return CmdPrep("maintenance", "Maintenance")
end

local function CmdRepair()
	return CmdPrep("repair", "Repair")
end

local function CmdTalents()
	return CmdPrep("talents", "Talents")
end

local function CmdTrain()
	if not UnitExists("target") or UnitIsPlayer("target") then
		Print("Target a trainer first.")
		return
	end
	return CmdPrep("trainer learn", "Trainer learn")
end

local function CmdSell()
	if not UnitExists("target") or UnitIsPlayer("target") then
		Print("Target a vendor first.")
		return
	end
	return CmdPrep("s *", "Sell greys")
end

local function CmdFood()
	return CmdPrep("food", "Eat")
end

local function CmdHome()
	if not UnitExists("target") or UnitIsPlayer("target") then
		Print("Target an innkeeper first.")
		return
	end
	return CmdPrep("home", "Set home")
end

local function CmdStats()
	return CmdPrep("stats", "Stats")
end

local function CmdLoot()
	return CmdPrep("ll normal", "Loot: normal (no BoP)")
end

local function CmdResetAI()
	return CmdPrep("reset botAI", "Reset bot AI")
end

local leaveArmedUntil = 0
local function CmdLeave()
	if not NeedGroup() then return end
	local now = GetTime()
	if now < leaveArmedUntil then
		leaveArmedUntil = 0
		Party("leave")
		Print("Bots leaving the party.")
		return true
	end
	leaveArmedUntil = now + 4
	Print("Leave armed. Click Leave again in 4s to confirm.")
	return
end

local function TogglePage()
	if not ui or not ui.SetPage then return end
	ui:SetPage((ui.page == "gear") and "combat" or "gear")
end

local function WipeOrInstanceReset()
	loopIndex = 1
end

local function PartyWiped()
	if UnitIsDeadOrGhost("player") then
		local anyAlive = false
		EachMember(function(unit)
			if not UnitIsDeadOrGhost(unit) then
				anyAlive = true
			end
		end)
		return not anyAlive
	end
	local anyDead = false
	local anyAlive = false
	EachMember(function(unit)
		if UnitIsDeadOrGhost(unit) then
			anyDead = true
		else
			anyAlive = true
		end
	end)
	return anyDead and not anyAlive
end

local function CmdLoop()
	if PartyWiped() then
		loopIndex = 1
	end
	local step = LOOP[loopIndex]
	if not step then
		loopIndex = 4
		step = LOOP[loopIndex]
	end

	local ok
	if step.id == "summon" then
		ok = CmdSummon()
	elseif step.id == "follow" or step.id == "follow2" then
		ok = CmdFollow()
	elseif step.id == "drink" or step.id == "drink2" then
		ok = CmdDrink()
	elseif step.id == "pull" then
		ok = CmdTankPull()
	elseif step.id == "skull" then
		ok = CmdSkull()
	elseif step.id == "stay" then
		ok = CmdStay()
	end

	if ok then
		loopIndex = loopIndex + 1
		if loopIndex > #LOOP then
			loopIndex = 4 -- next pack: tank pull
		end
	end
	if ui and ui.Refresh then
		ui:Refresh()
	end
end

local COMMANDS = {
	FOLLOW   = CmdFollow,
	STAY     = CmdStay,
	SUMMON   = CmdSummon,
	DRINK    = CmdDrink,
	FLEE     = CmdFlee,
	TANKHOLD = CmdTankHold,
	TANKPULL = CmdTankPull,
	TANKGO   = CmdTankGo,
	ATTACK   = CmdAttack,
	BURN     = CmdBurn,
	SKULL    = CmdSkull,
	WATER    = CmdWater,
	LOOP     = CmdLoop,
	SETUP    = CmdSetup,
	MARK     = CmdMarkToggle,
	CLEAR    = CmdMarkClear,
	AUTOGEAR = CmdAutogear,
	MAINT    = CmdMaint,
	REPAIR   = CmdRepair,
	TALENTS  = CmdTalents,
	TRAIN    = CmdTrain,
	SELL     = CmdSell,
	FOOD     = CmdFood,
	HOME     = CmdHome,
	STATS    = CmdStats,
	LOOT     = CmdLoot,
	RESETAI  = CmdResetAI,
	LEAVE    = CmdLeave,
}

function BotCtrl_Bind(which)
	if ui and ui.Flash then
		ui:Flash(which)
	end
	local fn = COMMANDS[which]
	if fn then
		fn()
	end
end

-----------------------------------------------------------------------
-- Override binds (1-5 / Shift / Ctrl) - session overlay, not permanent
-----------------------------------------------------------------------

local function ClearBinds()
	ClearOverrideBindings(driver)
	bindsPending = false
end

local function ApplyBinds()
	if InCombatLockdown() then
		bindsPending = true
		Print("Binds apply after combat.")
		return
	end
	ClearOverrideBindings(driver)
	if not db or not db.useBinds then
		bindsPending = false
		return
	end
	for i = 1, #OVERRIDE_KEYS do
		local row = OVERRIDE_KEYS[i]
		SetOverrideBinding(driver, false, row.key, row.cmd)
	end
	bindsPending = false
end

local function ToggleBinds()
	if InCombatLockdown() then
		Print("Can't change binds in combat.")
		return
	end
	db.useBinds = not db.useBinds
	ApplyBinds()
	if db.useBinds then
		Print("1-5 party, Shift tank, Ctrl DPS. Action-bar 1-5 is covered while this is on. /bot unbind to restore.")
	else
		Print("Override binds off. Action-bar 1-5 is yours again.")
	end
	if ui and ui.Refresh then
		ui:Refresh()
	end
end

-----------------------------------------------------------------------
-- Clickable widget (mirrors 1-5 / Shift / Ctrl)
-----------------------------------------------------------------------

local PARTY_COLOR = { 0.42, 0.30, 0.07, 0.95 }
local TANK_COLOR  = { 0.10, 0.28, 0.48, 0.95 }
local DPS_COLOR   = { 0.48, 0.12, 0.12, 0.95 }
local UTIL_COLOR  = { 0.18, 0.18, 0.20, 0.95 }
local LOOP_COLOR  = { 0.14, 0.38, 0.18, 0.95 }
local GEAR_COLOR  = { 0.32, 0.16, 0.42, 0.95 }
local WARN_COLOR  = { 0.48, 0.22, 0.08, 0.95 }

local flashBtn
local flashT = 0
local lastModKey = nil
local rosterDirty = false
local rosterElapsed = 0

local function PaintBtn(b, r, g, bl, a)
	if b and b.bg then
		b.bg:SetVertexColor(r, g, bl, a or 0.95)
	end
end

local function PaintFromColor(b, dim)
	if not b or not b.color then return end
	local c = b.color
	if dim then
		PaintBtn(b, c[1] * 0.35, c[2] * 0.35, c[3] * 0.35, 0.7)
	else
		PaintBtn(b, c[1], c[2], c[3], c[4] or 0.95)
	end
end

local function CurrentMod()
	local shift = IsShiftKeyDown()
	local ctrl = IsControlKeyDown()
	local alt = IsAltKeyDown()
	if alt or (shift and ctrl) then
		return "other"
	end
	if ctrl then
		return "ctrl"
	end
	if shift then
		return "shift"
	end
	return "none"
end

local function ChipAvailable(b)
	if not b or b.mod == "util" or b.mod == "mark" then
		return true
	end
	if not InGroup() then
		return false
	end
	local cmd = b.cmd
	if cmd == "TANKHOLD" or cmd == "TANKGO" then
		return TankName() ~= nil
	end
	if cmd == "TANKPULL" then
		if TankName() == nil then return false end
		return UnitExists("target") and not UnitIsFriend("player", "target")
	end
	if cmd == "WATER" then
		return rosterCache.mage and #rosterCache.mage > 0
	end
	if cmd == "SKULL" then
		if HasPackSkull() then return true end
		return UnitExists("target") and not UnitIsFriend("player", "target")
	end
	if cmd == "TRAIN" or cmd == "SELL" or cmd == "HOME" then
		return UnitExists("target") and not UnitIsPlayer("target")
	end
	return true
end

local function ChipActiveForMod(b, mod)
	if not b then return false end
	if b.mod == "util" then return false end
	if b.mod == "gear" then
		return ui and ui.page == "gear"
	end
	if b.mod == "mark" then
		return ui and ui.page ~= "gear"
	end
	if ui and ui.page == "gear" then
		return false
	end
	if b.mod == "party" then return mod == "none" end
	if b.mod == "tank" then return mod == "shift" end
	if b.mod == "dps" then return mod == "ctrl" end
	return false
end

local function PaintChip(b)
	if not b then return end
	local avail = ChipAvailable(b)
	b.dim = not avail

	if flashBtn == b or b.pressed then
		PaintBtn(b, 0.95, 0.80, 0.12, 1)
		if b.readyGlow then b.readyGlow:SetAlpha(0.85) end
		if b.labelFs then b.labelFs:SetTextColor(1, 1, 0.85) end
		if b.keyFs then b.keyFs:SetTextColor(1, 0.92, 0.35) end
		return
	end

	if b.mod == "util" then
		PaintFromColor(b, false)
		if b.readyGlow then b.readyGlow:SetAlpha(0) end
		if b.labelFs then b.labelFs:SetTextColor(0.92, 0.92, 0.92) end
		return
	end

	local active = ChipActiveForMod(b, CurrentMod())
	if active and avail then
		PaintFromColor(b, false)
		if b.readyGlow then b.readyGlow:SetAlpha(0.58) end
		if b.labelFs then b.labelFs:SetTextColor(1, 1, 1) end
		if b.keyFs then b.keyFs:SetTextColor(1, 0.85, 0.25) end
	elseif active and not avail then
		PaintFromColor(b, true)
		if b.readyGlow then b.readyGlow:SetAlpha(0.12) end
		if b.labelFs then b.labelFs:SetTextColor(0.55, 0.55, 0.55) end
		if b.keyFs then b.keyFs:SetTextColor(0.45, 0.45, 0.45) end
	else
		PaintFromColor(b, true)
		if b.readyGlow then b.readyGlow:SetAlpha(0) end
		if b.labelFs then b.labelFs:SetTextColor(0.42, 0.42, 0.42) end
		if b.keyFs then b.keyFs:SetTextColor(0.35, 0.35, 0.35) end
	end
end

local function ApplyModifierLook()
	if not ui then return end
	local mod = CurrentMod()
	lastModKey = mod
	if ui.rowGlows then
		local g = ui.rowGlows
		local onGear = ui.page == "gear"
		if g.party then g.party:SetAlpha((not onGear and mod == "none") and 0.42 or 0) end
		if g.tank then g.tank:SetAlpha((not onGear and mod == "shift") and 0.50 or 0) end
		if g.dps then g.dps:SetAlpha((not onGear and mod == "ctrl") and 0.50 or 0) end
		local gearA = onGear and 0.38 or 0
		if g.gear1 then g.gear1:SetAlpha(gearA) end
		if g.gear2 then g.gear2:SetAlpha(gearA) end
		if g.gear3 then g.gear3:SetAlpha(gearA) end
	end
	if ui.chips then
		for _, b in pairs(ui.chips) do
			PaintChip(b)
		end
	end
	if ui.RefreshStatus then
		ui:RefreshStatus()
	end
end

local function FlashBtn(b)
	if flashBtn and flashBtn ~= b then
		PaintChip(flashBtn)
	end
	flashBtn = b
	flashT = 0.32
	PaintChip(b)
end

local function FlashTick(dt)
	if not flashBtn then return end
	flashT = flashT - dt
	if flashT <= 0 then
		local b = flashBtn
		flashBtn = nil
		PaintChip(b)
	end
end

local function SavePosition(frame)
	local point, _, relPoint, x, y = frame:GetPoint()
	db.point = point
	db.relPoint = relPoint
	db.x = x
	db.y = y
end

local function Tip(frame, title, lines)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(title, 1, 0.82, 0)
		if lines then
			for i = 1, #lines do
				GameTooltip:AddLine(lines[i], 1, 1, 1, true)
			end
		end
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function MakeChip(parent, label, keyText, width, click, title, lines, color, cmd, mod)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(width)
	b:SetHeight(22)
	b.color = color
	b.cmd = cmd
	b.mod = mod
	b.dim = false
	b.pressed = false

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
	b.bg = bg

	local glow = b:CreateTexture(nil, "ARTWORK")
	glow:SetAllPoints()
	glow:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight")
	glow:SetBlendMode("ADD")
	glow:SetAlpha(0)
	b.readyGlow = glow

	local hi = b:CreateTexture(nil, "HIGHLIGHT")
	hi:SetAllPoints()
	hi:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight")
	hi:SetBlendMode("ADD")
	hi:SetAlpha(0.28)
	b:SetHighlightTexture(hi)

	local key = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	key:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -2)
	key:SetText(keyText or "")
	b.keyFs = key

	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 2)
	fs:SetText(label)
	b.labelFs = fs

	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnMouseDown", function(self)
		self.pressed = true
		PaintChip(self)
	end)
	b:SetScript("OnMouseUp", function(self)
		-- OnClick runs next; keep the pressed look until FlashBtn takes over.
	end)
	b:SetScript("OnLeave", function(self)
		if self.pressed then
			self.pressed = false
			PaintChip(self)
		end
		GameTooltip:Hide()
	end)
	b:SetScript("OnClick", function(self)
		self.pressed = false
		FlashBtn(self)
		if click then
			click()
		end
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(title, 1, 0.82, 0)
		if lines then
			for i = 1, #lines do
				GameTooltip:AddLine(lines[i], 1, 1, 1, true)
			end
		end
		local mod = CurrentMod()
		if ChipActiveForMod(self, mod) and ChipAvailable(self) then
			GameTooltip:AddLine("Live for this modifier", 0.4, 1, 0.4)
		elseif not ChipAvailable(self) then
			GameTooltip:AddLine("Not available right now", 1, 0.4, 0.4)
		else
			GameTooltip:AddLine("Hold the modifier to arm this row", 0.7, 0.7, 0.7)
		end
		GameTooltip:Show()
	end)
	PaintChip(b)
	return b
end

local function NextLoopLabel()
	if PartyWiped() then
		return "Next: Summon (wipe)"
	end
	local step = LOOP[loopIndex] or LOOP[1]
	return "Next: " .. step.label
end

local function BuildUI()
	local f = CreateFrame("Frame", "BotCtrlUI", UIParent)
	f:SetWidth(322)
	f:SetHeight(148)
	f:SetPoint(db.point or "CENTER", UIParent, db.relPoint or "CENTER", db.x or 0, db.y or -260)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0.05, 0.05, 0.07, 0.94)
	f:SetBackdropBorderColor(0.65, 0.55, 0.20, 0.9)

	f:SetScript("OnDragStart", function(self)
		if not db.locked then
			self:StartMoving()
		end
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition(self)
	end)

	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetWidth(16)
	icon:SetHeight(16)
	icon:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -7)
	icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", icon, "RIGHT", 5, 0)
	title:SetText("BotCtrl")

	local lock = CreateFrame("Button", nil, f)
	lock:SetWidth(16)
	lock:SetHeight(16)
	lock:SetPoint("TOPRIGHT", f, "TOPRIGHT", -7, -7)
	local lockTex = lock:CreateTexture(nil, "ARTWORK")
	lockTex:SetAllPoints()
	lockTex:SetTexture("Interface\\Buttons\\LockButton-Unlocked-Up")
	lock.tex = lockTex
	lock:SetScript("OnClick", function()
		db.locked = not db.locked
		if db.locked then
			lock.tex:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")
		else
			lock.tex:SetTexture("Interface\\Buttons\\LockButton-Unlocked-Up")
		end
	end)
	Tip(lock, "Lock bar", { "Stop the bar from moving. Drag the frame to place it." })
	if db.locked then
		lockTex:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")
	end
	f.lock = lock

	local chips = {}
	f.chips = chips

	local setup = MakeChip(f, "Setup", "", 48, CmdSetup, "Setup roles (once per session)", {
		"Whispers co +tank / nc +follow to the tank,",
		"co +dps to everyone else.",
		"Not a combat key. Run after invite.",
	}, UTIL_COLOR, "SETUP", "util")
	setup:SetPoint("RIGHT", lock, "LEFT", -4, 0)
	setup.keyFs:SetText("")
	setup.labelFs:ClearAllPoints()
	setup.labelFs:SetPoint("CENTER", setup, "CENTER", 0, 0)
	f.setup = setup
	chips.SETUP = setup

	local binds = MakeChip(f, "Binds", "", 48, ToggleBinds, "Bind 1-5 / Shift / Ctrl", {
		"Party 1-5, tank on Shift, DPS on Ctrl.",
		"Override only - your saved action-bar binds stay.",
		"/bot unbind to release 1-5.",
		"Never bound: autogear, leave.",
	}, UTIL_COLOR, "BINDS", "util")
	binds:SetPoint("RIGHT", setup, "LEFT", -3, 0)
	binds.keyFs:SetText("")
	binds.labelFs:ClearAllPoints()
	binds.labelFs:SetPoint("CENTER", binds, "CENTER", 0, 0)
	f.binds = binds
	chips.BINDS = binds

	local pageBtn = MakeChip(f, "Gear", "", 48, TogglePage, "Toggle Gear / Fight", {
		"Combat page: follow, tank, DPS (1-5 / Shift / Ctrl).",
		"Gear page: autogear, repair, talents, sell, leave.",
		"1-5 still fire combat even on the Gear page.",
		"Autogear and leave are never combat keys.",
	}, UTIL_COLOR, "PAGE", "util")
	pageBtn:SetPoint("RIGHT", binds, "LEFT", -3, 0)
	pageBtn.keyFs:SetText("")
	pageBtn.labelFs:ClearAllPoints()
	pageBtn.labelFs:SetPoint("CENTER", pageBtn, "CENTER", 0, 0)
	f.pageBtn = pageBtn
	chips.PAGE = pageBtn

	-- Clickable roster: left-click sets tank, right-click marks healer.
	local rosterBtns = {}
	for i = 1, 4 do
		local b = CreateFrame("Button", nil, f)
		b:SetWidth(74)
		b:SetHeight(16)
		if i == 1 then
			b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -26)
		else
			b:SetPoint("LEFT", rosterBtns[i - 1], "RIGHT", 3, 0)
		end
		local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetAllPoints()
		fs:SetJustifyH("LEFT")
		b.fs = fs
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			if not self.botName then return end
			if button == "RightButton" then
				local rec = rosterCache.named and rosterCache.named[self.botName]
				if rec and rec.role == "heal" then
					SetRole(self.botName, "dps")
					Print(self.botName .. " -> DPS")
				else
					SetRole(self.botName, "heal")
					Print(self.botName .. " -> heal")
				end
			else
				SetRole(self.botName, "tank")
				Print(self.botName .. " -> tank")
			end
		end)
		b:SetScript("OnEnter", function(self)
			if not self.botName then return end
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(self.botName, 1, 0.82, 0)
			GameTooltip:AddLine("Left-click: lock as tank", 1, 1, 1)
			GameTooltip:AddLine("Right-click: healer / DPS", 1, 1, 1)
			GameTooltip:AddLine("Auto-tank uses Righteous Fury, Defensive Stance,", 0.7, 0.7, 0.7, true)
			GameTooltip:AddLine("Frost Presence, bear form, or a shield.", 0.7, 0.7, 0.7, true)
			GameTooltip:AddLine("Fury warrior loses to prot paladin.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		rosterBtns[i] = b
	end
	f.rosterBtns = rosterBtns

	local w = 58
	local gap = 4

	local function PlaceRow(specs, color, anchor, yOff, mod)
		local row = {}
		for i = 1, #specs do
			local s = specs[i]
			local b = MakeChip(f, s.label, s.key, s.width or w, s.click, s.title, s.lines, s.color or color, s.cmd, s.mod or mod)
			if i == 1 then
				if type(anchor) == "table" then
					b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -4)
				else
					b:SetPoint("TOPLEFT", f, "TOPLEFT", 8, anchor)
				end
			else
				b:SetPoint("LEFT", row[i - 1], "RIGHT", gap, 0)
			end
			if s.cmd then
				chips[s.cmd] = b
			end
			if not s.key or s.key == "" then
				b.keyFs:SetText("")
				b.labelFs:ClearAllPoints()
				b.labelFs:SetPoint("CENTER", b, "CENTER", 0, 0)
			end
			row[i] = b
		end
		return row
	end

	local function MakeRowGlow(left, right)
		local t = f:CreateTexture(nil, "BACKGROUND")
		t:SetPoint("TOPLEFT", left, "TOPLEFT", -3, 3)
		t:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 3, -3)
		t:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight")
		t:SetBlendMode("ADD")
		t:SetAlpha(0)
		return t
	end

	local partyRow = PlaceRow({
		{ label = "Follow", key = "1", cmd = "FOLLOW", click = CmdFollow,
		  title = "1  Follow", lines = { "Party: follow you." } },
		{ label = "Stay", key = "2", cmd = "STAY", click = CmdStay,
		  title = "2  Hold", lines = { "Party: stay put." } },
		{ label = "Summon", key = "3", cmd = "SUMMON", click = CmdSummon,
		  title = "3  Summon", lines = { "After a wipe or inside an instance." } },
		{ label = "Drink", key = "4", cmd = "DRINK", click = CmdDrink,
		  title = "4  Drink", lines = { "Bots sit and drink. You drink too." } },
		{ label = "Flee", key = "5", cmd = "FLEE", click = CmdFlee,
		  title = "5  Run", lines = { "Party: ignore everything and run to you." } },
	}, PARTY_COLOR, -44, nil, "party")

	local tankRow = PlaceRow({
		{ label = "Hold", key = "S1", cmd = "TANKHOLD", click = CmdTankHold,
		  title = "Shift-1  Tank hold",
		  lines = { "Whisper tank: follow, then stay.", "DPS keep following you." } },
		{ label = "Pull", key = "S2", cmd = "TANKPULL", click = CmdTankPull,
		  title = "Shift-2  Open pack",
		  lines = { "Whisper tank: pull your target." } },
		{ label = "Go", key = "S3", cmd = "TANKGO", click = CmdTankGo,
		  title = "Shift-3  Tank go",
		  lines = { "Party: tank attack" } },
		{ label = "Mark", key = "", cmd = "MARK", click = CmdMarkToggle, mod = "mark", color = UTIL_COLOR,
		  title = "Pack mark (no combat)",
		  lines = {
			"Hover nameplates (V): casters/healers get skull.",
			"Icons only. Bots will not attack until Pull, Go, or Kill.",
			"Not a Shift key. Click only.",
		  } },
		{ label = "Clear", key = "", cmd = "CLEAR", click = CmdMarkClear, mod = "mark", color = UTIL_COLOR,
		  title = "Clear marks",
		  lines = { "Wipe raid markers on the pack." } },
	}, TANK_COLOR, partyRow[1], -4, "tank")

	local dpsRow = PlaceRow({
		{ label = "Kill", key = "C1", cmd = "ATTACK", click = CmdAttack,
		  title = "Ctrl-1  Kill target",
		  lines = { "Party: attack your target." } },
		{ label = "Burn", key = "C2", cmd = "BURN", click = CmdBurn,
		  title = "Ctrl-2  Burn",
		  lines = { "Party: max dps" } },
		{ label = "Skull", key = "C3", cmd = "SKULL", click = CmdSkull,
		  title = "Ctrl-3  Kill order",
		  lines = { "rti skull + attack. This is the go-ahead to fight the mark." } },
		{ label = "Water", key = "C4", cmd = "WATER", click = CmdWater,
		  title = "Ctrl-4  Mage water",
		  lines = { "Whispers every mage: cast conjure water." } },
		{ label = "Loop", key = "C5", cmd = "LOOP", click = CmdLoop, color = LOOP_COLOR,
		  title = "Ctrl-5  Dungeon loop",
		  lines = {
			"summon -> follow -> drink -> tank pull ->",
			"skull+attack -> stay -> drink -> follow.",
			"After a wipe it starts at summon.",
		  } },
	}, DPS_COLOR, tankRow[1], -4, "dps")

	local gearRow1 = PlaceRow({
		{ label = "Gear", key = "", cmd = "AUTOGEAR", click = CmdAutogear,
		  title = "Autogear",
		  lines = { "Party: autogear. Out of combat. Not a combat key." } },
		{ label = "Maint", key = "", cmd = "MAINT", click = CmdMaint,
		  title = "Maintenance",
		  lines = { "Party: maintenance (food, bags, upkeep)." } },
		{ label = "Repair", key = "", cmd = "REPAIR", click = CmdRepair,
		  title = "Repair",
		  lines = { "Party: repair. Target a repair vendor." } },
		{ label = "Talent", key = "", cmd = "TALENTS", click = CmdTalents,
		  title = "Talents",
		  lines = { "Party: talents. Bots apply their spec." } },
		{ label = "Train", key = "", cmd = "TRAIN", click = CmdTrain,
		  title = "Trainer learn",
		  lines = { "Target a class/profession trainer, then click." } },
	}, GEAR_COLOR, -44, nil, "gear")

	local gearRow2 = PlaceRow({
		{ label = "Sell", key = "", cmd = "SELL", click = CmdSell,
		  title = "Sell greys",
		  lines = { "Party: s *  Target a vendor first." } },
		{ label = "Food", key = "", cmd = "FOOD", click = CmdFood,
		  title = "Eat",
		  lines = { "Party: food." } },
		{ label = "Home", key = "", cmd = "HOME", click = CmdHome,
		  title = "Set hearth",
		  lines = { "Target an innkeeper, then click. Party: home." } },
		{ label = "Stats", key = "", cmd = "STATS", click = CmdStats,
		  title = "Stats",
		  lines = { "Party: stats (gold, bags, durability)." } },
		{ label = "Drink", key = "", cmd = "PREPDRINK", click = CmdDrink,
		  title = "Drink",
		  lines = { "Party: drink. You drink too." } },
	}, GEAR_COLOR, gearRow1[1], -4, "gear")

	local gearRow3 = PlaceRow({
		{ label = "Loot", key = "", cmd = "LOOT", click = CmdLoot,
		  title = "Loot normal",
		  lines = { "Party: ll normal (skip BoP)." } },
		{ label = "Reset", key = "", cmd = "RESETAI", click = CmdResetAI, color = WARN_COLOR,
		  title = "Reset bot AI",
		  lines = { "Party: reset botAI. Use if a bot is stuck." } },
		{ label = "Leave", key = "", cmd = "LEAVE", click = CmdLeave, color = WARN_COLOR,
		  title = "Leave party",
		  lines = { "Click twice to confirm. Never on a combat key." } },
	}, WARN_COLOR, gearRow2[1], -4, "gear")

	f.combatRows = { partyRow, tankRow, dpsRow }
	f.gearRows = { gearRow1, gearRow2, gearRow3 }

	f.rowGlows = {
		party = MakeRowGlow(partyRow[1], partyRow[#partyRow]),
		tank = MakeRowGlow(tankRow[1], tankRow[3]),
		dps = MakeRowGlow(dpsRow[1], dpsRow[#dpsRow]),
		gear1 = MakeRowGlow(gearRow1[1], gearRow1[#gearRow1]),
		gear2 = MakeRowGlow(gearRow2[1], gearRow2[#gearRow2]),
		gear3 = MakeRowGlow(gearRow3[1], gearRow3[#gearRow3]),
	}

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 8)
	status:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
	status:SetJustifyH("LEFT")
	status:SetText("|cff888888click a chip or bind 1-5|r")
	f.status = status

	function f:Flash(which)
		local b = self.chips and self.chips[which]
		if b then
			FlashBtn(b)
		end
	end

	local function ShowRows(rows, shown)
		for r = 1, #rows do
			local row = rows[r]
			for i = 1, #row do
				if shown then
					row[i]:Show()
				else
					row[i]:Hide()
				end
			end
		end
	end

	function f:SetPage(page)
		if page ~= "gear" then
			page = "combat"
		end
		self.page = page
		leaveArmedUntil = 0
		local onGear = page == "gear"
		ShowRows(self.combatRows, not onGear)
		ShowRows(self.gearRows, onGear)
		if self.pageBtn and self.pageBtn.labelFs then
			self.pageBtn.labelFs:SetText(onGear and "Fight" or "Gear")
			self.pageBtn.color = onGear and PARTY_COLOR or UTIL_COLOR
		end
		ApplyModifierLook()
	end

	function f:RefreshStatus()
		local extra = lastCmd ~= "" and ("  |cff888888" .. lastCmd .. "|r") or ""
		if self.page == "gear" then
			self.status:SetText("|cffc090ffGear page|r  autogear / repair / talents   (1-5 still combat)" .. extra)
			return
		end
		local mod = CurrentMod()
		local tag
		if mod == "shift" then
			tag = "|cff6eb5ffShift  tank|r"
		elseif mod == "ctrl" then
			tag = "|cffff7777Ctrl  DPS|r"
		elseif mod == "other" then
			tag = "|cff888888no bind for that combo|r"
		else
			tag = "|cffffd1001-5  party|r"
		end
		local marks = MarkStatusText()
		if marks then
			self.status:SetText(tag .. "  " .. marks .. extra)
		else
			self.status:SetText(tag .. "   " .. NextLoopLabel() .. extra)
		end
	end

	function f:Refresh()
		RebuildRoster()
		local list = rosterCache.all
		for i = 1, 4 do
			local b = self.rosterBtns[i]
			local rec = list[i]
			if rec then
				b.botName = rec.name
				local tag = rec.role == "tank" and "|cffffd100T|r " or (rec.role == "heal" and "|cff66ff66H|r " or "")
				b.fs:SetText(tag .. ClassColor(rec.class) .. ShortName(rec.name) .. "|r")
				b:Show()
			else
				b.botName = nil
				b.fs:SetText("")
				b:Hide()
			end
		end

		if self.binds and self.binds.labelFs then
			self.binds.labelFs:SetText(db.useBinds and "Bound" or "Binds")
			self.binds.color = db.useBinds and LOOP_COLOR or UTIL_COLOR
		end
		if self.setup and self.setup.labelFs then
			self.setup.labelFs:SetText(setupDone and "Set" or "Setup")
			self.setup.color = setupDone and LOOP_COLOR or UTIL_COLOR
		end
		if self.pageBtn and self.pageBtn.labelFs then
			local onGear = self.page == "gear"
			self.pageBtn.labelFs:SetText(onGear and "Fight" or "Gear")
			self.pageBtn.color = onGear and PARTY_COLOR or UTIL_COLOR
		end
		if self.chips and self.chips.MARK and self.chips.MARK.labelFs then
			local on = db.markEnabled
			self.chips.MARK.labelFs:SetText(on and "ON" or "Mark")
			self.chips.MARK.color = on and LOOP_COLOR or UTIL_COLOR
		end
		ApplyModifierLook()
	end

	ui = f
	f:SetPage("combat")
	if db.shown then
		f:Show()
	else
		f:Hide()
	end
	f:Refresh()
	return f
end

-----------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("PLAYER_DEAD")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterEvent("MODIFIER_STATE_CHANGED")
driver:RegisterEvent("UNIT_AURA")
driver:RegisterEvent("UNIT_INVENTORY_CHANGED")
driver:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
driver:RegisterEvent("PLAYER_FOCUS_CHANGED")
driver:RegisterEvent("UNIT_TARGET")
driver:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")

driver:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name ~= ADDON then return end
		BotCtrlDB = CopyDefaults(defaults, BotCtrlDB)
		db = BotCtrlDB
	elseif event == "PLAYER_LOGIN" then
		if not db then
			BotCtrlDB = CopyDefaults(defaults, BotCtrlDB)
			db = BotCtrlDB
		end
		BuildUI()
		ApplyBinds()
		Print("loaded. Binds 1-5, Gear tab, Mark on the tank row. Setup once after invite. /bot")
	elseif event == "PLAYER_ENTERING_WORLD" then
		local inInstance, itype = IsInInstance()
		if inInstance and (itype == "party" or itype == "raid") then
			WipeOrInstanceReset()
			Print("Instance: Summon -> Follow. Click Loop or key 3.")
			if ui and ui.Refresh then ui:Refresh() end
		end
		RebuildRoster()
		if ui and ui.Refresh then ui:Refresh() end
	elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
		setupDone = false
		RebuildRoster()
		if ui and ui.Refresh then ui:Refresh() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if bindsPending then
			ApplyBinds()
		end
		WipePack()
		if ui and ui.Refresh then ui:Refresh() end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- keep current pack marks into the pull
	elseif event == "PLAYER_DEAD" then
		WipeOrInstanceReset()
		if ui and ui.Refresh then ui:Refresh() end
	elseif event == "PLAYER_TARGET_CHANGED" then
		ApplyModifierLook()
		if db and db.markEnabled then ApplyVisible() end
	elseif event == "UPDATE_MOUSEOVER_UNIT"
		or event == "PLAYER_FOCUS_CHANGED"
		or event == "UNIT_TARGET" then
		if db and db.markEnabled then ApplyVisible() end
	elseif event == "MODIFIER_STATE_CHANGED" then
		ApplyModifierLook()
	elseif event == "UNIT_AURA" or event == "UNIT_INVENTORY_CHANGED" then
		local unit = ...
		if unit and (unit == "player" or unit:find("^party") or unit:find("^raid")) then
			rosterDirty = true
		end
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local _, subevent, sourceGUID, _, _, destGUID = ...
		NoteCast(subevent, sourceGUID, destGUID)
	end
end)

driver:SetScript("OnUpdate", function(self, dt)
	FlushQueue(dt)
	FlashTick(dt)
	local mod = CurrentMod()
	if mod ~= lastModKey then
		ApplyModifierLook()
	end
	if rosterDirty then
		rosterElapsed = rosterElapsed + dt
		if rosterElapsed >= 0.25 then
			rosterDirty = false
			rosterElapsed = 0
			if ui and ui.Refresh then
				ui:Refresh()
			else
				RebuildRoster()
			end
		end
	else
		rosterElapsed = 0
	end
	if db and db.markEnabled then
		markElapsed = markElapsed + dt
		if markElapsed >= 0.15 then
			markElapsed = 0
			ApplyVisible()
		end
	else
		markElapsed = 0
	end
end)

-----------------------------------------------------------------------
-- Slash
-----------------------------------------------------------------------

SLASH_BOTCTRL1 = "/bot"
SLASH_BOTCTRL2 = "/botctrl"
SlashCmdList["BOTCTRL"] = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S+)%s*(.*)$")
	cmd = cmd and cmd:lower() or ""
	rest = rest or ""

	if cmd == "" or cmd == "help" then
		Print("/bot follow stay summon drink flee hold pull go kill burn skull water setup loop")
		Print("/bot mark  /bot clear  /bot melee   (pack marks, folded in from PackMark)")
		Print("/bot gear | fight   (toggle prep page)")
		Print("/bot autogear maint repair talents train sell food home stats loot resetai leave")
		Print("/bot tank Name  |  /bot dps Name  |  /bot heal Name")
		Print("/bot binds  /bot unbind  /bot show  /bot hide  /bot lock  /bot reset")
		Print("Combat keys never send autogear or leave.")
	elseif COMMANDS[cmd:upper()] then
		COMMANDS[cmd:upper()]()
	elseif cmd == "hold" then
		CmdTankHold()
	elseif cmd == "pull" then
		CmdTankPull()
	elseif cmd == "go" then
		CmdTankGo()
	elseif cmd == "kill" then
		CmdAttack()
	elseif cmd == "run" then
		CmdFlee()
	elseif cmd == "tank" then
		if rest == "" then
			RebuildRoster()
			Print("Tank: " .. tostring(TankName() or "(none)"))
		else
			local name = ResolveName(rest)
			SetRole(name, "tank")
			Print(name .. " -> tank")
		end
	elseif cmd == "dps" then
		if rest ~= "" then
			local name = ResolveName(rest)
			SetRole(name, "dps")
			Print(name .. " -> DPS")
		end
	elseif cmd == "heal" then
		if rest ~= "" then
			local name = ResolveName(rest)
			SetRole(name, "heal")
			Print(name .. " -> heal")
		end
	elseif cmd == "binds" then
		if not db.useBinds then
			ToggleBinds()
		else
			Print("Already bound. /bot unbind to release.")
		end
	elseif cmd == "unbind" then
		if db.useBinds then
			ToggleBinds()
		else
			Print("Binds already off.")
		end
	elseif cmd == "show" then
		db.shown = true
		if ui then ui:Show() end
	elseif cmd == "hide" then
		db.shown = false
		if ui then ui:Hide() end
	elseif cmd == "toggle" then
		db.shown = not db.shown
		if ui then
			if db.shown then ui:Show() else ui:Hide() end
		end
	elseif cmd == "lock" then
		db.locked = not db.locked
		Print(db.locked and "Bar locked." or "Bar unlocked — drag to move.")
		if ui and ui.lock and ui.lock.tex then
			if db.locked then
				ui.lock.tex:SetTexture("Interface\\Buttons\\LockButton-Locked-Up")
			else
				ui.lock.tex:SetTexture("Interface\\Buttons\\LockButton-Unlocked-Up")
			end
		end
	elseif cmd == "reset" then
		db.point, db.relPoint, db.x, db.y = "CENTER", "CENTER", 0, -260
		if ui then
			ui:ClearAllPoints()
			ui:SetPoint("CENTER", UIParent, "CENTER", 0, -260)
		end
		Print("Bar position reset.")
	elseif cmd == "gear" or cmd == "prep" then
		if ui and ui.SetPage then ui:SetPage("gear") end
	elseif cmd == "fight" or cmd == "combat" then
		if ui and ui.SetPage then ui:SetPage("combat") end
	elseif cmd == "maint" then
		CmdMaint()
	elseif cmd == "train" then
		CmdTrain()
	elseif cmd == "sell" then
		CmdSell()
	elseif cmd == "resetai" then
		CmdResetAI()
	elseif cmd == "melee" then
		db.markMelee = not db.markMelee
		Print(db.markMelee and "Marking casters AND melee." or "Casters / mana users only.")
		if db.markEnabled then ApplyVisible() end
	else
		Print("unknown: " .. cmd .. "  —  /bot help")
	end
end
