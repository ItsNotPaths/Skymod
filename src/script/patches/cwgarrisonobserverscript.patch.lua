-- pex: playerleftlocation ae487093
-- playerLeftLocation gave an emptied garrison to the player's side and stopped the quest once
-- setOwner's resets were done. The stop now waits for CWScript's resettingGarrisons.
local rt = require('skymod.rt')

return function(C)
	C.__vars.stopOwed = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Leaving = rt.state(C, "Leaving")

	local function lost_by_enemy(self, loc)
		local cws = self.CWs
		return self.countSoldiers <= 0
			and loc:GetKeywordData(cws.CWOwner) ~= cws.PlayerAllegiance
			and not loc:HasKeyword(cws.CWCapital)
			and not loc:HasKeyword(cws.CWGarrisonDefenderOnly)
			and not loc:HasKeyword(cws.CWFort)
	end

	local function stop(self)
		self:UnregisterForUpdate()
		self:Stop()
	end

	function C:playerLeftLocation()
		if self.stopOwed or self.maxCountSoldiers == 0 then return end
		local loc = self.Garrison:GetLocation()
		if rt.static("Game", "GetPlayer"):IsInLocation(loc) then return end
		if not lost_by_enemy(self, loc) then return stop(self) end
		local cws = self.CWs
		self.stopOwed = true
		self:GotoState("Leaving")
		cws:SetOwner(loc, cws.PlayerAllegiance, rt.None, rt.None, rt.None, rt.None, rt.None, rt.None, rt.None, true)
		self:OnTick()
	end

	function Leaving:OnTick()
		if self.CWs.resettingGarrisons then return end
		self.stopOwed = false
		self:GotoState("")
		stop(self)
	end
end
