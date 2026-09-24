-- pex: ontriggerenter e56fae81
-- OnTriggerEnter ran one of two blocks the first time the player entered the coffin: DB04 seals
-- the eavesdropper in, DB10 sends it into the lake. Each was a chain of one-shot steps; now a
-- sequence stage plus one stopwatch, in OnTick, continues from either block into the other.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "coffin: " .. msg) end

return function(C)
	-- DB04: close the lid on the eavesdropper; DB10: the coffin falls into the lake
	C.Lid = rt.sequence("Idle", "Db04Close", "Db04Sealed", "Db10Close", "Db10Crash", "Db10Sleep", "Db10Wake",
		"Db10Flood", "Db10Lake", "Done")
	C.__vars.lid = C.Lid.Idle
	C.__vars.lidT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local L = C.Lid

	local function player() return rt.static("Game", "GetPlayer") end

	local function enterBox(self)
		rt.static("Game", "DisablePlayerControls", { abLooking = true, abCamSwitch = true })
		rt.static("Game", "ForceFirstPerson")
		player():MoveTo(self.PlayerCoffinMarker)
	end

	-- the DB10 block runs right after the DB04 block ends, as in the one Papyrus handler
	local function db10Start(self)
		if self.pNazirAlias:GetActorRef():IsInCombat() then return false end
		if self.DB10:GetStage() ~= 50 or self.pCoffinEscape ~= 0 then return false end
		enterBox(self)
		return true
	end

	-- stage -> { wait before it, action, next stage }
	local steps = {
		[L.Db04Close] = { 1.0, function(self)
			self.CoffinCloseSound:Play(self.Coffin)
			self.DBSanc_NMCoffinLightToggle:Disable(false)
			self.NMCoffinBlackIS:ApplyCrossfade(1.25)
		end, L.Db04Sealed },
		[L.Db04Sealed] = { 1.25, function(self)
			self.db04:SetStage(20)
			self.pNazirAlias:GetActorRef():StopCombat()
			player():StopCombatAlarm()
			self.pCiceroAlias:GetRef():MoveTo(self.pCiceroOutChamberMarker, 0.0, 0.0, 0.0, true)
			self.pCiceroNightMotherScene:Start()
			self.pInCoffin = 1
		end, L.Done },
		[L.Db10Close] = { 1.0, function(self)
			self.CoffinCloseSound:Play(self.Coffin)
			self.NMCoffinBlackIS:ApplyCrossfade(1.25)
		end, L.Db10Crash },
		[L.Db10Crash] = { 2.0, function(self)
			self.CoffinCrashSound:Play(self.Coffin)
			self.DB10.NazirStand = 1 -- pDB10Script's property, through the bare quest ref
			self.Body:PlayAnimation("playanim02")
		end, L.Db10Sleep },
		[L.Db10Sleep] = { 9.0, function(self) self.NightMotherSleepScene:Start() end, L.Db10Wake },
		[L.Db10Wake] = { 2.0, function(self) self.Body:PlayAnimation("playanim01") end, L.Db10Flood },
		[L.Db10Flood] = { 5.0, function(self)
			self.NMCoffinFullBlackIS:ApplyCrossfade(0.25)
			self.pBabetteAlias:GetReference():Enable(false)
			self.NightMotherCoffinWater:Enable(false)
			self.NightMotherCorpseWater:Enable(false)
			self.pNazirAlias:GetReference():MoveTo(self.NazirLakeMarker, 0.0, 0.0, 0.0, true)
			self.pBabetteAlias:GetReference():MoveTo(self.BabetteLakeMarker, 0.0, 0.0, 0.0, true)
			self.DB10:SetStage(55)
			self.DBSanc_NMCoffinLightToggle:Disable(false)
		end, L.Db10Lake },
		[L.Db10Lake] = { 10.0, function(self)
			player():MoveTo(self.PlayerLakeMarker, 0.0, 0.0, 0.0, true)
			self.NazirBabetteScene:Start()
			self.pCoffinEscape = 1
		end, L.Done },
	}

	local function enter(self, stage)
		self.lid = stage
		local s = steps[stage]
		if s then self.lidT = s[0] end
	end

	function C:OnTriggerEnter(akActionRef)
		if self.lid ~= L.Idle and self.lid ~= L.Done then
			trace("OnTriggerEnter dropped, lid " .. self.lid.name)
			return
		end
		local race = player():GetRace()
		if race == self.WerewolfBeastRace or race == self.DLC1VampireBeastRace then return end
		if akActionRef ~= player() then return end
		if self.pInCoffin == 0 and self.db04:GetStage() == 10 then
			trace("DB04: into the coffin")
			enter(self, L.Db04Close)
			enterBox(self)
		elseif db10Start(self) then
			trace("DB10: into the coffin")
			enter(self, L.Db10Close)
		end
	end

	function C:OnTick()
		if self.lid == L.Idle or self.lid == L.Done or self.lidT > 0 then return end
		local stage = self.lid
		local s = steps[stage]
		enter(self, s[2])
		trace(stage.name)
		s[1](self)
		if stage == L.Db04Sealed and db10Start(self) then
			trace("DB10 after DB04: into the coffin")
			enter(self, L.Db10Close)
		end
	end
end
