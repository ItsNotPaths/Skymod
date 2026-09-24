-- pex: addenemyfortstobacktowar b1474bef
-- pex: createmissions cce31de0
-- pex: finishcampaign eefdeba6
-- pex: resetholds 943ab3fa
-- pex: resolveoffscreen 46fff69f
-- pex: setholdownerbyint d5a07cb5
-- pex: setinitialowners 28e243de
-- pex: setowner dbfbd50b
-- pex: setownereastmarch fa4dc064
-- pex: setownerfalkreath 966eff2f
-- pex: setownerhaafingar 703118a8
-- pex: setownerhjaalmarch 6f4e9e0c
-- pex: setownerpale cff01762
-- pex: setownerreach 094dbdb4
-- pex: setownerrift bcfa0c04
-- pex: setownerstartresetquest 41da49ec
-- pex: setownerwhiterun 389e69a3
-- pex: setownerwinterhold 97fe316e
-- pex: startcwcitizensflee 2b2e7970
-- pex: winholdandsetowner 04f3395b
-- setOwner blocked its caller until its CWResetGarrison quests had started (each once its location
-- unloaded) and called back. Now each garrison owed a reset is a fact that OnTick settles into free
-- slots, and callers wait on `resettingGarrisons`. The other waits are runs with a bool each.
-- Unlike Papyrus, a reset that does not start, or does not call back within GIVE_UP, is dropped
-- for its slot alone: the owner is already set, only that garrison keeps its old soldiers.
-- ResetHolds, setInitialOwners, SetHoldOwnerByInt and the nine setOwner<Hold>: no change, setOwner
-- returns at once and only more requests or a log line follow it.
local rt = require('skymod.rt')

local SLOTS = 8        -- CWResetGarrison1..8
local GIVE_UP = 600.0  -- seconds a reset quest has to call back
local FLEE_BAIL = 31.0 -- StartCWCitizensFlee's 30 one-second waits, then it goes ahead

