-- pex: onitemadded 6a48e491
-- A planter keeps one plantable item and hands the rest back, with a message each time, then sets
-- the planted flora once per container session. WaitMenuMode(0) before each message is gone: the
-- handler runs after the container menu has closed (script-api.md section 7). The Wait(0) that let
-- the session's items all land becomes the Processing state, whose OnTick runs next tick.
local rt = require('skymod.rt')

return function(C)
	local Processing = rt.state(C, "Processing")

	function Processing:OnTick()
		self:GotoState("")
		self:SetPlantedItem()
	end

	local function index_in(list, item)
		for i = 0, list:GetSize() - 1 do
			if item == list:GetAt(i) then return i end
		end
	end

	function C:OnItemAdded(akBaseItem, aiItemCount, akItemReference, akSourceContainer)
		local player = rt.static("Game", "GetPlayer")
		local plantable = (rt.cast(akBaseItem, "Potion") or rt.cast(akBaseItem, "Ingredient"))
			and self.flPlanterPlantableItem:HasForm(akBaseItem)
		if plantable then
			self.plantedItemIndex = index_in(self.flPlanterPlantableItem, akBaseItem) or self.plantedItemIndex
			local previous = self.plantedItem
			if previous then self:RemoveItem(previous, 1, true, player) end
			self.plantedItem = akBaseItem
			self.plantedItemRef = akItemReference
			if previous then self.PlanterPreviousItemRemovedMESSAGE:Show() end
			if aiItemCount > 1 then
				self:RemoveItem(akBaseItem, aiItemCount - 1, true, player)
				self.PlanterOnlyOneItemMESSAGE:Show()
			else
				self.PlanterItemPlantedMESSAGE:Show()
			end
		else
			self:RemoveItem(akBaseItem, aiItemCount, true, player)
			self.PlanterNotPlantableMESSAGE:Show()
		end
		if not self.containerProccessed then
			self.containerProccessed = true
			self:GotoState("Processing")
		end
	end
end
