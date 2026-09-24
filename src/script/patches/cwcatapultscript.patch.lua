-- pex: launch e328fe49
-- launch() played the fire animation and waited for aeLaunch before firing the weapon. Now the
-- event fires it; `launching` says the arm is up with its payload.
local rt = require('skymod.rt')

return function(C)
	C.__vars.launching = rt.bool(false)
	local converted = C.__fn.onanimationevent

	function C:launch()
		self:GotoState(self.busy)
		self.launching = true
		self:PlayAnimation(self.aeFire) -- OnLoad registered aeLaunch
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if self.launching and asEventName == self.aeLaunch then
			self.launching = false
			self.WeaponToFire:Fire(self, self.AmmoToFire)
		end
		converted(self, akSource, asEventName)
	end
end
