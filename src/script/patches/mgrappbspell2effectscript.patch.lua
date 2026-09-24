-- pex: oneffectstart 86e170cc
-- Each cast turned the player (then the cow, horse, dog) into the next creature: a flash, 0.3 s,
-- the swap, 0.2 s, then the quest's Spell2Cast moved on. Now OnTick in Changing does the swap and
-- the count; `form_was` is the Spell2Cast this cast started from.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Flash", "Settle")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.step_t = rt.timer(0.0)
	C.__vars.form_was = rt.int(-1)
	C.__vars.TickRate = rt.float(0.05)
	local Changing = rt.state(C, "Changing")

	local function quest(self) return rt.cast(self.MGRAppBrelyna01, "MGRAppBrelyna01QuestScript") end
	local function player() return rt.static("Game", "GetPlayer") end

	-- the creature on screen now: the player at 0, else Creature1..3
	local function current(self, n) return n == 0 and player() or self["Creature" .. n]:GetReference() end

	function C:OnEffectStart(akTarget, akCaster)
		if self.step ~= S.Idle then return end
		local q = quest(self)
		local n = q.Spell2Cast
		if n < 0 or n > 3 then return end
		if n == 0 then q.SavedRace = player():GetRace() end
		current(self, n):PlaceAtMe(self.SummonTargetFXActivator, 1)
		self.form_was = n
		self.step = S.Flash
		self.step_t = 0.3
		self:GotoState("Changing")
	end

	local next_creature = { "EncCow", "EncHorseBrown", "EncDog" } -- 0-based: cow at 0

	function Changing:OnTick()
		if self.step_t > 0 then return end
		local n = self.form_was
		if self.step == S.Flash then
			if n == 0 then
				player():SetAlpha(0)
			else
				current(self, n):Disable()
			end
			if n < 3 then
				self["Creature" .. (n + 1)]:ForceRefTo(current(self, n):PlaceAtMe(self[next_creature[n]], 1))
			else
				player():MoveTo(current(self, 3))
				player():SetAlpha(1)
			end
			self.step = S.Settle
			self.step_t = self.step_t + 0.2
		else
			self.step = S.Idle
			quest(self).Spell2Cast = n < 3 and n + 1 or -1
			self:GotoState("")
		end
	end
end
