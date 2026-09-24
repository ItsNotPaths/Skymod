-- pex: closeanddisable e0da4836
-- pex: preactivation.onactivate 18195fa4
-- CloseAndDisable closed DoorX, polled (0.5 s) until it was shut, enabled DoorY and 0.1 s later
-- disabled DoorX. OnActivate ran it for door pair 1, then pair 2, then went to PostActivation.
-- Now `cd` steps one pair in OnTick; `pair_at` is the OnActivate pair being closed (-1 for a
-- direct call), a loop index over its two pairs.
local rt = require('skymod.rt')

return function(C)
	C.Close = rt.sequence("Idle", "Closing", "Swapping")
	local S = C.Close
	C.__vars.cd = S.Idle
	C.__vars.cd_t = rt.timer(0.0)
	C.__vars.cd_x = rt.form("ObjectReference")
	C.__vars.cd_y = rt.form("ObjectReference")
	C.__vars.pair_at = rt.int(-1)
	C.__vars.TickRate = rt.float(0.1)
	local Pre = rt.state(C, "preactivation")

	local function pair(self, n) if n == 0 then return self.Door1a, self.Door1b end return self.Door2a, self.Door2b end

	function C:CloseAndDisable(DoorX, DoorY)
		if self.cd ~= S.Idle then return end
		self.cd_x, self.cd_y = DoorX, DoorY
		DoorX:SetOpen(false)
		self.cd = S.Closing
		self.cd_t = 0.5
	end

	function Pre:OnActivate(triggerRef)
		if self.pair_at ~= -1 then return end
		self.pair_at = 0
		self:CloseAndDisable(pair(self, 0))
	end

	function Pre:OnTick()
		if self.cd ~= S.Idle and self.cd_t <= 0 then
			if self.cd == S.Closing then
				if self.cd_x:GetOpenState() ~= 3 then
					self.cd_t = 0.5
					return
				end
				self.cd_y:Enable(false)
				self.cd = S.Swapping
				self.cd_t = 0.1
				return
			end
			self.cd_x:Disable(false)
			self.cd = S.Idle
		end
		if self.cd ~= S.Idle or self.pair_at == -1 then return end
		if self.pair_at == 0 then
			self.pair_at = 1
			return self:CloseAndDisable(pair(self, 1))
		end
		self.pair_at = -1
		self:GotoState("postactivation")
	end
end
