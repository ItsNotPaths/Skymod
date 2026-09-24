-- RegisterCatapultHit waited TIME_TO_HIT, the volley's flight. The catapult now keeps that timer
-- and calls this when it runs out (ccbgssse001_catapultctrlscript.patch.lua).
return function(C)
	function C:RegisterCatapultHit()
		if self:ModObjectiveGlobal(1.0, self.CatapultHitCount, self.catapultObjective, self.CatapultHitTotal:GetValue()) then
			self:SetStage(self.stageToSetOnDone)
		end
	end
end
