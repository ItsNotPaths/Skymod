-- pex: fragment_4 e6f08d6d
-- The finale faded the bard out (0.1 s) and then turned off the mist and the beam. Now OnTick in
-- Fading waits for the ghost's fade before the two activations.
local rt = require('skymod.rt')

return function(C)
	C.__vars.ghost = rt.form("dunDeadMensBardGhostScript")
	C.__vars.TickRate = rt.float(0.05)
	local Fading = rt.state(C, "Fading")

	function C:Fragment_4()
		if self:GetState() == "Fading" then return end
		self.ghost = self.Bard:GetActorRef()
		self.ghost:FadeOut()
		self:GotoState("Fading")
	end

	function Fading:OnTick()
		if self.ghost and self.ghost.fading ~= rt.None then return end
		self:GotoState("")
		local player = rt.static("Game", "GetPlayer")
		self.BardScene10MistOffMarker:GetReference():Activate(player)
		self.BardScene10BeamOffMarker:GetReference():Activate(player)
	end
end
