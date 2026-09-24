-- pex: createashpile 86c931b9
-- pex: ondying 0864a58e
-- pex: onload b013cabf
-- createAshPile stays a real function (a mod can call it): it checks immunity, kills the victim,
-- attaches the ash pile, and waits fDelayEnd before finishing. OnLoad waited 10 s then called it;
-- OnDying called it at once. Both then waited 1 s and disabled. `life` tracks that outer wait,
-- keyed off `ash` reaching Done, whichever caller started it.
local rt = require('skymod.rt')

local Ash = rt.sequence("Idle", "Burning", "Done")
local Life = rt.sequence("Idle", "Lingering", "AwaitingAsh", "Ending", "Finished")

local function trace(self, msg) rt.static("Debug", "Trace", tostring(self.form) .. " shade: " .. msg) end

return function(C)
	C.__vars.ash = Ash.Idle
	C.__vars.ashT = rt.timer(0.0)
	C.__vars.life = Life.Idle
	C.__vars.lifeT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:createAshPile()
		if self.ash ~= Ash.Idle then return end -- a run happens once
		local list = self.pdisintegrationmainimmunitylist
		local immune
		if not list then
			immune = false
		else
			local base = rt.cast(self.victim:GetBaseObject(), "actorbase")
			self.victimrace = base:GetRace()
			immune = list:HasForm(self.victimrace) or list:HasForm(base)
		end
		self.targetisimmune = immune
		if immune then
			self.ash = Ash.Done
			return
		end
		local victim = self.victim
		victim:Kill(rt.static("Game", "GetPlayer"))
		victim:SetCriticalStage(victim.CritStage_DisintegrateStart)
		if self.pghostdeathfxshader then self.pghostdeathfxshader:Play(victim, self.shaderduration) end
		victim:SetAlpha(0.0, true)
		victim:AttachAshPile(self.pdefaultashpileghost)
		self.ash, self.ashT = Ash.Burning, self.fdelayend
	end

	local function start_life(self)
		self.life, self.lifeT = Life.AwaitingAsh, 0.0
		self:createAshPile()
	end

	function C:OnLoad()
		self.victim = self.form
		if self.life ~= Life.Idle then return end -- a run happens once
		if not self:IsDead() or self.deathvar == false then
			self.life, self.lifeT = Life.Lingering, 10.0
			trace(self, "loaded, lingering 10 s")
		end
	end

	function C:OnDying(akKiller)
		self.deathvar = false
		if self.life >= Life.AwaitingAsh then return end -- already running
		trace(self, "dying")
		start_life(self)
	end

	function C:OnTick()
		if self.ash == Ash.Burning and self.ashT <= 0 then
			local victim = self.victim
			if self.pghostdeathfxshader then self.pghostdeathfxshader:Stop(victim) end
			if self.bsetalphazero then victim:SetAlpha(0.0, true) end
			victim:SetCriticalStage(victim.CritStage_DisintegrateEnd)
			self.ash = Ash.Done
		end
		if self.life == Life.Idle or self.life == Life.Finished then return end
		if self.life == Life.Lingering then
			if self.lifeT > 0 then return end
			start_life(self)
		elseif self.life == Life.AwaitingAsh then
			if self.ash ~= Ash.Done then return end
			self.life, self.lifeT = Life.Ending, 1.0
		elseif self.life == Life.Ending then
			if self.lifeT > 0 then return end
			self.life = Life.Finished
			self:Disable()
			trace(self, "disabled")
		end
	end
end
