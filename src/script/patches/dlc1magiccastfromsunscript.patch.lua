-- pex: oneffectstart 50c2b278 e33f77da
-- pex: placeexplosionandrotate eb5ffa39 1af83cce
-- OnEffectStart waited fWaitDelay, maybe 0.25 s for the weather, then placed the sun explosion,
-- whose marker lived 0.25 s, and only then registered the recast. OnEffectFinish spun until both
-- sun functions were done. Now `cast` steps the start and `ending` waits for them in OnTick.
local rt = require('skymod.rt')

return function(C)
	C.Cast = rt.sequence("Idle", "Delay", "Weather", "Exploding")
	local S = C.Cast
	C.__vars.cast = S.Idle
	C.__vars.cast_t = rt.timer(0.0)
	C.__vars.marker = rt.form("ObjectReference")
	C.__vars.ending = rt.bool(false)
	local split_tick = C.__fn.ontick
	local function game(fn, ...) return rt.static("Game", fn, ...) end

	function C:OnEffectStart(Target, Caster)
		self.fSunYPosition = game("GetSunPositionY")
		self.CasterActor = Caster
		self.TargetActor = Target
		self.cast = S.Delay
		self.cast_t = self.fWaitDelay
	end

	local function recast(self)
		self.cast = S.Idle
		if self.SpellRef then
			self:RegisterForSingleUpdate(rt.static("Utility", "RandomFloat", self.fRecast, self.fRecastRand))
		end
	end

	function C:PlaceExplosionAndRotate()
		self.bFunctionRunningExplosion = true
		local marker = self.CasterActor:PlaceAtMe(self.PlacedXMarker)
		local p = self:FindSunArtLocation(self.fExplosionVectorScale)
		marker:SetPosition(rt.aget(p, 0), rt.aget(p, 1), rt.aget(p, 2))
		local x, y, z = game("GetSunPositionX"), self.fSunYPosition, math.max(game("GetSunPositionZ"), 0.25)
		local ax = rt.static("Math", "atan", y / z)
		local ay = -rt.static("Math", "atan", x / z)
		if ax < 0.0 then ax = ax + 360 end
		if ay < 0.0 then ay = ay + 360 end
		marker:SetAngle(ax, ay, 0.0)
		marker:PlaceAtMe(self.ExplosionRef)
		self.MyActivator = marker:PlaceAtMe(self.ActivatorRef)
		self.MyActivator:EnableNoWait(false)
		if self.myMusic then self.myMusic:Add() end
		self:RegisterForSingleUpdateGameTime(0.85)
		self.marker = marker
		self.cast = S.Exploding
		self.cast_t = 0.25
	end

	local function cast_tick(self)
		if self.cast == S.Idle or self.cast_t > 0 then return end
		if self.cast == S.Delay then
			if not self.bContinueRunning then self.cast = S.Idle return end
			if self.TargetActor ~= self.Player then return recast(self) end
			if self.bUseLocalNiceWeather then
				self.CurrentWeatherForm = rt.static("Weather", "GetCurrentWeather")
				if self.CurrentWeatherForm:GetClassification() == 0 then self.WeatherForm = rt.None end
			end
			if not self.WeatherForm then return self:PlaceExplosionAndRotate() end
			rt.static("Weather", "ReleaseOverride")
			self.cast = S.Weather
			self.cast_t = self.cast_t + 0.25
		elseif self.cast == S.Weather then
			self.WeatherForm:SetActive(self.bHoldWeatherUntilEnd, true)
			self:PlaceExplosionAndRotate()
		elseif self.cast == S.Exploding then
			self.marker:Disable()
			self.marker:Delete()
			self.marker = rt.None
			self.bFunctionRunningExplosion = false
			recast(self)
		end
	end

	-- was: spin until both sun functions finish, then clean up
	function C:OnEffectFinish(Target, Caster)
		self.bContinueRunning = false
		self.ending = true
		self:OnTick()
	end

	local function end_tick(self)
		if not self.ending or self.bFunctionRunningSunSpell or self.bFunctionRunningExplosion then return end
		self.ending = false
		if self.WeatherForm and self.bHoldWeatherUntilEnd then rt.static("Weather", "ReleaseOverride") end
		if self.MyActivator then
			self.MyActivator:Disable()
			self.MyActivator:Delete()
			self.MyActivator = rt.None
		end
	end

	function C:OnTick()
		split_tick(self)
		cast_tick(self)
		end_tick(self)
	end
end
