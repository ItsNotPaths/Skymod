-- pex: ready.onactivate 3c0f8bba
-- Ready.OnActivate checked the ingredients, went to Done, waited 2 s if the player's weapon was
-- drawn, then removed the crest, played the animation, waited 1 s, and played the forge sound.
-- Now a stage sequence in Done's OnTick carries the two waits.
local rt = require('skymod.rt')

local Craft = rt.sequence("Idle", "WeaponWait", "Playing")

return function(C)
	C.__vars.craft = Craft.Idle
	C.__vars.craftT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local Ready = rt.state(C, "ready")
	function Ready:OnActivate(akActivator)
		local player = rt.static("Game", "GetPlayer")
		if akActivator ~= player then return end
		local dwarven = player:GetItemCount(self.ingotdwarven)
		local eligible = player:GetItemCount(self.dlc1ld_aetheriumcrest) > 0 and (
			(player:GetItemCount(self.ingotmalachite) >= 2 and dwarven >= 4) or
			(player:GetItemCount(self.ingotgold) >= 1 and dwarven >= 2 and player:GetItemCount(self.ingotebony) >= 2) or
			(player:GetItemCount(self.gemsapphireflawless) >= 2 and dwarven >= 2 and player:GetItemCount(self.ingotgold) >= 2))
		if not eligible then return end
		self:GotoState("done")
		self.craft = Craft.WeaponWait
		self.craftT = player:IsWeaponDrawn() and 2.0 or 0.0
	end

	local Done = rt.state(C, "done")
	function Done:OnTick()
		if self.craft == Craft.Idle or self.craftT > 0 then return end
		if self.craft == Craft.WeaponWait then
			local player = rt.static("Game", "GetPlayer")
			player:RemoveItem(self.dlc1ld_aetheriumcrest, 1, false)
			self.aetheriumforgeobject:PlayAnimation("crest01")
			self.craft, self.craftT = Craft.Playing, 1.0
			return
		end
		self.objdwemergearforge:Play(self.aetheriumforgeobject)
		self.craft = Craft.Idle
	end
end
