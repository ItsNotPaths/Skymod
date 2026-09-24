-- pex: processingredients 41b5e935
-- ProcessIngredients put each ingredient the player had into the bowl, one after another, each
-- waiting for the bowl's Trigger0N animation. Now OnTick in Busy polls that animation;
-- `placing` is the ingredient going in (1..3), 0 when none.
local rt = require('skymod.rt')

local INGREDIENTS = {
	{ "BoneMealPlaced", "DLC1VQ04IngredBoneMeal" },
	{ "VoidSaltsPlaced", "DLC1VQ04IngredVoidSalt" },
	{ "SoulGemsPlaced", "DLC1VQ04IngredSoulGemShard" },
}

return function(C)
	C.__vars.placing = rt.int(0)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")

	-- the next ingredient after `from` that the player can put in; false when none is left
	local function place_next(self, from)
		local player = rt.static("Game", "GetPlayer")
		for n = from + 1, 3 do
			local placed, item = INGREDIENTS[n - 1][0], INGREDIENTS[n - 1][1]
			if not self[placed] and player:GetItemCount(self[item]) > 0 then
				self[placed] = true
				player:RemoveItem(self[item], 1)
				self.placing = n
				self.DLC1VQ04BloodBowlFurniture:PlayAnimation("Trigger0" .. n)
				return true
			end
		end
		return false
	end

	local function finish(self)
		self.placing = 0
		if self.BoneMealPlaced and self.VoidSaltsPlaced and self.SoulGemsPlaced then
			self.DLC1VQ04:SetStage(self.Stage)
			self:Disable()
		end
		self:GotoState("waiting")
	end

	function C:ProcessIngredients()
		if not place_next(self, 0) then finish(self) end
	end

	function Busy:OnTick()
		local n = self.placing
		if n == 0 or self.DLC1VQ04BloodBowlFurniture:IsAnimRunning("Trigger0" .. n) then return end
		if not place_next(self, n) then finish(self) end
	end
end
