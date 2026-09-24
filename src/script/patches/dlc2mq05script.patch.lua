-- pex: enablehm 36e7dd94
-- EnableHM(true) changed Hermaeus Mora's FX, waited 1 s, then enabled him. Now `hm_t` holds that
-- second, None when idle. EnableHM(false) never waited.
local rt = require('skymod.rt')

return function(C)
	C.__vars.hm_t = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)

	function C:EnableHM(enabling)
		if enabling then
			self.DLC2MQ05HermaeusMoraFXRef:ChangeState(true)
			self.hm_t = 1.0
			return
		end
		self.hm_t = rt.None
		self.DLC2MQ05HermaeusMoraFXRef:ChangeState(false)
		self.HermaeusMoraActivator:Disable()
		self.HermaeusMoraTA:Disable()
	end

	function C:OnTick()
		if self.hm_t == rt.None or self.hm_t > 0 then return end
		self.hm_t = rt.None
		self.HermaeusMoraActivator:Enable()
		self.HermaeusMoraTA:Enable()
	end
end
