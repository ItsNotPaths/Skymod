-- pex: startneed 13114fbb
-- pex: setinoblivion 528929c3
-- pex: onupdategametime cf2fe258
-- pex: waitforunlock ef07d261
-- pex: handleattributediseaseapply c1f770b4
-- pex: applyneedstageplayereffects e67cadd0
-- pex: getamounttoincrementby 447503f4
-- A need's update paused 1 s, and 0.1 s more before counting, then gave the new stage spell 0.3 s
-- after taking the old one; `locked` kept other callers waiting meanwhile. Each pause is now a
-- stage of the `updating` run and `locked` is its published fact. A call that waited for the lock
-- is owed and settled when the run ends. The subclasses' NeedUpdateGameTime is called again as
-- each pause ends (PauseNeedTick).
local rt = require('skymod.rt')

return function(C)
	C.Updating = rt.sequence("Idle", "Settling", "Counting", "Applying")
	C.Disease = rt.sequence("Idle", "Owed", "Clearing", "Dispelling")
	C.Oblivion = rt.sequence("None", "Enter", "Exit")
	local U, D, O = C.Updating, C.Disease, C.Oblivion
	local v = C.__vars
	v.TickRate = rt.float(0.1)
	v.updating, v.updateT = U.Idle, rt.timer(0.0)
	v.updateScheduled = rt.bool(false) -- from OnUpdateGameTime: it schedules the next one
	v.updateOwed = rt.bool(false)      -- an OnUpdateGameTime came while locked
	v.updateAfterSleep = rt.bool(false)
	v.updateBonus = rt.float(0.0)      -- the rate reduction the update started with
	v.oblivionOwed = O.None
	v.disease, v.diseaseT = D.Idle, rt.timer(0.0)
	v.diseaseSpell, v.diseaseTarget = rt.form("Spell"), rt.form("Actor")
	v.diseaseEffect = rt.form("ActiveMagicEffect")
	v.effectOwed = rt.bool(false)      -- a stage spell the player gets when effectT runs out
	v.effectSpell, v.effectMessage = rt.form("Spell"), rt.form("Message")
	v.effectT = rt.timer(0.0)
	v.diseaseQSpell, v.diseaseQEffect, v.diseaseQTarget = -- disease calls owed behind the one running
		rt.array_of("Spell"), rt.array_of("ActiveMagicEffect"), rt.array_of("Actor")

	local settle

	local function end_update(self)
		self.updating = U.Idle
		if self.updateScheduled and self:IsRunning() then
			self:RegisterForSingleUpdateGameTime(self.NeedUpdateGameTimeInterval:GetValue())
			if self.firstUpdate then self:UpdateAttributePenalty(self.NeedValue:GetValue()) end -- StartNeed's
			self.firstUpdate = false
		end
		self.locked = false
		settle(self)
	end

	-- NeedUpdateGameTime either starts a pause (the stage moves on) or finishes the update.
	local function step_update(self)
		local before = self.updating
		self:NeedUpdateGameTime()
		if self.updating ~= before then return end
		if self.effectOwed then
			self.updating = U.Applying
		else
			end_update(self)
		end
	end

	local function begin_update(self, scheduled)
		self.locked = true
		self.updateScheduled = scheduled
		self.updateT = 0.0
		step_update(self)
	end

	function C:PauseNeedTick(name, wait)
		local stage = U[name]
		if self.updating >= stage then return false end
		self.updating = stage
		self.updateT = self.updateT + wait
		return true
	end

	local function enter_oblivion(self)
		self.effectOwed = false
		self:RemoveAllNeedSpells()
		self:ClearAttributePenalty()
		self.PenaltyPercentGlobal:SetValue(0)
		self.oldStage = -1
	end

	settle = function(self)
		if self.locked then return end
		if self.oblivionOwed ~= O.None then
			local enter = self.oblivionOwed == O.Enter
			self.oblivionOwed = O.None
			if enter then enter_oblivion(self) else begin_update(self, false) end
			if self.locked then return end
		end
		if self.disease == D.Owed then
			self.locked = true
			self.disease = D.Clearing
			self.diseaseT = 1.0 -- the perk that scales the penalty spell applies late
			self:ClearAttributePenalty()
			return
		end
		if self.updateOwed then
			self.updateOwed = false
			self:OnUpdateGameTime()
		end
	end

	function C:OnUpdateGameTime()
		if not self:IsRunning() then return end
		if self.locked then
			self.updateOwed = true
			return
		end
		begin_update(self, true)
	end

	function C:StartNeed()
		if not self:IsRunning() then self:Start() end
		self:SetNeedStageValues()
		-- its run registers the next update and, being the first, applies the penalty
		if self.NeedUpdateGameTimeInterval then self:OnUpdateGameTime() end
	end

	function C:SetInOblivion(inOblivion)
		self.oblivionOwed = inOblivion ~= false and O.Enter or O.Exit
		settle(self)
	end

	-- Nothing runs beside a run now: a caller that must not overlap one waits on `locked`.
	function C:WaitForUnlock() end

	-- A call while one is already owed or running is queued, not dropped, and applied in order.
	function C:HandleAttributeDiseaseApply(akDisease, akEffectToDispel, akTarget)
		if self.disease == D.Idle then
			self.diseaseSpell, self.diseaseEffect, self.diseaseTarget = akDisease, akEffectToDispel, akTarget
			self.disease = D.Owed
			return settle(self)
		end
		if self.diseaseQSpell == rt.None then
			self.diseaseQSpell = rt.array(0, "Spell")
			self.diseaseQEffect = rt.array(0, "ActiveMagicEffect")
			self.diseaseQTarget = rt.array(0, "Actor")
		end
		self.diseaseQSpell[#self.diseaseQSpell] = akDisease
		self.diseaseQEffect[#self.diseaseQEffect] = akEffectToDispel
		self.diseaseQTarget[#self.diseaseQTarget] = akTarget
	end

	-- pops the oldest owed disease into the active fields; false if none is waiting
	local function next_disease(self)
		local qs, qe, qt = self.diseaseQSpell, self.diseaseQEffect, self.diseaseQTarget
		if qs == rt.None or #qs == 0 then return false end
		self.diseaseSpell, self.diseaseEffect, self.diseaseTarget = qs[0], qe[0], qt[0]
		for j = 0, #qs - 2 do
			qs[j], qe[j], qt[j] = qs[j + 1], qe[j + 1], qt[j + 1]
		end
		qs[#qs - 1], qe[#qe - 1], qt[#qt - 1] = nil, nil, nil
		return true
	end

	local function disease_tick(self)
		if self.diseaseT > 0 then return end
		if self.disease == D.Clearing then
			self.disease = D.Dispelling
			self.diseaseT = self.diseaseT + 0.5 -- its magnitude must be off the player first
			self.diseaseEffect:Dispel()
			return
		end
		self.disease = D.Idle
		self.diseaseTarget:AddSpell(self.diseaseSpell, false)
		self:UpdateAttributePenalty(self.NeedValue:GetValue())
		self.locked = false
		if next_disease(self) then self.disease = D.Owed end
		settle(self)
	end

	function C:ApplyNeedStagePlayerEffects(increasing, stageSpell, stageMessage, stageMessageOnDecrease)
		self:RemoveAllNeedSpells()
		self.effectOwed = true
		self.effectSpell = stageSpell
		self.effectMessage = rt.None
		if not self.firstUpdate then
			if increasing and stageMessage then
				self.effectMessage = stageMessage
			elseif not increasing and stageMessageOnDecrease then
				self.effectMessage = stageMessageOnDecrease
			end
		end
		self.effectT = 0.3 -- WaitMenuMode: a real timer (script-api section 7)
	end

	local function effect_tick(self)
		if not self.effectOwed or self.effectT > 0 then return end
		self.effectOwed = false
		if not self:IsRunning() then return end -- stopped meanwhile: StopNeed took the need spells
		self.PlayerRef:AddSpell(self.effectSpell, false)
		if self.effectMessage then self.effectMessage:Show() end
	end

	local function clamp(x, lo, hi) return rt.static("Survival_GlobalFunctions", "ClampFloatTo", x, lo, hi) end

	function C:GetAmountToIncrementBy(ticks, rateReductionMultiplier)
		if ticks > 1 and rt.static("Game", "QueryStat", "Days Jailed") > self.Survival_PlayerLastKnownDaysJailed:GetValueInt() then
			return 0.0 -- just out of jail
		end
		local amount = self:GetNeedRatePerTick() * ticks
		if self.detectedSleepEvent then
			self.detectedSleepEvent = false
			amount = amount * self.Survival_NeedSleepReducedMetabolismMult:GetValue()
		end
		amount = amount * (1.0 - rateReductionMultiplier)
		if ticks <= 1 then return amount end

		-- waited or slept: stop 25 past the next threshold crossed
		local current = self.NeedValue:GetValue()
		local new = current + amount
		local function crosses(stage) return current < stage and new >= stage end
		local function capped(stage) return clamp(stage + 25.0 - current, 0.0, stage + 25.0) end
		if self.detectedFastTravelEvent then
			self.detectedFastTravelEvent = false
			if crosses(self.needStage3Value) then return capped(self.needStage3Value) end
			return current
		end
		if crosses(self.needStage4Value) then return capped(self.needStage4Value) end
		if crosses(self.needStage5Value) then return capped(self.needStage5Value) end
		return amount
	end

	function C:OnTick()
		effect_tick(self) -- first, so an update waiting on it ends this tick
		if self.updating == U.Applying then
			if not self.effectOwed then end_update(self) end
		elseif self.updating ~= U.Idle and self.updateT <= 0 then
			step_update(self)
		end
		if self.disease > D.Owed then disease_tick(self) end
	end
end
