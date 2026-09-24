-- pex: position01.onactivate 549f3fbe
-- pex: position02.onactivate ebe29367
-- pex: position03.onactivate 357e70d4
-- pex: rotateringtostate 20a63448
-- RotateRingToState turned the ring and waited for Turned0N; the caller then set the new
-- position. The event now sets it: Turned01 ends at position 2, 02 at 3, 03 at 1.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")

	function C:RotateRingToState(stateNumber, animEventNumber)
		local keyhole = self.myLinkedRef
		if self.solveState == stateNumber then
			keyhole.numRingsSolved = keyhole.numRingsSolved + 1
			self.ringSolved = true
		elseif self.ringSolved then
			if keyhole.puzzleSolved then keyhole.puzzleSolved = false end
			if keyhole.numRingsSolved > 0 then keyhole.numRingsSolved = keyhole.numRingsSolved - 1 end
			self.ringSolved = false
		end
		self:RegisterForAnimationEvent(self, "Turned0" .. animEventNumber)
		self:PlayAnimation("Trigger0" .. animEventNumber)
	end

	for i, to in ipairs({ 2, 3, 1 }) do
		rt.state(C, "position0" .. (i + 1)).OnActivate = function(self, triggerRef)
			if triggerRef ~= rt.static("Game", "GetPlayer") or self.myLinkedRef:GetState() == "busy" then return end
			self:GotoState("busy")
			self:RotateRingToState(to, i + 1)
		end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		for n = 1, 3 do
			if asEventName == "Turned0" .. n then return self:GotoState("position0" .. (n % 3 + 1)) end
		end
	end
end
