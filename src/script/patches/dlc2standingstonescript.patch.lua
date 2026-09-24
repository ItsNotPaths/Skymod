-- pex: waiting.onactivate 48142e52
-- pex: workonpillar 8c71d84a
-- WorkOnPillar ran a fixed sequence of four fades (2 s each) then polled IsFurnitureInUse every
-- 1 s. Now a stage plus a timer walk the same sequence in OnTick. Waiting.OnActivate no longer
-- waits itself, but when it starts WorkOnPillar it must stay Busy until WorkOnPillar's own tail
-- returns to Waiting; the ready-spell and not-ready-message branches are unchanged (no wait).
local rt = require('skymod.rt')

return function(C)
	C.WOP = rt.sequence("Idle", "Fade", "Settle", "Hold", "Furniture")
	C.__vars.wopStage = C.WOP.Idle
	C.__vars.wopBusy = rt.bool(false)
	C.__vars.wopSleepMove = rt.bool(true)
	C.__vars.wopT = rt.timer(0.0)
	local Waiting = rt.state(C, "Waiting")

	function C:WorkOnPillar(bSleepMove)
		if bSleepMove == nil then bSleepMove = true end
		if self.wopBusy then return end -- a second start while one runs is dropped
		if not self:GetLinkedRef() then return end
		self.wopBusy = true
		self.wopSleepMove = bSleepMove
		rt.static("Game", "DisablePlayerControls")
		if bSleepMove == false then
			self.FadeToBlackImod:Apply()
			self.MAGStandingStoneActivateA:Play(rt.static("Game", "GetPlayer"))
		else
			self.FadeToBlackImod:PopTo(self.FadeToBlackHoldImod)
		end
		self.wopStage = C.WOP.Fade
		self.wopT = 2.0 -- fresh wait: WorkOnPillar is an external entry point
	end

	function C:OnTick()
		if self.wopStage == C.WOP.Idle then return end
		if self.wopStage == C.WOP.Fade then
			if self.wopT > 0 then return end
			if self.wopSleepMove == false then self.FadeToBlackImod:PopTo(self.FadeToBlackHoldImod) end
			rt.static("Game", "ForceThirdPerson")
			rt.static("Game", "GetPlayer"):MoveTo(self:GetLinkedRef())
			self.DLC2PillarMiraakVoice:Start()
			self.wopStage = C.WOP.Settle
			self.wopT = self.wopT + 2.0
			return
		end
		if self.wopStage == C.WOP.Settle then
			if self.wopT > 0 then return end
			self.FadeToBlackHoldImod:PopTo(self.FadeToBlackBackImod)
			self.FadeToBlackHoldImod:Remove()
			self.MAGStandingStoneActivateB:Play(rt.static("Game", "GetPlayer"))
			self.wopStage = C.WOP.Hold
			self.wopT = self.wopT + 2.0
			return
		end
		if self.wopStage == C.WOP.Hold then
			if self.wopT > 0 then return end
			rt.static("Game", "EnablePlayerControls")
			self.wopStage = C.WOP.Furniture
		end
		if self.wopStage == C.WOP.Furniture then
			if self.wopT > 0 then return end
			if self:GetLinkedRef():IsFurnitureInUse() then
				self.wopT = self.wopT + 1.0
				return
			end
			self.DLC2PillarMiraakVoice:Stop()
			self.DLC2Pillar:SetStage(100)
			self.wopStage = C.WOP.Idle
			self.wopBusy = false
			self:GotoState("Waiting") -- the sole terminal state; harmless if already there
		end
	end

	function Waiting:OnActivate(akActionRef)
		self:GotoState("Busy")
		local player = rt.static("Game", "GetPlayer")
		if akActionRef == player then
			if self.Freed then
				if self.GameDaysPassed:GetValue() > self.DelayReady and not player:HasSpell(self.DLC2SpellLearned) then
					self.DelayReady = self.GameDaysPassed:GetValue() + 0.75
					self:PlayAnimation("stage3")
					self.DLC2StoneActivateSound:Play(self)
					rt.cast(akActionRef, "Actor"):AddSpell(self.DLC2SpellLearned, true)
					self.DLC2SacredStoneSpell:Cast(akActionRef)
				else
					self.DLC2StandingStoneNotReadyMsg:Show()
				end
				self:GotoState("Waiting")
			else
				self:WorkOnPillar(false) -- its own tail returns to Waiting once done
			end
		else
			if not self.Freed and rt.cast(akActionRef, "Actor") then
				self:WorkOnPillarNPC(rt.cast(akActionRef, "Actor"))
			end
			self:GotoState("Waiting")
		end
	end
end
