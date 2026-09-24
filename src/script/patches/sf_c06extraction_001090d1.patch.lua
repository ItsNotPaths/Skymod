-- pex: fragment_4 51f04f1f
-- Extract no longer blocks, so the two lines after it now run before extraction finishes rather
-- than after. Both are idempotent facts (a flag write, an EvaluatePackage also done inside
-- Extract's own OnTick), so the reorder changes nothing observable; body is unchanged.
return function(C)
	function C:Fragment_4()
		local wolf = self.WolfSpirit:GetReference()
		wolf:Extract(self.Kodlak:GetActorRef())
		self:GetOwningQuest().WolfSpiritChill = false
		self.WolfSpirit:GetActorRef():EvaluatePackage()
	end
end
