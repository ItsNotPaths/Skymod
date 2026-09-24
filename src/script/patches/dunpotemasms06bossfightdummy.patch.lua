-- pex: onload 55b6c808
-- OnLoad ran the whole fight: wait for stage 80, then attack every 8, 6 and 4 s while `phase` (set
-- by the scene) stays ONE, TWO and THREE, raising the dead between phases, then banish Potema on
-- FOUR and wait for her "end" animation event. Now OnTick in the fight state walks the steps.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.05) -- divides every wait
	C.Step = rt.sequence("AwaitFight", "PhaseOne", "RaiseTwo", "PhaseTwo", "RaiseThree", "PhaseThree", "Banishing", "Transition")
	C.__vars.step = C.Step.AwaitFight
	C.__vars.t = rt.timer(0.0)
	local Fight = rt.state(C, "Fight")
	local S = C.Step

	-- One pass of `while phase == name: AttackFunc(); wait(w)`; false once the loop is over.
	local function attack_pass(self, name, w)
		if self.phase ~= name then return false end
		self:AttackFunc()
		self.t = self.t + w
		return true
	end

	local function next_phase(self, blend, step)
		self.Potema:SetAnimationVariableFloat("fPotemaFightVar", blend)
		self.BeamAttack:Cast(self.Potema, self.TombDoor)
		self.step = step
		self.t = self.t + 0.1
	end

	local function raise_all(self, ...)
		for _, w in ipairs({ ... }) do self.raise:Cast(w, w) end
	end

	local function finish(self)
		self.Potema:Disable()
		self.Potema:Delete()
		self.step = S.AwaitFight
		self:GotoState("")
	end

	function C:OnLoad()
		if self:GetState() == "Fight" then return end -- a run happens once
		self.player = rt.static("Game", "GetPlayer")
		self.ActivatorTargetRef = self.player:PlaceAtMe(self.FXEmptyActivator)
		self.PotPosX = self.Potema:GetPositionX()
		self.PotPosY = self.Potema:GetPositionY()
		self.step = S.AwaitFight
		self.t = 0.0
		self:GotoState("Fight")
		self:OnTick()
	end

	function Fight:OnTick()
		if self.t > 0 then return end
		if self.step == S.AwaitFight then
			if not self.myQuest:GetStageDone(80) then
				self.t = self.t + 3.0
				return
			end
			self:setUpAliases()
			self.phase = "ONE"
			self.Potema:SetAnimationVariableFloat("fPotemaFightVar", 0.25)
			self.MagicAttack:Cast(self.Potema, self.waveA01)
			self.MagicAttack:Cast(self.Potema, self.waveA02)
			self.step = S.PhaseOne
		end
		if self.step == S.PhaseOne then
			if not attack_pass(self, "ONE", 8.0) then next_phase(self, 0.75, S.RaiseTwo) end
			return
		end
		if self.step == S.RaiseTwo then
			raise_all(self, self.waveA01, self.waveA02)
			self.step = S.PhaseTwo
		end
		if self.step == S.PhaseTwo then
			if not attack_pass(self, "TWO", 6.0) then next_phase(self, 1.0, S.RaiseThree) end
			return
		end
		if self.step == S.RaiseThree then
			raise_all(self, self.waveA01, self.waveA02, self.waveB01, self.waveB02, self.waveB03)
			self.step = S.PhaseThree
		end
		if self.step == S.PhaseThree then
			if attack_pass(self, "THREE", 4.0) then return end
			self:RegisterForAnimationEvent(self.Potema, "EffectDoorHit")
			self.BeamAttack:Cast(self.Potema, self.TombDoor)
			if self.phase ~= "FOUR" then return finish(self) end
			self.Potema:InterruptCast()
			self.Potema:SetAnimationVariableFloat("fPotemaFightVar", 0)
			self.DefeatSFXmarker:Enable()
			self.SFXidle01:Disable()
			self.SFXidle02:Disable()
			self.step = S.Banishing
			self.t = self.t + 0.25
			return
		end
		if self.step == S.Banishing then
			self:RegisterForAnimationEvent(self.Potema, "end")
			self.Potema:PlayAnimation("TransitionAnim")
			self.step = S.Transition
		end
	end

	local door_hit = C.__fn.onanimationevent
	function C:OnAnimationEvent(akSource, asEventName)
		door_hit(self, akSource, asEventName)
		if self.step ~= S.Transition or akSource ~= self.Potema or asEventName ~= "end" then return end
		self.QSTMS06PotemaBanishExplosion:Play(self.TombDoor)
		self.TombDoor:SetOpen()
		finish(self)
	end
end
