-- pex: advancedragonattackscene 9d530718
-- pex: callodahviingtodragonsreach 26c53208
-- pex: onupdate 46fbdf43
-- AdvanceDragonAttackScene(2) waited 10 s before Odahviing appeared. It now returns at once and
-- waits in state "OdahviingArriving"; the other stages never waited and run as converted.
-- CallOdahviingToDragonsreach and OnUpdate waited only through that call and need no change.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.arrivalT = rt.timer(0.0)
	local Arriving = rt.state(C, "OdahviingArriving")
	local advance = C.__fn.advancedragonattackscene

	function C:AdvanceDragonAttackScene(newStage)
		if newStage ~= 2 then return advance(self, newStage) end
		if self:GetState() == "OdahviingArriving" then return true end -- already on his way
		if self.DragonAttackStage ~= 1 then return false end
		self:GotoState("OdahviingArriving")
		self.arrivalT = 10.0
		return true
	end

	function Arriving:OnTick()
		if self.arrivalT > 0 then return end
		self:GotoState("")
		self.Alias_Odahviing:GetRef():Enable()
		rt.static("Game", "GetPlayer"):SetVoiceRecoveryTime(0)
		self:SetStage(150)
		self.DragonAttackStage = 2
	end
end
