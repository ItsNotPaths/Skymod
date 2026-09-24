-- pex: oneffectstart 28f6de35 41ce4b0a
-- OnEffectStart played the transformation idle and, 10 s later, made sure the race had changed
-- (the SetRace animation event usually did it first). Now a timer holds the 10 s.
local rt = require('skymod.rt')

return function(C)
	C.__vars.change_t = rt.timer(rt.None)
	C.__vars.target = rt.form("Actor")
	local split_tick = C.__fn.ontick

	function C:OnEffectStart(Target, Caster)
		if Target:GetActorBase():GetRace() == self.DLC1VampireLordRace then return end
		self:RegisterForAnimationEvent(Target, "SetRace")
		Target:PlayIdle(self.IdleVampireTransformation)
		self.target = Target
		self.change_t = 10.0
	end

	function C:OnTick()
		split_tick(self)
		if self.change_t == rt.None or self.change_t > 0 then return end
		self.change_t = rt.None
		self:TransformIfNecessary(self.target)
	end
end
