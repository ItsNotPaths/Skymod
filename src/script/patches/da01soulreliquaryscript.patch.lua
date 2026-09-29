-- pex: onactivate c78fd9cd
-- Using the reliquary read the pick from Show at once, then branched on which soul the player
-- held. The event now asks; OnTick reads the answer and runs the matching branch. MyQuest (a cast
-- of DA01, live across the ask) becomes a field.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.MyQuest = rt.form("da01questscript")

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActionRef)
		self.MyQuest = self.DA01
		if self.ReliquaryUsed ~= 0 then return end
		self.asking = true
		self.DA01ReliquaryMessage:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.DA01ReliquaryMessage:Answer()
		if choice < 0 then return self.DA01ReliquaryMessage:Show() end
		self.asking = false
		self.ButtonPressed = choice
		if choice == 1 then
			if player():GetItemCount(self.DA01LightofAzura) == 1 then
				player():RemoveItem(self.DA01LightofAzura, 1, false, rt.None)
				self.DA01LightMessageSuccess:Show()
				self.MyQuest.StarCleansed = 1
				player():MoveTo(self.DA01ReturnFromStar)
				self.AzuraVoice:GetRef():MoveTo(self.Bavyna:GetRef())
				self.DA01:SetObjectiveCompleted(60, true)
				self.ReliquaryUsed = 1
			elseif player():GetItemCount(self.DA01LightofAzura) == 0 then
				self.DA01LightMessageFail:Show()
			end
		elseif choice == 2 then
			if player():GetItemCount(self.DA01MalynsBlackSoul) == 1 then
				self.DA01BlackSoulSuccess:Show()
				self.MyQuest.StarCorrupted = 1
				player():MoveTo(self.DA01ReturnFromStar)
				self.AzuraVoice:GetRef():MoveTo(self.Bavyna:GetRef())
				self.DA01:SetObjectiveCompleted(60, true)
				self.ReliquaryUsed = 1
			elseif player():GetItemCount(self.DA01MalynsBlackSoul) == 0 then
				self.DA01BlackSoulFail:Show()
			end
		end
	end
end
