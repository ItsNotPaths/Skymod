-- pex: off.fillmeter a9d34820
-- pex: on.fillmeter b16cd9f1
-- FillMeter played the next light stage and waited for "Done" before changing state. Now the
-- event changes it; `filling` is the state it is going to, "" at rest (the controller reads it).
local rt = require('skymod.rt')

return function(C)
	C.__vars.filling = rt.string("")
	local Off, On = rt.state(C, "Off"), rt.state(C, "On")

	local function fill(self, anim, to)
		if self.filling ~= "" then return end
		self.filling = to
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation(anim)
	end

	function Off:FillMeter() fill(self, "Trigger01", "On") end
	function On:FillMeter() fill(self, "Trigger02", "Overload") end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" or self.filling == "" then return end
		local to = self.filling
		self.filling = ""
		self:GotoState(to)
	end
end
