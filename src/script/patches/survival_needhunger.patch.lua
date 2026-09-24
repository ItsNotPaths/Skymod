-- pex: incrementneedbytick 4d9fc715
-- pex: needupdategametime 7af7abba
-- pex: applyhungerstage ad4252fb
-- pex: decreasehungerbuffered e5861c1d
-- pex: decreasehungerimpl cb402a0a
-- pex: increasehunger d217e2c1
-- pex: processeatingbuffer 567f2750
-- NeedUpdateGameTime paused in IncrementNeedByTick before raising hunger. It is now called again
-- as each pause of the base's update run ends; the pre-pause facts are `update*` fields.
-- ApplyHungerStage, IncreaseHunger and the eating functions need no change: the stage spell no
-- longer blocks them (Survival_NeedBase.ApplyNeedStagePlayerEffects).
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
		local value = self:IncrementNeed(self.NeedValue:GetValue(), amount, -1.0)
		self.lastTimeInGameHours = now
		return value
	end

	function C:NeedUpdateGameTime()
		if self.updating.name == "Idle" then
			self.updateAfterSleep = self.detectedSleepEvent
			if self.conditions.isInPlaneOfOblivion then
				self.lastTimeInGameHours = hours()
				return
			end
			local race = self.PlayerRef:GetActorBase():GetRace()
			self.updateBonus = 0.0
			if self.Survival_HungerResistRacesMinor:HasForm(race) then self.updateBonus = self.Survival_RacialBonusMinor:GetValue() end
		end
		local value = self:IncrementNeedByTick(self.updateBonus)
		if not value then return end -- paused
		self:ApplyHungerStage(value, self.lastValue)
		local weakened = self.Survival_AfflictionWeakened
		if not self.updateAfterSleep and value >= self.needStage5Value and not self.PlayerRef:HasSpell(weakened)
			and rt.static("Utility", "RandomFloat") <= self.Survival_AfflictionHungerChance:GetValue() then
			self.Survival_AfflictionWeakenedMsg:Show()
			self.PlayerRef:AddSpell(weakened, false)
		end
		self.lastValue = value
	end
end
