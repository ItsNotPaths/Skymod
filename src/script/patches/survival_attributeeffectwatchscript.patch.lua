-- pex: checkattributepenalty 5745e778
-- pex: handleattributediseaseapply 268b7b55
-- pex: waitforunlock ef07d261
-- WaitForUnlock polled 0.5s until `locked` cleared, so two calls into these functions could not
-- run their bodies at the same time. Handlers here already run one at a time to completion (no
-- real concurrency inside one tick), so the only way in is a second call while the first is still
-- on the stack; that is the ordinary "a run happens once" case (script-api.md section 3).
-- WaitForUnlock is kept as a no-op for any mod that still calls it directly.
local rt = require('skymod.rt')

return function(C)
	function C:CheckAttributePenalty()
		if self.locked then return end -- a run happens once
		self.locked = true
		local totalAV = self.Need:GetTotalAV(self.AttributeAVName, self.PenaltyAVName)
		if totalAV ~= self.lastTotalAV then
			self.Need:ApplyAttributePenalty(totalAV, self.Need.NeedValue:GetValue(), self.AttributeAVName, self.PenaltyAVName)
		end
		self.lastTotalAV = totalAV
		self.locked = false
	end

	function C:HandleAttributeDiseaseApply(akDisease, akEffectToDispel, akTarget)
		if self.locked then return end -- a run happens once
		self.locked = true
		self.Need:HandleAttributeDiseaseApply(akDisease, akEffectToDispel, akTarget)
		self.locked = false
	end

	function C:WaitForUnlock() end
end
