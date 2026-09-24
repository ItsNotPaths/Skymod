-- pex: close d4b525c6
-- pex: open 3d38e559
-- open() and close() played the gate animation and waited for "opening" or "closing" in the busy
-- state. Now that event ends the move; the two names say which way it went.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")

	local function move(self, anim, done)
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function C:open() move(self, "open", "opening") end
	function C:close() move(self, "close", "closing") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "opening" then
			self:GotoState("upPosition")
		elseif asEventName == "closing" then
			self:GotoState("downPosition")
		end
	end
end
