-- pex: oneffectfinish 01e3f578 b6144553
-- pex: oneffectstart c8135742 214e57b2
-- OnEffectStart waited 1 s for the spell's other effects, then took or dispelled the target and
-- set DoneStarting; OnEffectFinish polled DoneStarting every second before releasing the target.
-- Now OnTick in Starting ends the start, and a finish that came early (`finished`) runs after it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.start_t = rt.timer(0.0)
	C.__vars.target = rt.form("Actor")
	C.__vars.finished = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Starting = rt.state(C, "Starting")

	local function release(self)
		self.target:RemoveFromFaction(self.DLC1VampireFeedNoCrimeFaction)
		self.DLC1VampireMesmerize:ClearRefFrom(self.target)
	end

	function C:OnEffectStart(Target, Caster)
		if self:GetState() == "Starting" then return end
		self.target = Target
		Target:AddToFaction(self.DLC1VampireFeedNoCrimeFaction)
		self.start_t = 1.0
		self:GotoState("Starting")
	end

	function Starting:OnTick()
		if self.start_t > 0 then return end
		local t = self.target
		if t:HasMagicEffect(self.InfluenceAggDownFFAimed) or t:HasMagicEffect(self.PerkMasterMindAggDownFFAimed) then
			self.DLC1VampireMesmerize:ForceRefInto(t)
		else
			self:Dispel()
		end
		self.DoneStarting = true
		self:GotoState("")
		if self.finished then release(self) end
	end

	function C:OnEffectFinish(Target, Caster)
		self.target = Target
		if self.DoneStarting then return release(self) end
		self.finished = true
	end
end
