-- pex: fragment_0 294554a6
-- Stage 0 reset the garrison, then set the ownership keyword data and stopped once
-- StartCWGovernmentQuestIfCapital returned (a 1 s poll on the government's callback). Those last two
-- steps now wait in state "AwaitingGovernment", polling WaitingForCallBackFromCWGovernment every 1 s.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.pollT = rt.timer(0.0)
	local Awaiting = rt.state(C, "AwaitingGovernment")

	local function garrison(self) return rt.cast(self, "CWResetGarrisonScript") end

	local function finish(self)
		garrison(self):SetOwnershipKeywordData()
		self:Stop()
	end

	-- keyword data -2 on the garrison or fort keyword means: do not reset this place
	local function kept(loc, kw) return loc:HasKeyword(kw) and loc:GetKeywordData(kw) == -2 end

	function C:Fragment_0()
		if self:GetState() == "AwaitingGovernment" then return end
		local q, loc = garrison(self), self.Alias_Garrison:GetLocation()
		if kept(loc, q.CWs.CWGarrison) or kept(loc, q.CWs.CWFort) then return finish(self) end
		q:ToggleEnableMarkers(self.Alias_EnableMarkerImperial, self.Alias_EnableMarkerSons,
			self.Alias_EnableMarkerImperialExterior, self.Alias_EnableMarkerSonsExterior, self.Alias_EnableMarkerMonster)
		q:ProcessIfCamp(self.Alias_EnableMarkerImperial, self.Alias_EnableMarkerSons)
		q:ProcessSoldierAliases()
		self:GotoState("AwaitingGovernment")
		self.pollT = 0.0
		q:StartCWGovernmentQuestIfCapital()
		self:OnTick()
	end

	function Awaiting:OnTick()
		if self.pollT > 0 then return end
		if garrison(self).WaitingForCallBackFromCWGovernment then
			self.pollT = self.pollT + 1.0
			return
		end
		self:GotoState("")
		finish(self)
	end
end
