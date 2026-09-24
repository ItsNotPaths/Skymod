-- pex: waiting.onload f789c5d4
-- OnLoad(waiting) flashed (maybe) then waited 0.1s before settling alpha and aggression. The
-- flash's own wait is defaultGhostScript's; a settle timer here covers the trailing 0.1s. OnTick
-- calls the parent's (already patched for GhostFlash) tick first, since it never resolves once a
-- state here defines its own.
local rt = require('skymod.rt')

return function(C)
	C.__vars.settle_t = rt.timer(rt.None)
	local parent_tick = rt.load("defaultghostscript").__fn.ontick
	local Waiting = rt.state(C, "waiting")

	function Waiting:OnLoad()
		self:addSpell(self.pghostabilitynew, true)
		self:addSpell(self.pghostresistsability, true)
		local flash = 0
		if self.bflicker then
			self:GhostFlash(1)
			flash = 1
		end
		self.settle_t = flash + 0.1
	end

	function C:OnTick()
		parent_tick(self)
		if self.settle_t == rt.None or self.settle_t > 0 then return end
		self.settle_t = rt.None
		self:SetAlpha(0, false)
		self.pghostfxshader:Stop(self)
		self:setAV("Aggression", 0)
	end
end
