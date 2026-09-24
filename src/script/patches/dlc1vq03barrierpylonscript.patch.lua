-- pex: lowerthebarrier e19b053e 0b2a6681
-- LowerTheBarrier played Activate01 and waited for "Done", then walked a timed chain: the stones
-- 2, 0.5, 0.3 and 0.2 s apart, the barrier's fade 0.4 s later, its removal 1 s after that and the
-- light 0.6 s after. Now the event starts the chain and OnTick in Lowering walks it on a stopwatch.
local rt = require('skymod.rt')

-- each stage's wait from the step before it, and what it does when due
local CHAIN = {
	Stone01 = { 2.0, function(self) self.DLC1VQ03BarrierStone01:Activate(self) end },
	Stone03 = { 0.5, function(self) self.DLC1VQ03BarrierStone03:Activate(self) end },
	Stone02 = { 0.3, function(self) self.DLC1VQ03BarrierStone02:Activate(self) end },
	Stone04 = { 0.2, function(self) self.DLC1VQ03BarrierStone04:Activate(self) end },
	Fade = { 0.4, function(self)
		rt.static("Sound", "StopInstance", self.barrierSoundInstance)
		self.DLC1VQ03Barrier:PlayGamebryoAnimation("AnimTrans01")
		self:RegisterForSingleUpdate(0.1)
	end },
	Remove = { 1.0, function(self)
		self.DLC1VQ03Barrier:DisableNoWait()
		self.DLC1VQ03BarrierLight:Disable(true)
	end },
	Light = { 0.6, function(self) self.DLC1VQ03LightActivateParent:Activate(self) end },
}

return function(C)
	C.Step = rt.sequence("Idle", "Animating", "Stone01", "Stone03", "Stone02", "Stone04", "Fade", "Remove", "Light")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.sw = rt.stopwatch(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local Lowering = rt.state(C, "Lowering")

	function C:LowerTheBarrier()
		if self.step ~= S.Idle then return end
		self.step = S.Animating
		self:GotoState("Lowering")
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Activate01")
	end

	function Lowering:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" or self.step ~= S.Animating then return end
		self.AMBEvernightCryptRumbleSD:Play(self.DLC1VQ03Barrier)
		rt.static("Game", "ShakeController", self.rumbleAmount1, self.rumbleAmount1, self.rumbleDuration)
		rt.static("Game", "ShakeCamera", rt.None, self.cameraShakeAmount1, self.rumbleDuration)
		self.step = S.Stone01
		self.sw = 0.0
	end

	function Lowering:OnTick()
		while self.step > S.Animating do
			local due = CHAIN[self.step.name]
			if self.sw < due[0] then return end
			self.sw = self.sw - due[0]
			local last = self.step == S.Light
			self.step = last and S.Idle or self.step + 1
			due[1](self)
			if last then return self:GotoState("") end
		end
	end
end
