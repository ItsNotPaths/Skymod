-- pex: lowered.onactivate 625258f8
-- pex: raised.onactivate b1cee61c
-- The stair played Lower or Raise and waited for "Done" before changing state. Now the event
-- changes it; `moving_to` is the state it is going to, "" at rest.
local rt = require('skymod.rt')

return function(C)
	C.__vars.moving_to = rt.string("")
	local Raised, Lowered = rt.state(C, "Raised"), rt.state(C, "Lowered")

	local function move(self, anim, to)
		if self.moving_to ~= "" then return end -- a run happens once
		self.moving_to = to
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation(anim)
	end

	function Raised:OnActivate(obj) move(self, "Lower", "Lowered") end
	function Lowered:OnActivate(obj) move(self, "Raise", "Raised") end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" or self.moving_to == "" then return end
		local to = self.moving_to
		self.moving_to = ""
		self:GotoState(to)
	end
end
