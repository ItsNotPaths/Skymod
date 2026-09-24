-- pex: waiting.onactivate 7e9923cb
-- pex: active.onactivate bb295747
-- pex: ringfinish c64519d9
-- Waiting's first branch (fresh puzzle) opens (4s), reveals, runs RingFinish, then marks the
-- quest done once RingFinish settles. Waiting's second branch and Active's handler are the same
-- body (shift the pressed ring, wait 3s, finishCheck) so they share one step. RingFinish stays a
-- real function of its own (a mod may call it): three named beats (3s, 3s, 6s), start-and-return.
local rt = require('skymod.rt')

return function(C)
	C.Reveal = rt.sequence("Idle", "Opening", "Waiting")
	C.__vars.reveal = C.Reveal.Idle
	C.__vars.revealT = rt.timer(0.0)

	C.Ring = rt.sequence("Idle", "Wait1", "Wait2", "Wait3")
	C.__vars.ring = C.Ring.Idle
	C.__vars.ringT = rt.timer(0.0)

	C.__vars.shiftPending = rt.bool(false)
	C.__vars.shiftT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local R, S = C.Reveal, C.Ring

	local function player() return rt.static("Game", "GetPlayer") end

	local function shift_pressed_ring(self)
		if self.bPuzzRing1 then
			self.mainScript:RingShift(1)
		elseif self.bPuzzRing2 then
			self.mainScript:RingShift(2)
		elseif self.bPuzzRing3 then
			self.mainScript:RingShift(3)
		end
	end

	local function start_shift(self)
		self:GotoState("busy")
		shift_pressed_ring(self)
		self.shiftPending = true
		self.shiftT = 3.0
	end

	function C:RingFinish()
		if self.ring ~= S.Idle then return end -- a run happens once
		self.BloodSealEffect:PlayAnimation("playanim01")
		self.mainScript:RingShift(1)
		self.mainScript:RingShift(2)
		self.mainScript:RingShift(3)
		self.ring = S.Wait1
		self.ringT = 3.0
	end

	local Waiting = rt.state(C, "waiting")
	function Waiting:OnActivate(triggerRef)
		if triggerRef ~= player() then return end
		if not self.mainScript.questDone and self.MQ203:GetStageDone(150) then
			self:GotoState("busy")
			self.MQ203:SetStage(180)
			self.reveal = R.Opening
			self.revealT = 4.0
		elseif self.mainScript.questDone and self.MQ203:GetStage() < 200 then
			start_shift(self)
		end
	end

	local Active = rt.state(C, "active")
	function Active:OnActivate(triggerRef)
		if triggerRef ~= player() then return end
		start_shift(self)
	end

	function C:OnTick()
		if self.reveal ~= R.Idle and self.revealT <= 0 then
			if self.reveal == R.Opening then
				self.reveal = R.Waiting
				self.MQ203:SetStage(185)
				self:RingFinish()
			elseif self.ring == S.Idle then -- Waiting: RingFinish has settled
				self.reveal = R.Idle
				self.mainScript.questDone = true
			end
		end
		if self.ring ~= S.Idle and self.ringT <= 0 then
			if self.ring == S.Wait1 then
				self.ring = S.Wait2
				self.ringT = 3.0
				self.BloodSealEffect:PlayAnimation("playanim02")
				self.mainScript:RingShift(1)
				self.mainScript:RingShift(2)
			elseif self.ring == S.Wait2 then
				self.ring = S.Wait3
				self.ringT = 6.0
				self.mainScript:RingShift(1)
				self.MQ203:SetStage(200)
				self.LightEnabler:Enable(false)
			else
				self.ring = S.Idle
				self.BloodSealEffect:PlayAnimation("playanim03")
			end
		end
		if self.shiftPending and self.shiftT <= 0 then
			self.shiftPending = false
			self:finishCheck()
		end
	end
end
