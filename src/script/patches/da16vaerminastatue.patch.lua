-- pex: done.onactivate 6329c129
-- pex: waiting.onactivate 5be63db6
-- Each activation played an animation and waited for "End" before changing state. Now the event
-- changes it; `turning_to` is the state the statue is going to, "" when at rest.
local rt = require('skymod.rt')

return function(C)
	C.__vars.turning_to = rt.string("")
	local Waiting, Done = rt.state(C, "waiting"), rt.state(C, "Done")

	local function play(self, anim, to)
		if self.turning_to ~= "" then return end -- a run happens once
		self.turning_to = to
		self:RegisterForAnimationEvent(self, "End")
		self:PlayAnimation(anim)
	end

	function Waiting:OnActivate(akActivator) play(self, "playAnim02", "Done") end
	function Done:OnActivate(akActivator) play(self, "playAnim01", "Waiting") end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "End" or self.turning_to == "" then return end
		local to = self.turning_to
		self.turning_to = ""
		self:GotoState(to)
	end
end
