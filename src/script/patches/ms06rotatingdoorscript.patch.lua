-- pex: leftpos.onactivate 3f94df13
-- pex: offpos.onactivate 64337f14
-- pex: rightpos.onactivate bb003d38
-- As NorRotatingDoorLever, and returning to OFFpos waited 4 s (from LEFTpos) or 0.4 s (from
-- RIGHTpos) after the lever's end event. Now `off_t` is that wait; the class OnTick runs the
-- split ticks, then ends it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.off_t = rt.timer(rt.None)
	local Off, Left, Right, Busy = rt.state(C, "OFFpos"), rt.state(C, "LEFTpos"), rt.state(C, "RIGHTpos"), rt.state(C, "busyState")
	local split_tick = C.__fn.ontick

	local function move(self, anim, done)
		self:GotoState("busyState")
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Off:OnActivate(triggerRef)
		self.myDoor = self:GetLinkedRef() -- the original's load-order hack
		if self.leftNEXT then move(self, "pushDown", "pushed") else move(self, "pullDown", "pulled") end
	end
	function Left:OnActivate(triggerRef) move(self, "pushUp", "unPushed") end
	function Right:OnActivate(triggerRef) move(self, "pullUp", "unPulled") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "pushed" then
			self:GotoState("LEFTpos")
			self.leftNEXT = false
		elseif asEventName == "pulled" then
			self:GotoState("RIGHTpos")
			self.leftNEXT = true
		elseif asEventName == "unPushed" then
			self.off_t = 4.0
		elseif asEventName == "unPulled" then
			self.off_t = 0.4
		end
	end

	function C:OnTick()
		split_tick(self)
		if self.off_t == rt.None or self.off_t > 0 then return end
		self.off_t = rt.None
		self:GotoState("OFFpos")
	end
end
