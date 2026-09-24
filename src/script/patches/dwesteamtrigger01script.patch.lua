-- pex: swaitingforhit.onhit 0eab1e13
-- pex: startlooping bc76f0fc
-- A hit opened the resonator (wait for "done") and opened its linked door. StartLooping cycled
-- while loaded: wait, steam on, 0.25 s, then open the resonator, 2 s, steam off, wait, close it.
-- Now `loop` is the cycle's step, stepped by OnTick and the "done" events; `hit_opening` marks
-- an opening started by a hit.
local rt = require('skymod.rt')

return function(C)
	C.Loop = rt.sequence("Idle", "Delay", "Steam", "Opening", "Hold", "Back", "Closing")
	local L = C.Loop
	C.__vars.loop = L.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.hit_opening = rt.bool(false)
	C.__vars.cycle_opened = rt.bool(false) -- this cycle opened the resonator, so it closes it
	C.__vars.TickRate = rt.float(0.05)
	local Waiting = rt.state(C, "sWaitingForHit")

	local function steam(self) return self:GetLinkedRef(self.LinkCustom01) end

	local function next_cycle(self)
		if not self:Is3DLoaded() then
			self.loop = L.Idle
			return
		end
		self.loop = L.Delay
		self.t = self.fDelayBeforeLooping
	end

	function Waiting:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		self.bBeenHit = true
		self:GotoState("sBeenHit")
		self.hit_opening = true
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("open")
	end

	function C:StartLooping()
		if self.loop ~= L.Idle then return end
		next_cycle(self)
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" then return end
		if self.hit_opening then
			self.hit_opening = false
			self:GetLinkedRef():SetOpen()
		elseif self.loop == L.Opening then
			self:GetLinkedRef():SetOpen()
			self.loop = L.Hold
			self.t = 2.0
		elseif self.loop == L.Closing then
			self:GetLinkedRef():SetOpen(false)
			self:GotoState("sWaitingForHit")
			next_cycle(self)
		end
	end

	function C:OnTick()
		if self.loop == L.Idle or self.t > 0 then return end
		if self.loop == L.Delay then
			steam(self):EnableNoWait(true)
			self.loop = L.Steam
			self.t = self.t + 0.25
		elseif self.loop == L.Steam then
			if not self:Is3DLoaded() then return next_cycle(self) end
			self.cycle_opened = not self.bBeenHit
			if self.bBeenHit then
				self.loop = L.Hold
				self.t = self.t + 2.0
			else
				self:GotoState("sBeenHit")
				self.loop = L.Opening
				self:RegisterForAnimationEvent(self, "done")
				self:PlayAnimation("open")
			end
		elseif self.loop == L.Hold then
			steam(self):DisableNoWait(true)
			self.loop = L.Back
			self.t = self.t + self.fDelayBeforeLoopingBack
		elseif self.loop == L.Back then
			if self.cycle_opened then
				self.loop = L.Closing
				self:PlayAnimation("close")
			else
				next_cycle(self)
			end
		end
	end
end
