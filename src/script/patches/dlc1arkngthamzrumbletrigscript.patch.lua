-- pex: forcerumbleandresettimer a877c47b
-- pex: handlerumble 74b47f30
-- ForceRumbleAndResetTimer did an initial burst, then two waits before handing off to HandleRumble,
-- which looped "wait a random interval, maybe pulse" while ShouldRumble. OnActivate already resets
-- ShouldRumble to false before calling Force, so a re-activation is meant to restart the burst, not
-- be dropped; the old loop notices ShouldRumble false at its next wait and stops. Now one stage
-- field plus a timer, both driven from the "Rumbling" state's OnTick.
local rt = require('skymod.rt')

return function(C)
	local S = rt.sequence("Wind1", "Wind2", "LoopWait", "LoopPulse")
	C.RumbleStage = S
	C.__vars.TickRate = rt.float(0.5)
	C.__vars.rumbleStage = S.Wind1
	C.__vars.rumbleT = rt.timer(0.0)
	local Rumbling = rt.state(C, "Rumbling")

	local function pulse(self, volume, camShake, knockAmt)
		if not (self:Is3DLoaded() and self.shouldrumble) then return false end
		local player = rt.static("Game", "GetPlayer")
		local id = self.ambrumbleshake:Play(self)
		rt.static("Sound", "SetInstanceVolume", id, volume)
		rt.static("Game", "ShakeCamera", player, camShake, 1.5)
		rt.static("Game", "ShakeController", camShake, camShake, 1.5)
		player:KnockAreaEffect(knockAmt, 16)
		self:PlaceDustExplosions()
		return true
	end

	function C:ForceRumbleAndResetTimer()
		local player = rt.static("Game", "GetPlayer")
		local id = self.ambrumbleshake:Play(self)
		rt.static("Sound", "SetInstanceVolume", id, 0.7)
		rt.static("Game", "ShakeCamera", player, 0.5, 1.5)
		rt.static("Game", "ShakeController", 0.5, 0.5, 1.5)
		player:KnockAreaEffect(0.3, 16)
		self:PlaceDustExplosions()
		self.rumbleStage = S.Wind1
		self.rumbleT = 1.0
		self:GotoState("Rumbling")
	end

	function C:HandleRumble()
		if self:GetState() == "Rumbling" and self.rumbleStage >= S.LoopWait then return end -- already looping
		self.rumbleStage = S.LoopWait
		self.rumbleT = rt.static("Utility", "RandomFloat", self.waitforrumblemin, self.waitforrumblemax)
		self:GotoState("Rumbling")
	end

	function Rumbling:OnTick()
		if self.rumbleT > 0 then return end
		if self.rumbleStage == S.Wind1 then
			local player = rt.static("Game", "GetPlayer")
			rt.static("Game", "ShakeCamera", player, 0.3, 3)
			rt.static("Game", "ShakeController", 0.3, 0.3, 3)
			self.rumbleStage = S.Wind2
			self.rumbleT = self.waitforrumblemax
			return
		end
		if self.rumbleStage == S.Wind2 then
			self.shouldrumble = true
			self.rumbleStage = S.LoopWait
			self.rumbleT = rt.static("Utility", "RandomFloat", self.waitforrumblemin, self.waitforrumblemax)
			return
		end
		if self.rumbleStage == S.LoopWait then
			if self.dlc1arkgnthamzrumbleglobal:GetValue() == 0 then self.shouldrumble = false end
			if not self.shouldrumble then
				self:GotoState("")
				return
			end
			local fired
			if not self.checkdistance then
				fired = pulse(self, 0.5, 0.3, 0.1)
			elseif rt.static("Game", "GetPlayer"):GetDistance(self) < self.distancefromtrigger then
				fired = pulse(self, 0.3, 0.2, 0.1)
			end
			if fired then
				self.rumbleStage = S.LoopPulse
				self.rumbleT = 1.0
			else
				self.rumbleStage = S.LoopWait
				self.rumbleT = rt.static("Utility", "RandomFloat", self.waitforrumblemin, self.waitforrumblemax)
			end
			return
		end
		if self.rumbleStage == S.LoopPulse then
			local player = rt.static("Game", "GetPlayer")
			rt.static("Game", "ShakeCamera", player, 0.1, 3)
			rt.static("Game", "ShakeController", 0.1, 0.1, 3)
			self.rumbleStage = S.LoopWait
			self.rumbleT = rt.static("Utility", "RandomFloat", self.waitforrumblemin, self.waitforrumblemax)
		end
	end
end
