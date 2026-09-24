-- pex: running.onbeginstate 3dc28240
-- OnBeginState ran a `while hauntActive` loop, polling hauntingStage every loopTimer and reading
-- GetCurrentRealTime() (a stub) for each stage's own sound/shake/ghost deadlines. Now OnTick in
-- the running state does one pass per tick, and every deadline is a timer holding what remains.
-- Stage 8's own Utility.Wait(lightsBackOnTime) becomes a None-until-running timer, the same idiom
-- the S6 splitter uses for a single wait (see TeleportPlayerToSky in the converted class).
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(C.__vars["::looptimer_var"].default)
	C.__vars["::currentsoundtimer_var"] = rt.timer(0.0)
	C.__vars["::ghosttimer01_var"] = rt.timer(0.0)
	C.__vars["::ghosttimer02_var"] = rt.timer(0.0)
	C.__vars["::ghosttimer03_var"] = rt.timer(0.0)
	C.__vars["currentshaketimer"] = rt.timer(0.0)
	C.__vars.stage8Wait = rt.timer(rt.None)

	local Run = rt.state(C, "running")

	function Run:OnBeginState()
		self.hauntActive = true
	end

	function Run:OnTick()
		if not self.hauntActive then return end
		local stage = self.hauntingStage

		if stage == 1 then
			if not self.TriggerSoundDone then
				self.TriggerSoundDone = true
				self:GhostActivate(self.BedroomItem)
				self.QSTDA10SpookyDistant:play(self.DA10SpookySoundMarker01)
			end
		elseif stage == 2 then
			-- DoortoSlamDone is never set (dead in the original), so this crossfade re-applies every pass.
			self.DA10HauntingISMDIn:applyCrossFade(10.0)
		elseif stage == 3 then
			if self.NormalLightsON then
				self.NormalLightsON = false
				self.QSTDA10SpookyDistant:play(self.DA10SpookySoundMarker01)
				self.NormalLights:GetReference():disable()
			end
			if self.currentSoundTimer <= 0 then
				self.randomizerForStage3 = rt.static("Utility", "RandomInt", 0, 1)
				if self.randomizerForStage3 == 0 then
					self.QSTDA10SpookyDistant:play(self.DA10SpookySoundMarker06)
				else
					self.QSTDA10SpookyDistant:play(self.DA10SpookySoundMarker07)
				end
				self.currentSoundTimer = rt.static("Utility", "RandomFloat", 1.5, 3.0)
			end
		elseif stage == 4 then
			if not self.secondISMDDone then
				self.secondISMDDone = true
				self.DA10HauntingISMDLoop:applyCrossFade(15.0)
			end
			if self.ghostTimer01 <= 0 then
				self:GhostActivateBasementPicker()
				self.ghostTimer01 = rt.static("Utility", "RandomFloat", self.ghostTimerMin, self.ghostTimerMax)
			end
			if not self.PhaseOneLightsON then
				self.PhaseOneLightsON = true
				self.PhaseOneLights:GetReference():enable()
				self.ChairEnableMarker:GetReference():Enable()
			end
			if self.currentSoundTimer <= 0 then
				self:GhostSoundPicker()
				self.currentSoundTimer = rt.static("Utility", "RandomFloat", 0, 0.2)
			end
		elseif stage == 6 then
			if not self.SingleRumbleDone then
				self.SingleRumbleDone = true
				self.ControllerShakeL = rt.static("Utility", "RandomFloat", 0.3, 0.7)
				self.ControllerShakeR = rt.static("Utility", "RandomFloat", 0.3, 0.7)
				self.ControllerShakeDuration = 1.5
				local player = rt.static("Game", "GetPlayer")
				self.QSTDA10Rumble:play(player)
				rt.static("Game", "ShakeCamera", { afStrength = 1.0 })
				rt.static("Game", "ShakeController", self.ControllerShakeL, self.ControllerShakeR, self.ControllerShakeDuration)
			end
			if not self.PhaseTwoLightsON then
				self.PhaseTwoLightsON = true
				self.PhaseTwoLights:GetReference():enable()
			end
			if self.currentSoundTimer <= 0 then
				self:GhostSoundPicker()
				self.currentSoundTimer = rt.static("Utility", "RandomFloat", 0, 0.1)
			end
		elseif stage == 7 then
			if self.ghostTimer01 <= 0 then
				self:GhostActivateBasementPicker()
				self.ghostTimer01 = rt.static("Utility", "RandomFloat", self.ghostTimerMin, self.ghostTimerMax)
			end
			if self.ghostTimer02 <= 0 then
				self:GhostActivatePicker()
				self.ghostTimer02 = rt.static("Utility", "RandomFloat", self.ghostTimerMin, self.ghostTimerMax)
			end
			if self.ghostTimer03 <= 0 then
				self:GhostActivatePicker()
				self.ghostTimer03 = rt.static("Utility", "RandomFloat", self.ghostTimerMin, self.ghostTimerMax)
			end
			if self.currentShakeTimer <= 0 then
				self.ControllerShakeL = rt.static("Utility", "RandomFloat", 0.0, 1.0)
				self.ControllerShakeR = rt.static("Utility", "RandomFloat", 0.0, 1.0)
				self.ControllerShakeDuration = rt.static("Utility", "RandomFloat", 1.0, 2.0)
				rt.static("Game", "ShakeCamera", { afStrength = 1.0 })
				rt.static("Game", "ShakeController", self.ControllerShakeL, self.ControllerShakeR, self.ControllerShakeDuration)
				local player = rt.static("Game", "GetPlayer")
				self.QSTDA10Rumble:play(player)
				self.currentShakeTimer = rt.static("Utility", "RandomFloat", 0, self.shakeTimer)
			end
			if self.currentSoundTimer <= 0 then
				self:GhostSoundPicker()
				self.currentSoundTimer = rt.static("Utility", "RandomFloat", 0, 0.1)
			end
		elseif stage == 8 then
			if self.PhaseTwoLightsON then
				self.PhaseTwoLightsON = false
				self.PhaseTwoLights:GetReference():disable()
			end
			if self.PhaseOneLightsON then
				self.PhaseOneLightsON = false
				self.PhaseOneLights:GetReference():disable()
			end
			if self.stage8Wait == rt.None then
				self.stage8Wait = self.lightsBackOnTime
			elseif self.stage8Wait <= 0 then
				self.stage8Wait = rt.None
				if not self.NormalLightsON then
					self.NormalLightsON = true
					self.NormalLights:GetReference():enable()
				end
				if not self.ghostsStopped then
					self.ghostsStopped = true
					self:DropAllGhosts()
				end
				if self.currentSoundTimer <= 0 then
					self:GhostSoundPicker()
					self.currentSoundTimer = rt.static("Utility", "RandomFloat", 0, 0.5)
				end
			end
		elseif stage == 9 then
			self.hauntActive = false
			rt.static("ImageSpaceModifier", "RemoveCrossFade", 3.0)
			self:SetStage(100)
		end
	end
end
