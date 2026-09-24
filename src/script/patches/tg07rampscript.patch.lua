-- pex: waiting.onactivate efbf44c4
-- The ramp played Trigger01 and waited for "Done" in animating, then went to done and moved Vald
-- to his faction. The event now does that.
local rt = require('skymod.rt')

return function(C)
	local Waiting, Animating = rt.state(C, "Waiting"), rt.state(C, "animating")

	function Waiting:OnActivate(akActivator)
		self:GotoState("animating")
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Trigger01")
	end

	function Animating:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" then return end
		self:GotoState("done")
		if self.pTG07Done == 0 and self.pTG07Quest:GetStageDone(48) == false then
			self.pTG07Vald:GetActorRef():AddToFaction(self.pTG07ValdFaction)
			self.pTG07Done = 1
		end
	end
end
