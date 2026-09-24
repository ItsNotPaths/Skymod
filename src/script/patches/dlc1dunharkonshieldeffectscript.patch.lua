-- pex: oneffectfinish afeec7ad
-- OnEffectFinish played the shield's destroy or stop animation and waited for its "End" before
-- disabling it. Now OnTick waits for that animation to end.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.__vars.shield_anim = rt.string("") -- the animation the shield plays before it goes
	local split_tick = C.__fn.ontick

	function C:OnEffectFinish(Target, Caster)
		Caster:GetActorBase():SetInvulnerable(false)
		Caster:RemoveSpell(self.DLC1dunHarkonDrainCloak)
		self.DLC1dunHarkonShrineLight:DisableNoWait(true)
		self.DLC1dunHarkonAbsorbFX:DisableNoWait(true)
		local shield = self.DLC1dunHarkonShadowShieldRef
		if rt.cast(self.HarkonAlias, "DLC1dunHarkonBossBattle").ShieldDestroyed then
			shield:PlaceAtMe(self.DLC1HarkonShieldAurielsBowExplosion)
			self.shield_anim = "DestroyShieldAnim"
		else
			self.shield_anim = "StopEffect"
		end
		shield:PlayAnimation(self.shield_anim)
	end

	function C:OnTick()
		split_tick(self)
		if self.shield_anim == "" or self.DLC1dunHarkonShadowShieldRef:IsAnimRunning(self.shield_anim) then return end
		self.shield_anim = ""
		self.DLC1dunHarkonShadowShieldRef:Disable(false)
	end
end
