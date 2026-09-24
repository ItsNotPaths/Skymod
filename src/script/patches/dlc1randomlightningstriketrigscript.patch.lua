-- pex: castlightingbolts 866a7547 f361a77e
-- pex: handlelightning ef6b1b41
-- pex: oncellattach 4fd4a521
-- HandleLightning looped while ShouldCastLightning: wait 8-10 s, then (cell attached) play the
-- pre-strike sound and wait PreStrikeDelay, strike a random point of the linked chain, and
-- interrupt a concentrated spell after a short wait. The loop is now OnTick in the running state.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1) -- divides the default waits
	C.Step = rt.sequence("Waiting", "PreStrike", "Casting")
	C.__vars.step = C.Step.Waiting
	C.__vars.waitT = rt.timer(0.0)
	local Running = rt.state(C, "Running")

	local function attached(ref) return ref:GetParentCell():IsAttached() end

	-- The top of HandleLightning's loop: ShouldCastLightning is read only here.
	local function next_cycle(self)
		self.step = C.Step.Waiting
		if not self.ShouldCastLightning then return self:GotoState("") end
		self.waitT = self.waitT + rt.static("Utility", "RandomFloat", self.WaitForCastMin, self.WaitForCastMax)
	end

	-- The end of CastLightingBolts.
	local function end_cast(self)
		self.ClosestActorToStrikePoint = rt.None
		self.CurrentCastPoint = 0
		next_cycle(self)
	end

	local function strike(self)
		if not attached(self) then return end_cast(self) end
		self.CurrentCastPoint = rt.static("Utility", "RandomInt", 1, self.MaxLightningPoints)
		local point = self:GetNthLinkedRef(self.CurrentCastPoint)
		if not (point:Is3DLoaded() and attached(point)) then return end_cast(self) end
		self.LightningSpell:Cast(self, point)
		if not self.forceQuiet then
			self.CloseSoundinstanceID = self.CloseImpactSound:Play(point)
			self.FarSoundinstanceID = self.CloseImpactSound:Play(point)
		end
		if not self.IsConcentratedSpell then return end_cast(self) end
		self.step = C.Step.Casting
		self.waitT = self.waitT + self.TimeBeforeInterruptingConcentratedSpell
	end

	function C:OnCellAttach()
		self.MaxLightningPoints = self:GetLinkedRef():CountLinkedRefChain(rt.None, 100)
		self.ShouldCastLightning = true
		if self:GetState() == "Running" then return end -- a run happens once
		self.waitT = 0.0
		self:GotoState("Running")
		next_cycle(self)
	end

	function Running:OnTick()
		if self.waitT > 0 then return end
		if self.step == C.Step.Waiting then
			if not attached(self) then return next_cycle(self) end
			if not self.PreStrikeSound then return strike(self) end
			self.PreStrikeSoundInstanceID = self.PreStrikeSound:Play(self)
			self.step = C.Step.PreStrike
			self.waitT = self.waitT + self.PreStrikeDelay
		elseif self.step == C.Step.PreStrike then
			strike(self)
		else
			self:InterruptCast()
			end_cast(self)
		end
	end
end
