-- pex: goaway 75b3e5e2
-- GoAway polled its own state until "playing" ended, then went "goingaway", played the leave
-- animation, and waited 1.5s before removing the crossfade. Both waits are now timers on the
-- class's existing OnTick.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick
	C.__vars.goAwayPending = rt.bool(false)
	C.__vars.crossfadeT = rt.timer(rt.None) -- None: no crossfade wait pending
	C.__vars.TickRate = rt.float(0.5)

	function C:GoAway()
		if self.goAwayPending or self.crossfadeT ~= rt.None then return end -- a second start is dropped
		self.goAwayPending = true
	end

	function C:OnTick()
		split_tick(self)
		if self.goAwayPending and self:GetState() ~= "playing" then
			self.goAwayPending = false
			self:GotoState("goingaway")
			self.learnwordfadeloop02:ApplyCrossfade(0.5)
			self:PlayAnimation("Away")
			self.crossfadeT = 1.5
			return
		end
		if self.crossfadeT == rt.None or self.crossfadeT > 0 then return end
		self.crossfadeT = rt.None
		rt.static("ImageSpaceModifier", "RemoveCrossFade", 0.5)
	end
end
