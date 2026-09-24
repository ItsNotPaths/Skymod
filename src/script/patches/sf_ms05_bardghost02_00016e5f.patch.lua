-- pex: fragment_0 1a33ad52
-- The bard faded out (0.1 s), then after 0.5 s the mist marker was activated and the quest moved
-- to stage 39. Now OnTick in Fading waits for the ghost's fade, then holds the 0.5 s.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Fading", "Mist")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.step_t = rt.timer(0.0)
	C.__vars.ghost = rt.form("dunDeadMensBardGhostScript")
	C.__vars.TickRate = rt.float(0.05)
	local Fading = rt.state(C, "Fading")

	function C:Fragment_0()
		if self.step ~= S.Idle then return end
		self.ghost = self.Bard:GetActorRef()
		self.ghost:FadeOut()
		self.step = S.Fading
		self:GotoState("Fading")
	end

	function Fading:OnTick()
		if self.step == S.Fading then
			if self.ghost and self.ghost.fading ~= rt.None then return end
			self.step = S.Mist
			self.step_t = 0.5
		end
		if self.step_t > 0 then return end
		self.step = S.Idle
		self:GotoState("")
		self.BardScene02MistMarker:GetReference():Activate(self.Bard:GetReference())
		self:GetOwningQuest():SetStage(39)
	end
end
