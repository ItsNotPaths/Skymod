-- pex: ghostflash 270c99e0
-- GhostFlash hid the ghost, waited `time` s, then restored it. Now a timer field, read in OnTick
-- (already ticking for OnDying's split continuation, called first). A second call while one is
-- running is dropped.
local rt = require('skymod.rt')

return function(C)
	C.__vars.flash_t = rt.timer(rt.None)
	local split_tick = C.__fn.ontick

	function C:GhostFlash(time)
		if self.flash_t ~= rt.None then return end
		self.pghostfxshader:stop(self)
		self:setGhost(true)
		self.flash_t = time
	end

	function C:OnTick()
		split_tick(self)
		if self.flash_t == rt.None or self.flash_t > 0 then return end
		self.flash_t = rt.None
		self:setGhost(false)
		self:setAlpha(0.3, false)
		self.pghostfxshader:play(self, -1.0)
		self.bflash = false
	end
end
