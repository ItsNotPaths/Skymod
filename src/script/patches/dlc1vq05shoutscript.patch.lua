-- pex: oneffectstart dc32d23d
-- pex: spellfxcast db1669f6
-- The shout woke the first enabled grave group: shout, 1 s, cast at the five targets, 2 s,
-- explosions, activate the group, 3 s, disable it. Now OnTick in Raising walks those steps;
-- `graves` is the group being raised.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Shouting", "Casting", "Waking")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.step_t = rt.timer(0.0)
	C.__vars.graves = rt.form("ObjectReference")
	C.__vars.TickRate = rt.float(0.1)
	local Raising = rt.state(C, "Raising")

	function C:OnEffectStart(Target, Caster)
		if self.step ~= S.Idle then return end
		for i = 1, 4 do
			local g = self["gravesMarker0" .. i]
			if g:IsEnabled() then
				self.graves = g
				self.shoutFX:Cast(Caster, self.casterMarker)
				self.step = S.Shouting
				self.step_t = 1.0
				return self:GotoState("Raising")
			end
		end
	end

	function C:spellFXCast()
		for i = 1, 5 do self.spellFX:Cast(self.casterMarker, self["casterTarget0" .. i]) end
	end

	function Raising:OnTick()
		if self.step_t > 0 then return end
		if self.step == S.Shouting then
			self:spellFXCast()
			self.step = S.Casting
			self.step_t = self.step_t + 2.0
		elseif self.step == S.Casting then
			for i = 1, 5 do self["casterTarget0" .. i]:PlaceAtMe(self.raiseExplosion) end
			self.graves:Activate(self.graves)
			self.step = S.Waking
			self.step_t = self.step_t + 3.0
		elseif self.step == S.Waking then
			self.step = S.Idle
			self.graves:Disable()
			self:GotoState("")
		end
	end
end
