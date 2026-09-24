-- pex: quickstartsiege 48daf681
-- QuickStartSiege polled once a second for CWScript's Init, blocked in setOwner, polled for the
-- siege quest, and for a finale also polled CWSiege, CWFortSiege and CWFinale stages. Now `quick`
-- steps through those waits; the siege being set up is kept as facts (qs*).
local rt = require('skymod.rt')

return function(C)
	C.Quick = rt.sequence("Idle", "AwaitInit", "AwaitGarrisons", "AwaitSiege", "AwaitFinale", "AwaitFinaleStage")
	local Q = C.Quick
	local v = C.__vars
	v.quick = Q.Idle
	v.qsHold, v.qsAttacker, v.qsAllegiance, v.qsDebugOn = rt.int(0), rt.int(0), rt.int(0), rt.int(1)
	v.qsMinorHold, v.qsFinale = rt.bool(false), rt.bool(false)
	v.qsFieldCO = rt.form("ObjectReference")
	v.TickRate = rt.float(1.0)
	local QuickStarting = rt.state(C, "QuickStarting")

	function C:QuickStartSiege(Hold, Attacker, PlayerAllegiance, CWDebugOn, IsMinorHold, QuickStartFinale)
		if self.quick ~= Q.Idle then return end
		self.qsHold, self.qsAttacker, self.qsAllegiance, self.qsDebugOn = Hold, Attacker, PlayerAllegiance, CWDebugOn
		self.qsMinorHold, self.qsFinale = IsMinorHold, QuickStartFinale
		self.quick = Q.AwaitInit
		self:GotoState("QuickStarting")
		self:OnTick()
	end

	-- CW started on the player's side; a hold the attacker owns goes back to the defender (true).
	local function start_war(self)
		local cws, attacker = self.CWs, self.qsAttacker
		cws.debugOn:SetValue(self.qsDebugOn)
		cws.CW00A:Stop()
		cws.CW00B:Stop()
		cws.CW01A:Stop()
		cws.CW01B:Stop()
		cws.CWAlliesS:MakeHadvarAndRalofPotentialAllies()
		cws:SetStage(self.qsAllegiance)
		local hold = cws:getLocationForHold(self.qsHold)
		if hold:GetKeywordData(cws.CWOwner) ~= attacker then return false end
		local defender = cws:GetOppositeFactionInt(attacker)
		hold:SetKeywordData(cws.CWOwner, defender)
		cws:SetOwner(cws:GetCapitalLocationForHold(hold), defender)
		cws:SetOwner(cws:GetCampLocationForHold(hold, attacker), attacker)
		return true
	end

	local function start_siege(self)
		local cws = self.CWs
		local hold = cws:getLocationForHold(self.qsHold)
		if self.qsHold == 4 then
			cws.CW03:SetStage(100)
			cws.CW03:Stop()
		end
		if self.qsAttacker == self.qsAllegiance then
			self.qsFieldCO = cws:GetReferenceCampFieldCOForHold(hold, self.qsAllegiance)
		else
			self.qsFieldCO = cws:GetReferenceHQFieldCOForHold(hold, self.qsAllegiance)
		end
		self.quick = Q.AwaitSiege
		cws:CreateMissions(hold, self.qsFieldCO, true, self.qsFieldCO)
	end

	local function siege_running(self)
		if self.qsMinorHold then return self.CWFortSiege:IsRunning() end
		return self.CWSiege:IsRunning()
	end

	local function join_siege(self)
		local cws = self.CWs
		self.quick = self.qsFinale and Q.AwaitFinale or Q.Idle
		rt.static("Game", "GetPlayer"):MoveTo(self.qsFieldCO)
		if not cws:GetStageDone(50) then
			cws:SetStage(50)
			cws.CW03:SetStage(210)
			cws.CWSiegeS:SetStage(1)
		end
	end

	function QuickStarting:OnTick()
		if self.quick == Q.AwaitInit then
			if self.CWs.Init == 0 then return end
			self.quick = Q.AwaitGarrisons
			if not start_war(self) then start_siege(self) end
		end
		if self.quick == Q.AwaitGarrisons then
			if self.CWs.resettingGarrisons then return end
			start_siege(self)
		end
		if self.quick == Q.AwaitSiege then
			if not siege_running(self) then return end
			join_siege(self)
		end
		if self.quick == Q.AwaitFinale then
			if not (self.CWSiege:GetStageDone(1) and self.CWFortSiege:GetStageDone(10) and self.CWFinale:IsRunning()) then return end
			self.quick = Q.AwaitFinaleStage
			self.CWFinale:SetStage(10)
		end
		if self.quick == Q.AwaitFinaleStage then
			if not self.CWFinale:GetStageDone(10) then return end
			self.quick = Q.Idle
			rt.static("Game", "GetPlayer"):MoveTo(self.CWFinaleLeaderAlias:GetReference())
		end
		if self.quick == Q.Idle then self:GotoState("") end
	end
end
