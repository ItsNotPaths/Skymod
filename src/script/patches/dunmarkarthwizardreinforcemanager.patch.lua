-- pex: initial.onactivate d63e3428
-- The manager spawned reinforcement 1 and waited in its EVPReinforcement loop (until it entered
-- combat or unloaded) before spawning reinforcement 2. EVPReinforcement now returns at once and
-- publishes runEVPLoop; `first` is reinforcement 1, and OnTick in AllDone spawns reinforcement 2
-- once its loop has ended.
local rt = require('skymod.rt')

return function(C)
	C.__vars.first = rt.form("dunMarkarthWizard_EVPReinforcements")
	C.__vars.TickRate = rt.float(0.5)
	local Initial, AllDone = rt.state(C, "Initial"), rt.state(C, "AllDone")

	local function spawn(self, point, base, slot)
		local a = point:PlaceActorAtMe(base, self.ReinforcementLevelMod, self.ReinforcementEncZone)
		a:AddToFaction(self.SecureAreaFaction)
		slot:ForceRefTo(a)
		rt.cast(a, "dunMarkarthWizard_EVPReinforcements"):EVPReinforcement()
		a:EvaluatePackage()
		return a
	end

	function Initial:OnActivate(akactivator)
		self:GotoState("AllDone")
		self.CallerForHelpMarker:MoveTo(akactivator)
		if self.ReinforcementsEnabledMarker:IsDisabled() then return end
		self.ReinforcementsEnabledMarker:Disable()
		if self.SpawnPoint1 then
			self.first = spawn(self, self.SpawnPoint1, self.ReinforcementType1, self.ReinforcementSlot1)
		end
		self:OnTick()
	end

	function AllDone:OnTick()
		if self.first and self.first.runEVPLoop then return end
		self.first = rt.None
		if self.SpawnPoint2 and self.ReinforcementSlot2:GetReference() == rt.None then
			spawn(self, self.SpawnPoint2, self.ReinforcementType2, self.ReinforcementSlot2)
		end
		self:GotoState("Done")
	end
end
