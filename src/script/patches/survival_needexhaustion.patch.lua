-- pex: incrementneedbytick 69e8d582
-- pex: needupdategametime 6e337cb4
-- pex: applyexhaustionstage 17748494
-- pex: decreaseexhaustion e99ab2ce
-- pex: increaseexhaustion 359f9bef
-- NeedUpdateGameTime paused in IncrementNeedByTick before raising exhaustion. It is now called
-- again as each pause of the base's update run ends; the pre-pause facts are `update*` fields.
-- ApplyExhaustionStage, IncreaseExhaustion and DecreaseExhaustion need no change: the stage spell
-- no longer blocks them (Survival_NeedBase.ApplyNeedStagePlayerEffects).
local rt = require('skymod.rt')

return function(C)
	local function hours() return rt.static("Utility", "GetCurrentGameTime") * 24 end

	function C:IncrementNeedByTick(rateReductionMultiplier)
		if self:PauseNeedTick("Settling", 1.0) then return end
		if self.firstUpdate then
			self.lastTimeInGameHours = hours()
			return self.NeedValue:GetValue() + 1
		end
		if self:PauseNeedTick("Counting", 0.1) then return end
		local now = hours()
		local amount = self:GetAmountToIncrementBy(self:GetTicks(now, self.lastTimeInGameHours), rateReductionMultiplier)
		if self.PlayerRef:IsOverEncumbered() then
			amount = amount * self.Survival_ExhaustionOverEncumberedMult:GetValue()
		end
		local value = self:IncrementNeed(self.NeedValue:GetValue(), amount, -1.0)
		self.lastTimeInGameHours = now
		return value
	end

	local function racial_bonus(self)
		local race = self.PlayerRef:GetActorBase():GetRace()
		if self.Survival_ExhaustionResistRacesMajor:HasForm(race) then return self.Survival_RacialBonusMajor:GetValue() end
		if self.Survival_ExhaustionResistRacesMinor:HasForm(race) then return self.Survival_RacialBonusMinor:GetValue() end
		return 0.0
	end

	function C:NeedUpdateGameTime()
		if self.updating.name == "Idle" then
			self.updateAfterSleep = self.detectedSleepEvent
			if self.conditions.isInPlaneOfOblivion then
				self.lastTimeInGameHours = hours()
				return
			end
			if self.playerSleeping then
				self.playerSleeping = false
				self.lastTimeInGameHours = hours()
				return
			end
			self.updateBonus = racial_bonus(self)
		end
		local value = self:IncrementNeedByTick(self.updateBonus)
		if not value then return end -- paused
		self:ApplyExhaustionStage(value, self.lastValue, self:CanGetRestedBonus(false))
		local addled = self.Survival_AfflictionAddled
		if not self.updateAfterSleep and value >= self.needStage5Value and not self.PlayerRef:HasSpell(addled)
			and rt.static("Utility", "RandomFloat") <= self.Survival_AfflictionExhaustionChance:GetValue() then
			self.Survival_AfflictionAddledMsg:Show()
			self.PlayerRef:AddSpell(addled, false)
		end
		self.lastValue = value
	end
end
