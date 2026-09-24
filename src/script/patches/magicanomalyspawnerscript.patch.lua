-- pex: anomalydied 5c1350d5
-- pex: opened.onbeginstate 0a893601
-- OnBeginState ran an init block (lights, three summons) then waited 3.5 s, then polled every
-- 0.5 s for each anomaly's death, calling anomalyDied when one died. anomalyDied waited 0.5 s
-- before vanishing once the count hit 0. Now one stage sequence in the "opened" state;
-- anomalyDied stays callable (a mod or the poll can call it) and starts the vanish stage itself.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", tostring(self) .. " " .. msg) end

return function(C)
	local split_tick = C.__fn.ontick -- this class's S6 split waits; an OnTick here must run them
	-- each stage names the step that runs when `wait` runs out
	C.Portal = rt.sequence("Closed", "Massive", "Spawn1", "Spawn2", "Spawn3", "Settle", "Watch", "Vanish", "Gone")
	C.__vars.portal = C.Portal.Closed
	C.__vars.wait = rt.timer(0.0)

	local opened = rt.state(C, "opened")

	local function spawn(self)
		local a = self:PlaceActorAtMe(self.EncMagicAnomaly, 4, None)
		a:SetScale(rt.static("Utility", "RandomFloat", 0.7, 1.25))
		return a
	end

	function opened:OnBeginState()
		if self.portal ~= C.Portal.Closed then return end
		self.portal, self.wait = C.Portal.Massive, 0.75
		trace(self, "opened: light explosion")
		self:PlaceAtMe(self.ExplosionIllusionLight01, 1, false, false)
	end

	local function check(self, gate, anomaly)
		if self[gate] == 0 and anomaly:IsDead() == true then
			self:anomalyDied()
			self[gate] = self[gate] + 1
		end
	end

	-- the "waiting" state's own OnTriggerEnter timer is already cleared before GotoState("opened")
	-- runs, so the class's split OnTick has nothing left to do here; no need to chain it.
	function opened:OnTick()
		if split_tick then split_tick(self) end
		if self.wait > 0 then return end
		local step = self.portal
		if step == C.Portal.Massive then
			self.portal, self.wait = C.Portal.Spawn1, 0.5
			self:PlaceAtMe(self.ExplosionIllusionMassiveLight01, 1, false, false)
			self:KnockAreaEffect(1.0, 900.0)
			self:SetAnimationVariableFloat("fToggleBlend", self.fToggleBlendFull)
		elseif step == C.Portal.Spawn1 then
			self.portal, self.wait = C.Portal.Spawn2, 1.5
			self.myEncMagicAnomaly01 = spawn(self)
		elseif step == C.Portal.Spawn2 then
			self.portal, self.wait = C.Portal.Spawn3, 0.5
			self.myEncMagicAnomaly02 = spawn(self)
		elseif step == C.Portal.Spawn3 then
			self.portal, self.wait = C.Portal.Settle, 3.5
			self.myEncMagicAnomaly03 = spawn(self)
			self.numberOfEnemiesAlive = 3
		elseif step == C.Portal.Settle then
			self.portal, self.wait = C.Portal.Watch, 0.5
			self:SetAnimationVariableFloat("fDampRate", 0.03)
			self:SetAnimationVariableFloat("fToggleBlend", self.fToggleBlendOpen)
		elseif step == C.Portal.Watch then
			if self.numberOfEnemiesAlive <= 0 then return end
			self.wait = 0.5
			check(self, "Gate1", self.myEncMagicAnomaly01)
			check(self, "Gate2", self.myEncMagicAnomaly02)
			check(self, "Gate3", self.myEncMagicAnomaly03)
			return
		elseif step == C.Portal.Vanish then
			self.portal = C.Portal.Gone
			self:Disable(true)
			if self.MGR30:IsRunning() == true then self.MGR30:SetStage(20) end
		else
			return
		end
		trace(self, "opened step " .. tostring(step))
	end

	-- start-and-return: the last death starts the 0.5 s vanish instead of waiting here
	function C:anomalyDied()
		self.myCurrentBlend = self:GetAnimationVariableFloat("fToggleBlend")
		self:SetAnimationVariableFloat("fToggleBlend", self.myCurrentBlend - (self.fToggleBlendOpen / 3.0))
		self.numberOfEnemiesAlive = self.numberOfEnemiesAlive - 1
		trace(self, "anomalyDied: " .. self.numberOfEnemiesAlive .. " left")
		if self.numberOfEnemiesAlive == 0 then
			self.portal, self.wait = C.Portal.Vanish, 0.5
		end
	end
end
