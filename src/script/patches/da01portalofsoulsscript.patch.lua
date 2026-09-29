-- pex: waitingforplayer.onactivate 82fa353f
-- Which of two messages fired (holding Malyn's black soul, or not) read its pick at once. The
-- event now asks the right one; OnTick in "waitingForPlayer" reads whichever answer is pending.
local rt = require('skymod.rt')

return function(C)
	C.__vars.askingBlack = rt.bool(false)
	C.__vars.askingNormal = rt.bool(false)
	local WaitingForPlayer = rt.state(C, "waitingForPlayer")

	local function player() return rt.static("Game", "GetPlayer") end

	function WaitingForPlayer:OnActivate(triggerRef)
		if triggerRef ~= player() then return end
		if player():GetItemCount(self.DA01MalynsBlackSoul) >= 1 then
			self.askingBlack = true
			self.DA01PortalofSoulsBlackMessage:Show()
		elseif player():GetItemCount(self.DA01MalynsBlackSoul) == 0 then
			self.askingNormal = true
			self.DA01PortalofSoulsMessage:Show()
		end
	end

	function WaitingForPlayer:OnTick()
		if self.askingBlack then
			local choice = self.DA01PortalofSoulsBlackMessage:Answer()
			if choice < 0 then return self.DA01PortalofSoulsBlackMessage:Show() end
			self.askingBlack = false
			self.ButtonPressed = choice
			if choice == 0 then
				self.DA01:SetStage(70)
				self:GotoState("hasBeenTriggered")
			elseif choice == 1 then
				self.DA01:SetStage(75)
				self:GotoState("hasBeenTriggered")
			end
		elseif self.askingNormal then
			local choice = self.DA01PortalofSoulsMessage:Answer()
			if choice < 0 then return self.DA01PortalofSoulsMessage:Show() end
			self.askingNormal = false
			self.ButtonPressed = choice
			if choice == 0 then
				self.DA01:SetStage(70)
				self:GotoState("hasBeenTriggered")
			end
		end
	end
end
