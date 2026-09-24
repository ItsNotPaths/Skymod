-- pex: moveplayertoearth 894c1b8c
-- pex: moveplayertosky 669148b5
-- MovePlayerToEarth and MovePlayerToSky each chained fixed Utility.Wait calls around fades and
-- moves. Now two stage fields, each with its own stopwatch, read from the class's OnTick (which
-- already ticks for the S6-split TeleportPlayerToSky; that runs first, unchanged).
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick
	C.__vars.TickRate = rt.float(0.05)

	C.Fall = rt.sequence("Idle", "Falling", "Bloom", "White")
	C.__vars.fall = C.Fall.Idle
	C.__vars.fallClock = rt.stopwatch(0.0)

	C.Sky = rt.sequence("Idle", "Fading", "Float1", "Float2")
	C.__vars.sky = C.Sky.Idle
	C.__vars.skyClock = rt.stopwatch(0.0)
	C.__vars.skyPlayer = rt.form("Actor")

	local FALL_TIME, PRE_EFFECT_TIME, FADE_TIME = 6.0, 1.0, 1.5
	local BLOOM_TIME = FALL_TIME - PRE_EFFECT_TIME - FADE_TIME

	function C:MovePlayerToEarth()
		if self.fall ~= C.Fall.Idle then return end -- a second start is dropped
		self:ForceCameraAndDisableControls()
		self.DA09SkyPlaneCollision:disable()
		self.fall = C.Fall.Falling
		self.fallClock = 0.0
	end

	function C:MovePlayerToSky()
		if self.sky ~= C.Sky.Idle then return end
		rt.static("Game", "EnableFastTravel", false)
		self:ForceCameraAndDisableControls()
		self:SafeGuardAgainstDragons(true)
		self.DA09MeridiaStatueFXRef:PlayAnimation("playanim01")
		self.DA09SkyPlaneCollision:enable()
		self.DA09MeridiaRef:MoveTo(self.DA09MeridiaStartMarker)
		self.DA09MeridiaRef:enable()
		self.skyPlayer = rt.static("Game", "GetPlayer")
		self.DA09SkyFadeInOut:apply()
		self.sky = C.Sky.Fading
		self.skyClock = 0.0
	end

	function C:OnTick()
		split_tick(self)

		if self.fall == C.Fall.Falling and self.fallClock >= PRE_EFFECT_TIME then
			self.DA09BloomIMOD:ApplyCrossFade(BLOOM_TIME)
			self.fall = C.Fall.Bloom
			self.fallClock = self.fallClock - PRE_EFFECT_TIME
		end
		if self.fall == C.Fall.Bloom and self.fallClock >= BLOOM_TIME then
			self.DA09WhiteIMOD:ApplyCrossFade(FADE_TIME)
			self.fall = C.Fall.White
			self.fallClock = self.fallClock - BLOOM_TIME
		end
		if self.fall == C.Fall.White and self.fallClock >= FADE_TIME then
			local player = rt.static("Game", "GetPlayer")
			player:MoveTo(self.DA09StatueMarker)
			self.DA09SkyBeam2:disable()
			self.DA09MeridiaRef:disable()
			rt.static("ImageSpaceModifier", "RemoveCrossFade", FALL_TIME)
			if self:GetStage() > 300 then
				self.DA09FXBeamSkyRef:Disable()
				self.DA09MeridiaStatueFXRef:PlayAnimation("playanim02")
				self.QSTBeamMeridiaStatueLPRef:disable()
			end
			rt.static("Game", "EnablePlayerControls")
			rt.static("Game", "EnableFastTravel", true)
			self:SafeGuardAgainstDragons(false)
			self.fall = C.Fall.Idle
		end

		if self.sky == C.Sky.Fading and self.skyClock >= 1.0 then
			self.skyPlayer:TranslateToRef(self.DA09FloatMarker1, 150)
			self.sky = C.Sky.Float1
			self.skyClock = self.skyClock - 1.0
		end
		if self.sky == C.Sky.Float1 and self.skyClock >= 2.5 then
			self.skyPlayer:TranslateToRef(self.DA09SkyMarker, 4000)
			self.sky = C.Sky.Float2
			self.skyClock = self.skyClock - 2.5
		end
		if self.sky == C.Sky.Float2 and self.skyClock >= 4.5 then
			self.skyPlayer:StopTranslation()
			self.DA09SkyBeam2:enable()
			self.QSTBeamMeridiaStatueLPRef:enable()
			self.skyPlayer:moveto(self.DA09SkyMarker)
			rt.static("Game", "EnableFastTravel", false)
			rt.static("Game", "EnablePlayerControls", { abFighting = false, abCamSwitch = false })
			self.sky = C.Sky.Idle
		end
	end
end
