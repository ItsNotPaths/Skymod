-- pex: onmagiceffectapply 15c0bca4
-- A frost or fire hit changed the player's cold, then Processing ignored hits for 2 s. The 2 s is
-- now a timer that OnTick in Processing reads.
local rt = require('skymod.rt')

return function(C)
	C.__vars.processingT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Processing = rt.state(C, "Processing")

	function C:OnMagicEffectApply(akCaster, akEffect)
		self:GotoState("Processing")
		self.processingT = 2.0
		if akEffect:HasKeyword(self.MagicDamageFrost) then
			self:GetColderFromSpellHit(self.amountToChangeColdOnSpellHit)
		elseif akEffect:HasKeyword(self.MagicDamageFire) then
			self:GetWarmerFromSpellHit(self.amountToChangeColdOnSpellHit)
		elseif self.Survival_FrostbitePoisonEffects:HasForm(akEffect) then
			self:GetColderFromSpellHit(self.amountToChangeColdOnSpellHit)
		end
	end

	function Processing:OnTick()
		if self.processingT <= 0 then self:GotoState("") end
	end
end
