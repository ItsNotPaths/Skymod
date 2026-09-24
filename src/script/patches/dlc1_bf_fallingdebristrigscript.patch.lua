-- pex: checkforplayer 8282a0f4
-- pex: forcecollapse 3196ea5a
-- CheckForPlayer polled the trigger every 0.2 s; when the player stood in it, the prince cast and
-- either a pillar fell (wait for the chunk's "impact", then 5 s, then hide it) or a ceiling piece
-- fell (0.5 s, then the prince stops). ForceCollapse waited a random 0.5..8 s, then dropped the
-- piece. Now OnTick in the Falling state walks those steps.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Watching", "Pillar", "Settling", "Ceiling", "Forcing")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Falling = rt.state(C, "Falling")

	local function prince(self) return rt.cast(self.Prince, "Actor") end
	local function link(self, n) return self:GetLinkedRef(self["LinkCustom0" .. n]) end
	local function vars(self) return self.vars end -- CheckForPlayer and ForceCollapse are also bool properties

	function C:CheckForPlayer()
		if self.myQuest:IsStageDone(self.stageToCheck) then return end
		if not self.DebrisWasTriggered then vars(self)["::checkforplayer_var"] = true end
		if self.step ~= S.Idle then return end
		self.step = S.Watching
		self:GotoState("Falling")
		self:OnTick()
	end

	function C:ForceCollapse()
		if self.DebrisWasTriggered then return end
		self.DebrisWasTriggered = true
		self.step = S.Forcing
		self.t = rt.static("Utility", "RandomFloat", 0.5, 8)
		self:GotoState("Falling")
	end

	local function done(self)
		self.step = S.Idle
		self:GotoState("")
	end

	local function collapse(self)
		self.DebrisController:Activate(self)
		self.DebrisWasTriggered = true
		local p = prince(self)
		p:SetSubGraphFloatVariable("ftoggleBlend", 1.0)
		self.DLC01_SunAuraCloakEffect:Play(p)
		p:PlayIdle(link(self, 3) and self.PrinceBigCast or self.PrinceCast)
		rt.static("Game", "ShakeCamera", self, 0.3, 1)
		if link(self, 3) then
			self:RegisterForAnimationEvent(link(self, 3), "impactFloor")
			local pos = self.PillarPosition
			if pos >= 1 and pos <= 4 then
				self.QSTFalmerBossColumnDestruction2D:Play(self)
				link(self, 3):PlayAnimation("anim" .. pos)
				link(self, 2):PlayAnimation("anim" .. pos)
			end
			self.step = S.Pillar
		else
			if link(self, 4) then link(self, 4):Enable() end
			if link(self, 5) then link(self, 5):Enable() end
			self:RegisterForAnimationEvent(link(self, 2), "stage1State_to_stage2State")
			link(self, 2):PlayAnimation("Stage2")
			self.step = S.Ceiling
			self.t = 0.5
		end
	end

	function Falling:OnTick()
		if self.t > 0 then return end
		if self.step == S.Watching then
			if self.DebrisWasTriggered or not vars(self)["::checkforplayer_var"] then return done(self) end
			if self.myQuest:IsStageDone(self.stageToCheck) then return end -- Papyrus kept looping here
			if self:GetTriggerObjectCount() > 0 then collapse(self) end
		elseif self.step == S.Pillar then
			if link(self, 2):IsAnimRunning("anim" .. self.PillarPosition) then return end
			local p = prince(self)
			p:PlayIdle(self.PrinceBigCastEnd)
			self:GetLinkedRef():PlaceAtMe(self.DLC1SnowElfColumnHavokExplosion)
			self.FXRumbleFalmerBoss2D:Play(self)
			rt.static("Game", "ShakeCamera", self, 0.5, 1)
			rt.static("Game", "ShakeController", 0.5, 0.5, 1)
			self:GetLinkedRef():KnockAreaEffect(1, 1024)
			self.DLC01_SunAuraCloakEffect:Stop(p)
			p:SetSubGraphFloatVariable("ftoggleBlend", 0.0)
			self.step = S.Settling
			self.t = 5.0
		elseif self.step == S.Settling then
			link(self, 3):Disable(true)
			done(self)
		elseif self.step == S.Ceiling then
			self.DLC01_SunAuraCloakEffect:Stop(prince(self))
			prince(self):SetSubGraphFloatVariable("ftoggleBlend", 0.0)
			done(self)
		elseif self.step == S.Forcing then
			if link(self, 2) then link(self, 2):PlayAnimation("Stage2") end -- nothing followed its wait
			done(self)
		end
	end
end
