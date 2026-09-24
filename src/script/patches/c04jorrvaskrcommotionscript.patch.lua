-- pex: setup 9abc6779
-- Setup itself has no wait; it is here only because it calls FragmentTracking.AllFragmentsStolen,
-- which sits in the latent closure elsewhere. Nothing after that call in Setup depends on its
-- result, so Setup is a faithful copy: the call is now start-and-return, everything else unchanged.
local rt = require('skymod.rt')

return function(C)
	function C:Setup()
		self.FragmentTracking:AllFragmentsStolen()

		self.MeleeTreeCompanion:ForceRefTo(self.Aela)
		if not self.Torvar:IsDead() then
			self.RangedGateCompanion:ForceRefTo(self.Torvar)
		elseif not self.Athis:IsDead() then
			self.RangedGateCompanion:ForceRefTo(self.Athis)
		end

		self.RangedGateCompanion:GetReference():MoveTo(self.GateSpot)
		self.MeleeTreeCompanion:GetReference():MoveTo(self.TreeSpot)

		if self.Gawker1:GetReference() then self.Gawker1:GetReference():MoveTo(self.Gawker1Spot) end
		if self.Gawker2:GetReference() then self.Gawker2:GetReference():MoveTo(self.Gawker2Spot) end
		if self.Gawker3:GetReference() then self.Gawker3:GetReference():MoveTo(self.Gawker3Spot) end
		if self.Gawker4:GetReference() then self.Gawker4:GetReference():MoveTo(self.Gawker4Spot) end

		self.KodlakHammer:Disable()

		self.Vilkas:GetActorReference():AddItem(self.VilkasHelmet, 1)
		self.Vilkas:GetActorReference():EquipItem(self.VilkasHelmet)
	end
end
