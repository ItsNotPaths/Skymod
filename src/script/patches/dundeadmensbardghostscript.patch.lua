-- pex: fadeout 157ce86f
-- FadeOut stopped the shader, faded the ghost out and disabled it 0.1 s later. Now `fading` is
-- that 0.1 s, None when idle; the scene fragments wait for it to be None.
local rt = require('skymod.rt')

return function(C)
	C.__vars.fading = rt.timer(rt.None)
	local split_tick = C.__fn.ontick

	function C:FadeOut()
		self.GhostShader:Stop(self)
		self:SetAlpha(0, true)
		self.fading = 0.1
	end

	function C:OnTick()
		split_tick(self)
		if self.fading == rt.None or self.fading > 0 then return end
		self.fading = rt.None
		self:Disable()
	end
end
