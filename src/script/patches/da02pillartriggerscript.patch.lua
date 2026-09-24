-- pex: turnoff 599ec21a
-- pex: turnon ba9ba57d
-- TurnOn and TurnOff played the shrine animation and waited for PowUp or PowDown before setting
-- AnimState. The script already registers both events on the shrine; the event now sets it.
local rt = require('skymod.rt')

return function(C)
	local converted = C.__fn.onanimationevent

	function C:TurnOn()
		rt.cast(self.DA02PillarRef, "DefaultSoundControlScript"):playSoundByName("ShrineActivate")
		self.BoethiahBluePulseLightRef:Enable()
		self.DA02PillarRef:PlayAnimation("playanim01")
		self.ShrineOfBoethiahRef:PlayAnimation("playanim01")
	end

	function C:TurnOff()
		rt.cast(self.DA02PillarRef, "DefaultSoundControlScript"):stopSoundByName("ShrineActivate")
		self.BoethiahBluePulseLightRef:Disable()
		self.DA02PillarRef:PlayAnimation("reset")
		self.ShrineOfBoethiahRef:PlayAnimation("reset")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource == self.ShrineOfBoethiahRef then
			if asEventName == self.PowUp then self.AnimState = 1 end
			if asEventName == self.PowDown then self.AnimState = 0 end
		end
		converted(self, akSource, asEventName) -- counts again: someone may have left meanwhile
	end
end
