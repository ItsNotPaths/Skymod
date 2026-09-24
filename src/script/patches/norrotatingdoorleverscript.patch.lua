-- pex: leftpos.onactivate ef0e10e8
-- pex: offpos.onactivate 02ec65b5
-- pex: rightpos.onactivate 26deed1b
-- The lever went to busyState, moved and waited for its end event. The event now sets the new
-- position: pushed -> LEFTpos, pulled -> RIGHTpos, unPushed/unPulled -> OFFpos.
local rt = require('skymod.rt')

return function(C)
	local Off, Left, Right, Busy = rt.state(C, "OFFpos"), rt.state(C, "LEFTpos"), rt.state(C, "RIGHTpos"), rt.state(C, "busyState")
	local to = { pushed = "LEFTpos", pulled = "RIGHTpos", unPushed = "OFFpos", unPulled = "OFFpos" }

	local function move(self, anim, done)
		self:GotoState("busyState")
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Off:OnActivate(triggerRef)
		if self.leftNEXT then move(self, "pushDown", "pushed") else move(self, "pullDown", "pulled") end
	end
	function Left:OnActivate(triggerRef) move(self, "pushUp", "unPushed") end
	function Right:OnActivate(triggerRef) move(self, "pullUp", "unPulled") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		for name, state in pairs(to) do
			if asEventName == name then
				self:GotoState(state)
				if name == "pushed" then self.leftNEXT = false elseif name == "pulled" then self.leftNEXT = true end
				return
			end
		end
	end
end
