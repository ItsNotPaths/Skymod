-- pex: position01.onactivate 99b8163c
-- pex: position02.onactivate e05c8a2f
-- pex: position03.onactivate c54b1ae8
-- pex: rotatepillartostate e09a5fb6
-- RotatePillarToState turned the pillar and waited for Turned0N; the caller then set the new
-- position. The event now sets it: Turned01 ends at position 2, 02 at 3, 03 at 1.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")

	function C:RotatePillarToState(stateNumber, animEventNumber)
		self:GotoState("busy")
		local door = self.myLinkedRef
		if self.solveState == stateNumber then
			door.numPillarsSolved = door.numPillarsSolved + 1
			self.pillarSolved = true
		elseif self.pillarSolved then
			door.numPillarsSolved = door.numPillarsSolved - 1
			self.pillarSolved = false
		end
		self:RegisterForAnimationEvent(self, "Turned0" .. animEventNumber)
		self:PlayAnimation("Trigger0" .. animEventNumber)
	end

	for i, to in ipairs({ 2, 3, 1 }) do
		rt.state(C, "position0" .. (i + 1)).OnActivate = function(self, triggerRef)
			self:RotatePillarToState(to, i + 1)
		end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		for n = 1, 3 do
			if asEventName == "Turned0" .. n then return self:GotoState("position0" .. (n % 3 + 1)) end
		end
	end
end
