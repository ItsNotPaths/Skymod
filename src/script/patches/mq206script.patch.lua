-- pex: cleanuptimetraveleffects cf876574
-- CleanUpTimeTravelEffects played the time-travel camera/sound, waited 3s, applied the white
-- fade, waited 1s, then released the weather override and stopped the effects. A stage plus one
-- timer now does the same two beats in OnTick.
local rt = require('skymod.rt')

return function(C)
	C.Effects = rt.sequence("Idle", "Warp", "Fade")
	C.__vars.effects = C.Effects.Idle
	C.__vars.effectsT = rt.timer(0.0)
	local S = C.Effects

	local function player() return rt.static("Game", "GetPlayer") end

	function C:CleanUpTimeTravelEffects()
		if self.effects ~= S.Idle then return end -- a run happens once
		self.FXTimeWarpCamAttachEffect:Play(player())
		self.QSTMQ206TimeTravel2DSound:Play(player())
		self.effects = S.Warp
		self.effectsT = 3.0
	end

	function C:OnTick()
		if self.effects == S.Idle or self.effectsT > 0 then return end
		if self.effects == S.Warp then
			self.effects = S.Fade
			self.effectsT = 1.0
			self.FadeToWhiteInOutImod:Apply(1.0)
		else
			self.effects = S.Idle
			rt.static("Weather", "ReleaseOverride")
			self.FXTimeTravelCamAttachEffect:Stop(player())
			rt.static("ImageSpaceModifier", "RemoveCrossFade", 1.0)
		end
	end
end