return function(C)
	local v = C.__vars
	v.resetLocs, v.resetFactions = rt.array_of("Location"), rt.array_of("Int") -- garrisons owed a reset, for whom
	v.resetSlotLocs = rt.array_of("Location") -- what each reset quest resets
	v.resettingGarrisons = rt.bool(false)
	v.resetClock = rt.stopwatch(0.0) -- never reset; slots store their start on it
	v.resetStarted = rt.array_of("Float")
	v.finishingCampaign = rt.bool(false) -- waiting for CWMission00 to stop
	v.missionPending = rt.bool(false)    -- a minor-capital siege waits for CWFortSiegeCapital to stop
	v.missionCapital = rt.form("Location")
	v.missionFieldCO, v.missionMarker = rt.form("ObjectReference"), rt.form("ObjectReference")
	v.missionT = rt.timer(0.0)
	v.fleeStopping = rt.bool(false)
	v.fleeLocation = rt.form("Location")
	v.fleeSw = rt.stopwatch(0.0)
	v.fortsReadyMsgOwed = rt.bool(false)
	v.TickRate = rt.float(1.0)

	local function waiting(self, n) return self["WaitingForCWResetGarrisonQuest" .. n] end
	local function set_waiting(self, n, on) self["WaitingForCWResetGarrisonQuest" .. n] = on end
	local function slot_busy(self, n) return waiting(self, n) or not self["CWResetGarrison" .. n]:IsStopped() end

	local function free_slot(self)
		for n = 1, SLOTS do
			if not slot_busy(self, n) then return n end
		end
	end

	local function in_reset(self, loc)
		for n = 1, SLOTS do
			if rt.aget(self.resetSlotLocs, n - 1) == loc and slot_busy(self, n) then return true end
		end
		return false
	end

	local function any_waiting(self)
		for n = 1, SLOTS do
			if waiting(self, n) then return true end
		end
		return false
	end

	local function drop_reset(self, n, why)
		set_waiting(self, n, false)
		rt.static("Debug", "Trace", "CWScript: ERROR reset of " .. tostring(rt.aget(self.resetSlotLocs, n - 1)) .. " " .. why .. "; dropped, its garrison keeps its soldiers")
	end

	-- A later request for an owed location wins, except "keep the owner" (iCurrentOwner).
	local function owe(self, loc, faction)
		if faction ~= self.iCurrentOwner then loc:SetKeywordData(self.CWOwner, faction) end
		local i = rt.afind(self.resetLocs, loc)
		if i >= 0 then
			if faction ~= self.iCurrentOwner then self.resetFactions[i] = faction end
			return
		end
		if rt.alen(self.resetLocs) == 0 then
			self.resetLocs, self.resetFactions = rt.array(0, "Location"), rt.array(0, "Int")
		end
		self.resetLocs[#self.resetLocs] = loc
		self.resetFactions[#self.resetFactions] = faction
	end

	local function take_first(self)
		local locs, factions = self.resetLocs, self.resetFactions
		local loc, faction = locs[0], factions[0]
		for j = 0, #locs - 2 do
			locs[j], factions[j] = locs[j + 1], factions[j + 1]
		end
		locs[#locs - 1], factions[#factions - 1] = nil, nil
		return loc, faction
	end

	-- a flag set by anything, even an old save, is timed from resetStarted (0 when never started here)
	local function reset_tick(self)
		if rt.alen(self.resetSlotLocs) == 0 then self.resetSlotLocs = rt.array(SLOTS, "Location") end
		if rt.alen(self.resetStarted) == 0 then self.resetStarted = rt.array(SLOTS, "Float") end
		for n = 1, SLOTS do
			if waiting(self, n) and self.resetClock - self.resetStarted[n - 1] >= GIVE_UP then
				self["CWResetGarrison" .. n]:Stop()
				drop_reset(self, n, "never called back")
			end
		end
		if not self.resettingGarrisons then return end
		for _ = 1, rt.alen(self.resetLocs) do
			local n = free_slot(self)
			if not n then break end
			local loc, faction = take_first(self)
			if in_reset(self, loc) or loc:IsLoaded() then
				owe(self, loc, faction) -- again once its reset is over or it unloads
			else
				set_waiting(self, n, true)
				self.resetSlotLocs[n - 1] = loc
				self.resetStarted[n - 1] = self.resetClock
				if not self:setOwnerStartResetQuest(loc, faction, self["CWResetGarrisonStart" .. n]) then
					drop_reset(self, n, "did not start")
				end
			end
		end
		if rt.alen(self.resetLocs) == 0 and not any_waiting(self) then self.resettingGarrisons = false end
	end

	function C:setOwner(l1, FactionToOwn, l2, l3, l4, l5, l6, l7, l8, SetKeywordDataImmediately)
		if rt.cast(self.debugSkipSetOwnerCalls, "bool") then return end
		local locs, owed = { l1, l2, l3, l4, l5, l6, l7, l8 }, false
		for i = 0, 7 do
			local loc = locs[i]
			if rt.cast(loc, "bool") then
				if SetKeywordDataImmediately then self:SetOwnerKeywordDataOnly(loc, FactionToOwn) end
				owe(self, loc, FactionToOwn)
				owed = true
			end
		end
		if not owed then return end
		self.resettingGarrisons = true
		reset_tick(self)
	end

	-- Sets the owner as before; true when the reset quest started. The caller waits out IsLoaded.
	function C:setOwnerStartResetQuest(LocationToSet, FactionToOwn, KeywordForResetGarrisonQuest)
		if not rt.cast(LocationToSet, "bool") then return false end
		if FactionToOwn ~= self.iCurrentOwner then LocationToSet:SetKeywordData(self.CWOwner, FactionToOwn) end
		return KeywordForResetGarrisonQuest:SendStoryEventAndWait(LocationToSet)
	end

	local add_forts = C.__fn.addenemyfortstobacktowar
	function C:AddEnemyFortsToBackToWar(ShowDebugMessage)
		if not ShowDebugMessage or self.EnemyFortsAddedBackToWar then return add_forts(self, ShowDebugMessage) end
		rt.static("Debug", "MessageBox", "Setting Enemy Forts to be cleared of bandits and ready for missions. WAIT before testing civil war missions.")
		self.fortsReadyMsgOwed = true
		add_forts(self, false)
	end

	local function forts_tick(self)
		if not self.fortsReadyMsgOwed or self.resettingGarrisons then return end
		self.fortsReadyMsgOwed = false
		rt.static("Debug", "MessageBox", "Done Setting Enemy Forts to be cleared of bandits and ready for missions. You may now test civil war missions.")
	end

	-- WinHoldAndSetOwnerKeywordDataOnly sets and clears WinningHoldAndSettingOwnerPleaseWait in one
	-- call that never waits, so the wait on it is gone: no caller can see it set.
	function C:WinHoldAndSetOwner(HoldLocationToSet, AttackersWon, DefendersWon)
		local newOwner
		if not self.WinHoldAndSetOwnerAlreadySetKeyword then
			newOwner = self:GetWinner(HoldLocationToSet, AttackersWon, DefendersWon)
		else
			newOwner = rt.cast(HoldLocationToSet:GetKeywordData(self.CWOwner), "int")
			self.WinHoldAndSetOwnerAlreadySetKeyword = false
		end
		self:ClearHoldCrimeGold(HoldLocationToSet)
		self:SetHoldOwner(HoldLocationToSet, newOwner)
	end

	local function send_minor_capital_siege(self, capital, fieldCO, marker)
		self.CWFortSiegeMinorCapitalStart:SendStoryEvent(capital, fieldCO, marker)
	end

	function C:CreateMissions(HoldLocation, CurrentFieldCO, ForceFinalSiege, CampaignStartMarker)
		if self.WarIsActive == -1 then return end
		local objGlobal = self:GetCWObjGlobal(self:GetHoldID(HoldLocation))
		if (HoldLocation == self.HaafingarHoldLocation and self.HaafingarFortBattleComplete)
			or (HoldLocation == self.EastmarchHoldLocation and self.EastmarchFortBattleComplete) then
			objGlobal:SetValue(99)
		else
			objGlobal:SetValue(0)
		end
		if objGlobal:GetValue() < 99 and not ForceFinalSiege then
			self.CWMissionStart:SendStoryEvent(HoldLocation, CurrentFieldCO, CampaignStartMarker, 1)
			return
		end
		local capital = self:GetCapitalLocationForHold(HoldLocation)
		if capital:HasKeyword(self.LocTypeCity) then
			local ownFinal = (capital == self.SolitudeLocation and self.PlayerAllegiance == self.iImperials)
				or (capital == self.WindhelmLocation and self.PlayerAllegiance == self.iSons)
			if not ownFinal then self.CWSiegeStart:SendStoryEvent(capital, CurrentFieldCO) end
			return
		end
		if HoldLocation:GetKeywordData(self.CWOwner) == self.PlayerAllegiance then return end
		if self.missionPending then return end -- a run happens once
		if self.CWFortSiegeCapital:IsStopped() then
			return send_minor_capital_siege(self, capital, CurrentFieldCO, CampaignStartMarker)
		end
		self.missionPending = true
		self.missionCapital, self.missionFieldCO, self.missionMarker = capital, CurrentFieldCO, CampaignStartMarker
		self.missionT = 1.0
	end

	local function missions_tick(self)
		if not self.missionPending or self.missionT > 0 then return end
		if self.CWFortSiegeCapitalFort:GetLocation() ~= self.missionCapital then
			self.missionPending = false -- that capital's siege is already set up
			return
		end
		if not self.CWFortSiegeCapital:IsStopped() then
			self.missionT = self.missionT + 1.0
			return
		end
		self.missionPending = false
		send_minor_capital_siege(self, self.missionCapital, self.missionFieldCO, self.missionMarker)
	end

	local function campaign(self) return rt.cast(self.CWCampaign, "CWCampaignScript") end

	local function finish_tick(self)
		if not self.finishingCampaign or not campaign(self).CWMission00:IsStopped() then return end
		self.finishingCampaign = false
		self:setContestedHoldWinType()
		self:SetCountWins()
		self.previousContestedHold = self.contestedHold
		local report = self.debugForceOffscreenResult == 0
		if report then
			self.playerReport = 1
			self:getCampaignWonMessage():Show()
			self.CWCampaignObj:SetStage(self.contestedHoldWinner == self.PlayerAllegiance and 20 or 30)
		end
		self:ContributeToSalaryPool()
		if report then self.CWCampaign:Stop() end
	end

	function C:finishCampaign()
		if self.finishingCampaign then return end
		self.CampaignRunning = 0
		self.CWCampaignS.completedMission = 0
		self.CWCampaignS.failedMission = 0
		self.finishingCampaign = true
		campaign(self):stopTutorialMission()
		finish_tick(self)
	end

	local function resolved_tick(self)
		if self.finishingCampaign or self:GetState() ~= "ResolvingCampaignOffscreen" then return end
		self:GotoState("WaitingToStartNewCampaign")
	end

	function C:resolveOffscreen(CurrentAttackDelta)
		if self.finishingCampaign then return end
		self:GotoState("ResolvingCampaignOffscreen")
		self:stopSiegeQuests()
		if (CurrentAttackDelta or 0) == 0 then CurrentAttackDelta = self.AttackDelta end
		self.resolutionForced = false
		self.resolutionDieRoll = rt.cast(rt.static("Utility", "RandomInt", 0, 100), "float")
		self.resolutionResult = self.resolutionDieRoll + CurrentAttackDelta * self.ResolutionAttackDeltaMultiplier
		self.contestedHoldWinner = self.resolutionResult > 50 and self.attacker or self.defender
		local hold = self.ContestedHold
		if (hold == self.iReach and self.playerJoinedCampaginReach == 0)
			or (hold == self.iWhiterun and self.playerJoinedCampaginWhiterun == 0)
			or (hold == self.iRift and self.playerJoinedCampaginRift == 0) then
			self.contestedHoldWinner = self.defender
			self.resolutionForced = true
		end
		self:finishCampaign()
		resolved_tick(self)
	end

	local function flee_tick(self)
		if self.fleeStopping then
			if not self.CWCitizensFlee:IsStopped() and self.fleeSw < FLEE_BAIL then return end
			self.fleeStopping = false
		elseif not rt.cast(self.fleeLocation, "bool") then
			return
		end
		local loc = self.fleeLocation
		self.fleeLocation = rt.None
		self.CWCitizensFleeStart:SendStoryEvent(loc)
	end

	function C:StartCWCitizensFlee(LocationOfBattle)
		self.fleeLocation = LocationOfBattle -- a second call while stopping moves the flight
		if self.fleeStopping then return end
		if not self.CWCitizensFlee:IsStopped() then
			self.fleeStopping = true
			self.fleeSw = 0.0
			self.CWCitizensFlee:Stop()
		end
		flee_tick(self)
	end

	-- callees first, so a caller sees a callee that finished this tick
	function C:OnTick()
		reset_tick(self)
		flee_tick(self)
		missions_tick(self)
		finish_tick(self)
		resolved_tick(self)
		forts_tick(self)
	end
end
