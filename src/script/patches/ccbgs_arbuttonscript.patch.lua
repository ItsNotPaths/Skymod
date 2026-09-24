-- pex: waiting.onactivate 9ce71bc6
-- The press played and waited for TransitionComplete in the busy state; the event now ends it.
local rt = require('skymod.rt')

return function(C)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	function Waiting:OnActivate(akActionRef)
		self:GotoState("Busy")
		if self.bPlayerOnly and akActionRef ~= rt.static("Game", "GetPlayer") then
			self:GotoState("Waiting")
			return
		end
		self.ActivateSound:Play(self)
		self:RegisterForAnimationEvent(self, "TransitionComplete")
		self:PlayAnimation("Stage2ReturnStage1")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "TransitionComplete" then self:GotoState("Waiting") end
	end
end
