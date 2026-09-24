-- pex: ondeath 24fc1bd4
-- OnDeath ran one of two symmetric ten-step gem sequences (white/black ending), each step a wait
-- then an effect, ending in a fade and a quest stage. A step list plus one timer now walks
-- whichever branch applies.
local rt = require('skymod.rt')

local function play(shaderField, ...)
	local gems = { ... }
	return function(self) for _, g in ipairs(gems) do self[shaderField]:Play(self[g], -1.0) end end
end

-- Explicit [N] keys: this Lua fork is 0-based for positional { a, b } literals, and this list is
-- walked by a 1-based step field.
local function steps_for(shaderField, fadeField, stage)
	return {
		[1] = { wait = 2.0, fn = play(shaderField, "gemA") },
		[2] = { wait = 1.5, fn = play(shaderField, "gemB") },
		[3] = { wait = 0.5, fn = play(shaderField, "gemC") },
		[4] = { wait = 0.5, fn = play(shaderField, "gemD") },
		[5] = { wait = 1.0, fn = play(shaderField, "gemE", "gemF") },
		[6] = { wait = 1.0, fn = play(shaderField, "gemG", "gemH") },
		[7] = { wait = 1.5, fn = play(shaderField, "gemI", "gemJ") },
		[8] = { wait = 1.0, fn = play(shaderField, "gemK") },
		[9] = { wait = 2.5, fn = function(self) self[fadeField]:apply(1.0) end },
		[10] = { wait = 2.75, fn = function(self) self.DA01:SetStage(stage) end },
	}
end

return function(C)
	C.__vars.deStep = rt.int(0) -- 0 idle, else 1-based index into the running branch's steps
	C.__vars.deT = rt.timer(0.0)
	C.__vars.deGood = rt.bool(false)
	local WHITE = steps_for("shaderWhiteFX", "fadeToWhiteIFX", 90)
	local BLACK = steps_for("shaderBlackFX", "fadeToBlackIFX", 95)

	function C:OnDeath(killer)
		if self.deStep > 0 then return end -- a run happens once
		self.deGood = self.DA01:GetStageDone(70) == 1
		if self.deGood then
			self.shaderWhiteFX:Play(self, -1.0)
			self.goodSound:Enable()
			self.portalWhiteFX:moveTo(self.marker)
			self.portalWhiteFX:playAnimation("playAnim01")
			self.DA01WhiteFXScene:Start()
		else
			self.shaderBlackFX:Play(self, -1.0)
			self.badSound:Enable()
			self.portalBlackFX:moveTo(self.marker)
			self.portalBlackFX:playAnimation("playAnim01")
			self.DA01BlackFXScene:Start()
		end
		self.deStep = 1
		self.deT = (self.deGood and WHITE or BLACK)[1].wait -- fresh wait: deT idles until death
	end

	function C:OnTick()
		if self.deStep <= 0 or self.deT > 0 then return end
		local steps = self.deGood and WHITE or BLACK
		local s = steps[self.deStep]
		s.fn(self)
		self.deStep = self.deStep + 1
		local nxt = steps[self.deStep]
		if not nxt then
			self.deStep = 0
			return
		end
		self.deT = self.deT + nxt.wait
	end
end
