-- pex: position01.onactivate f64e0d52
-- pex: position02.onactivate 6f673e81
-- pex: position03.onactivate d8721002
-- pex: rotatepillar a69567c5
-- rotatePillar turned the pillar, waited for Turned0N, then opened the drawbridge if all three
-- pillars were set; the caller then set the new position. The event now does both. Once the
-- quest is done the pillar no longer turns and only changes state, as before.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")

	function C:rotatePillar(stateNumber, animEventNumber)
		if self.mainScript.questDone then return end
		self:GotoState("busy")
		self:pillarSet(stateNumber)
		self:RegisterForAnimationEvent(self, "Turned0" .. animEventNumber)
		self:PlayAnimation("Trigger0" .. animEventNumber)
	end

	for i, to in ipairs({ 2, 3, 1 }) do
		rt.state(C, "position0" .. (i + 1)).OnActivate = function(self, triggerRef)
			if self.mainScript.pillarSolved then return end
			self:rotatePillar(to, i + 1)
			if self:GetState() ~= "busy" then self:GotoState("position0" .. to) end
		end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		for n = 1, 3 do
			if asEventName == "Turned0" .. n then
				local m = self.mainScript
				if m.pillarAState == 2 and m.pillarBState == 2 and m.pillarCState == 2 then
					m.pillarSolved = true
					self.drawBridge:Activate(self.controllerScript)
					for _, f in ipairs({ m.flameA, m.flameB, m.flameC, m.flameD }) do f:SetAnimationVariableFloat("fToggleBlend", 1) end
				end
				return self:GotoState("position0" .. (n % 3 + 1))
			end
		end
	end
end
