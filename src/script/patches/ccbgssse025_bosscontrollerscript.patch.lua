-- pex: summon 523deed0
-- pex: summonphase c155dcf7
-- pex: onupdate 6b8adac9
-- pex: teleportandsetnewsummonphase 2678e0a9
-- pex: teleporttolocation d61f5412
-- OnUpdate chained Summon (poll for 3D), SummonPhase and TeleportToLocation (two 0.5s waits) by
-- calling straight through them. None of the four has a caller outside this unit (bundle), so
-- OnUpdate now drives one Busy-state step sequence with the same shape and order; Summon,
-- SummonPhase, TeleportToLocation and TeleportAndSetNewSummonPhase are folded into it rather than
-- kept as separate blocking entry points nothing else calls.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "boss: " .. msg) end

return function(C)
	C.Step = rt.sequence("Idle", "WanderOut", "WanderIn", "PhaseOut", "PhaseIn", "Summon0", "Summon1", "DirectOut", "DirectIn")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.stepT = rt.timer(0.0)
	C.__vars.previousLoc = rt.form("ObjectReference") -- carried across TeleportToLocation's first wait
	C.__vars.teleport_to = rt.form("ObjectReference")
	C.__vars.teleport_detect = rt.bool(true)
	C.__vars.list_phase = rt.int(0)       -- the phase whose bases the running summon places
	C.__vars.single = rt.bool(false)      -- a direct Summon call: one actor, no second index
	C.__vars.from_update = rt.bool(false) -- the run came from OnUpdate, which re-registers at its end
	local Busy = rt.state(C, "Busy")

	-- phase -> the bases to summon, by marker index
	local summons = {
		[2] = { "summonedGoldenSaintWarrior" },
		[3] = { "summonedDarkSeducerWarrior", "summonedDarkSeducerArcher" },
		[4] = { "summonedGoldenSaintWarrior", "summonedGoldenSaintArcher" },
	}

	local function phaseOf(self) return self.vars.summonphase end

	local function place(at, what) return at:PlaceAtMe(what, 1, false, false) end

	local function enter(self, step, wait)
		self.step = step
		self.stepT = wait
		self:GotoState("Busy")
	end

	local function finish(self)
		self.step = S.Idle
		self:GotoState("")
		if self.from_update and self.shouldUpdate then self:RegisterForSingleUpdate(self.HEALTH_CHECK_DURATION) end
	end

	-- TeleportToLocation up to its first wait
	local function teleportOut(self, step)
		local boss = self.bossRef
		self.fadeOutFX:Play(boss)
		boss:SetGhost(true)
		enter(self, step, self.TELEPORT_SUMMON_FX_DURATION)
		self.previousLoc = place(boss, self.SummonFX)
	end

	local function teleportIn(self, step)
		local boss, marker = self.bossRef, self.teleport_to
		self.step, self.stepT = step, self.stepT + self.TELEPORT_SUMMON_FX_DURATION
		self.TrailFXAbsorb:Play(self.previousLoc, self.TELEPORT_TRAIL_FX_DURATION, marker)
		boss:MoveTo(marker)
		place(boss, self.SummonFX)
	end

	local function teleportDone(self, autodetect)
		local boss = self.bossRef
		self.fadeOutFX:Stop(boss)
		boss:SetGhost(false)
		if autodetect then
			boss:StartCombat(self.PlayerRef)
			boss:CreateDetectionEvent(self.PlayerRef, 100)
		end
	end

	local function summon(self, index)
		local list = summons[self.list_phase]
		local marker = self.summonMarkerRefs[index]
		enter(self, S.Summon0 + index, 1.0) -- Papyrus: at most 10 waits of 0.1 s for the 3D
		place(marker, self.SummonFX)
		self.currentSummons[index] = marker:PlaceActorAtMe(self[list[index]], 4, nil)
	end

	local function summonTick(self)
		local index = self.step == S.Summon0 and 0 or 1
		local actor = self.currentSummons[index]
		if not actor:Is3DLoaded() and self.stepT > 0 then return false end
		actor:StartCombat(self.PlayerRef)
		if index == 0 and not self.single and #summons[self.list_phase] > 1 then
			summon(self, 1)
			return true
		end
		finish(self)
		return false
	end

	-- OnUpdate after the wander teleport: the health check
	local function check(self)
		local current = self.bossRef:GetAVPercentage("Health")
		local old, phase = self.oldHealthPercent, nil
		if old > 0.90 and current <= 0.90 and phaseOf(self) <= 1 then
			phase = 2
		elseif old > 0.66 and current <= 0.66 and phaseOf(self) <= 2 then
			phase = 3
		elseif old > 0.33 and current <= 0.33 and phaseOf(self) <= 3 then
			phase = 4
		end
		self.oldHealthPercent = current
		if not phase then return finish(self) end
		self.vars.summonphase = phase -- set before the action it guards
		self.teleport_to = self.bossCenterTeleportMarkerRef
		teleportOut(self, S.PhaseOut)
	end

	function C:OnUpdate()
		if self.step ~= S.Idle then
			trace("OnUpdate dropped, mid-sequence at " .. tostring(self.step))
			return
		end
		self.from_update, self.single = true, false
		if self.bossRef:GetDistance(self.battlefieldCenterRef) > self.MAX_BOSS_WANDER_DISTANCE then
			self.teleport_to = self.bossCenterTeleportMarkerRef
			teleportOut(self, S.WanderOut)
		else
			check(self)
		end
	end

	local function stepTick(self)
		local st = self.step
		if st == S.Summon0 or st == S.Summon1 then return summonTick(self) end
		if self.stepT > 0 then return false end
		if st == S.WanderOut then
			teleportIn(self, S.WanderIn)
		elseif st == S.WanderIn then
			teleportDone(self, false)
			check(self)
		elseif st == S.PhaseOut then
			teleportIn(self, S.PhaseIn)
		elseif st == S.PhaseIn then
			teleportDone(self, true)
			self:DispelSummons()
			self.list_phase = phaseOf(self)
			if not summons[self.list_phase] then finish(self) else summon(self, 0) end
		elseif st == S.DirectOut then
			teleportIn(self, S.DirectIn)
		elseif st == S.DirectIn then
			teleportDone(self, self.teleport_detect)
			finish(self)
		end
		return true
	end

	-- the named functions start the same runs, so a call from anywhere still works
	function C:TeleportToLocation(teleportMarker, abAutodetectPlayer)
		if self.step ~= S.Idle then return end
		self.from_update, self.single = false, false
		self.teleport_to = teleportMarker
		self.teleport_detect = abAutodetectPlayer ~= false
		teleportOut(self, S.DirectOut)
	end

	function C:TeleportAndSetNewSummonPhase(teleportTarget, phase)
		if self.step ~= S.Idle then return end
		self.from_update, self.single = false, false
		self.vars.summonphase = phase
		self.teleport_to = teleportTarget
		teleportOut(self, S.PhaseOut)
	end

	function C:SummonPhase(phase)
		if self.step ~= S.Idle then return end
		self.from_update, self.single = false, false
		self:DispelSummons()
		self.list_phase = phase
		if summons[phase] then summon(self, 0) end
	end

	function C:Summon(actorToSummon, index)
		if self.step ~= S.Idle then return end
		self.from_update, self.single = false, true
		local marker = self.summonMarkerRefs[index]
		enter(self, S.Summon0 + index, 1.0)
		place(marker, self.SummonFX)
		self.currentSummons[index] = marker:PlaceActorAtMe(actorToSummon)
	end

	function Busy:OnTick()
		while self.step ~= S.Idle and stepTick(self) do end
	end
end
