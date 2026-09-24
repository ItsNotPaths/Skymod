-- pex: incrementneedbytick dfd14c0f
-- pex: needupdategametime 1ac826ff
-- pex: applycoldstage a2ee50ce
-- pex: decreasecold f051627a
-- pex: getamounttoincrementby 306e495c
-- pex: increasecold 925cb4ad
-- NeedUpdateGameTime paused in IncrementNeedByTick before moving cold toward the area's ceiling.
-- It is now called again as each pause of the base's update run ends; the pre-pause facts are
-- `update*` fields. ApplyColdStage, IncreaseCold, DecreaseCold and GetAmountToIncrementBy need no
-- change: neither the stage spell nor the parent's count blocks them now (Survival_NeedBase).
local rt = require('skymod.rt')

return function(C)
	C.__vars.updateCeiling = rt.float(0.0) -- the most cold the area allows, when the update started

	local function hours() return rt.static("Utility", "GetCurrentGameTime") * 24 end

	-- above the ceiling the player warms back to it, except in combat
	local function toward_ceiling(self, current, ceiling, ticks)
		if self.PlayerRef:IsInCombat() then return current end
		local warmed = current - self.coldToRestoreInWarmArea * ticks
		if warmed < ceiling then return self:DecrementNeed(current, current - ceiling, -1.0, -1.0) end
		return self:DecrementNeed(current, self.coldToRestoreInWarmArea * ticks, -1.0, -1.0)
	end

	function C:IncrementNeedByTick(ceilingValue, rateReductionMultiplier)
		if self:PauseNeedTick("Settling", 1.0) then return end
		local current = self.NeedValue:GetValue()
		if self.firstUpdate then
			self.lastTimeInGameHours = hours()
			return current + 1
		end
		if self:IsTalkingToNPC() then
			self.lastTimeInGameHours = hours()
			return current
		end
		if self:PauseNeedTick("Counting", 0.1) then return end
		local now = hours()
		local ticks = self:GetTicks(now, self.lastTimeInGameHours)
		local amount = self:GetAmountToIncrementBy(ticks, rateReductionMultiplier)
		local value
		if current > ceilingValue then
			value = toward_ceiling(self, current, ceilingValue, ticks)
		elseif current + amount > ceilingValue then
			value = self:IncrementNeed(current, ceilingValue - current, -1.0)
		else
			value = self:IncrementNeed(current, amount, -1.0)
		end
		self.lastTimeInGameHours = now
		return value
	end

	-- the start of NeedUpdateGameTime; false when the update ends here
	local function begin(self)
		self.updateAfterSleep = self.detectedSleepEvent
		if self.cachedTimescale == 0.0 then self:PrecacheValues() end
		if self.conditions.isInPlaneOfOblivion then
			self.lastTimeInGameHours = hours()
			self.wasInOblivion = true
			return false
		end
		self.currentColdLevel = self:UpdateColdLevel()
		local nearHeat = self.heatcheck:IsPlayerNearHeatAndStanding()
		self:DisplayColdLevelTransitionMessage(self.currentColdLevel)
		if nearHeat then
			self.lastTimeInGameHours = hours()
			self.wasInOblivion = false
			self.lastColdLevel = self.currentColdLevel
			return false
		end
		self.updateCeiling = self:GetMaxStageValue(self:GetColdStageMaximum(self.currentColdLevel))
		local clamp = rt.static("Survival_GlobalFunctions", "ClampFloatTo", self.PlayerRef:GetWarmthRating(), 0.0, self.cachedColdResistMaxValue)
		self.updateBonus = (self.warmthMaxBonusPercent * clamp) / self.cachedColdResistMaxValue
		return true
	end

	function C:NeedUpdateGameTime()
		if self.updating.name == "Idle" and not begin(self) then return end
		local value = self:IncrementNeedByTick(self.updateCeiling, self.updateBonus)
		if not value then return end -- paused
		self:ApplyColdStage(value, self.lastValue)
		local frostbitten = self.Survival_AfflictionFrostbitten
		if not self.updateAfterSleep and value >= self.needStage5Value and not self.PlayerRef:HasSpell(frostbitten)
			and rt.static("Utility", "RandomFloat") <= self.Survival_AfflictionColdChance:GetValue() then
			self.Survival_AfflictionFrostbittenMsg:Show()
			self.PlayerRef:AddSpell(frostbitten, false)
		end
		self:UpdateTemperatureUI(self.currentColdLevel, self.lastValue, value)
		self:CheckIfMaxCold(value)
		self.wasInOblivion = false
		self.lastValue = value
		self.lastColdLevel = self.currentColdLevel
	end
end
