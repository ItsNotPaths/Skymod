-- pex: fragment_87 048ac3cd
-- Fragment_87 played the altar's Down anim, then looped unequip+wait(1) until the rusty mace was
-- off, swapped in the mace of Molag Bal, waited 1 more, then had Molag Bal speak. Now two stages
-- of one timer on OnTick; the class already ticks (S6 split), so this calls that first.
local rt = require('skymod.rt')

return function(C)
	local orig_tick = C.__fn.ontick
	C.Frag87 = rt.sequence("Idle", "Unequip", "Waiting", "Done")
	C.__vars.frag87stage = C.Frag87.Idle
	C.__vars.frag87t = rt.timer(0.0)
	local S = C.Frag87

	function C:Fragment_87()
		if self.frag87stage ~= S.Idle then return end -- a second start is dropped
		self:SetObjectiveCompleted(60, true)
		self:SetObjectiveDisplayed(70, true, false)
		self.alias_altar:GetRef():PlayAnimation("Down")
		self.frag87stage = S.Unequip
		self.frag87t = 0.0
		self:OnTick() -- Papyrus checked at once
	end

	function C:OnTick()
		orig_tick(self)
		if self.frag87stage == S.Unequip then
			if self.frag87t > 0 then return end
			local player = rt.static("Game", "GetPlayer")
			if player:GetEquippedWeapon(false) == self.da10rustymace then
				player:UnequipItem(self.da10rustymace, true, true)
				self.frag87t = 1.0
				return
			end
			player:RemoveItem(self.da10rustymace, 1, false, rt.None)
			player:AddItem(self.da10maceofmolagbal, 1, false)
			player:EquipItem(self.da10maceofmolagbal, false, false)
			self.achievementsquest:IncDaedricArtifacts()
			self.frag87stage = S.Waiting
			self.frag87t = 1.0
			return
		end
		if self.frag87stage == S.Waiting then
			if self.frag87t > 0 then return end
			local player = rt.static("Game", "GetPlayer")
			self.alias_molagbalfinaltalking:GetRef():Activate(player, false)
			self.frag87stage = S.Done
		end
	end
end
