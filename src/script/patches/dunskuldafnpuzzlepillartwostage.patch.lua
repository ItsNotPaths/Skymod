-- pex: position01.onactivate 9f6fca49
-- pex: position02.onactivate 1fe6306e
-- pex: position03.onactivate 83b752be
-- pex: rotatepillartostate a2c09c15
-- The pillar turned and waited for Turned0N; the caller then set localState, the control's two
-- solution flags and the new position. The event now does all of it.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")
	-- after Turned0N: the position reached, and the control's (puzzleSolved, altSolution)
	local AFTER = { { 2, true, false }, { 3, false, false }, { 1, false, true } }

	function C:RotatePillarToState(stateNumber, animEventNumber)
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, "Turned0" .. animEventNumber)
		self:PlayAnimation("Trigger0" .. animEventNumber)
	end

	for i, a in ipairs(AFTER) do
		rt.state(C, "position0" .. (i + 1)).OnActivate = function(self, triggerRef)
			self:RotatePillarToState(a[0], i + 1)
		end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		for n = 1, 3 do
			if asEventName == "Turned0" .. n then
				local a = AFTER[n - 1]
				self.localState = a[0]
				self.myLinkedRef.puzzleSolved = a[1]
				self.myLinkedRef.altSolution = a[2]
				return self:GotoState("position0" .. a[0])
			end
		end
	end
end
