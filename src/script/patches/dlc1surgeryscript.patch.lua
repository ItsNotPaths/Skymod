-- pex: beginsurgery dbfba956 30f21b54
-- Surgery polled the surgeon's dialogue every 0.5 s, opened the limited race menu, then waited in
-- menu mode until it closed. ShowLimitedRaceMenu yields like Message.Show, so only the dialogue
-- poll is left. As in the original, a player who cannot use the face menu keeps controls disabled.
local rt = require('skymod.rt')

return function(C)
	C.__vars.inSurgery = rt.bool(false)
	C.__vars.dialoguePoll = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.5)
	local function game(fn, ...) return rt.static("Game", fn, ...) end

	local function operate(self)
		if not self:CanUseFaceMenu() then return end
		local player = game("GetPlayer")
		player:RemoveItem(self.Gold001, self.DLC1SurgeryCost:GetValueInt())
		local angle = self.Surgeon:GetHeadingAngle(player)
		if player:GetDistance(self.PlayerMarker) > self.MoveToMarkerDistance or player:GetSitState() > 0 or angle < -90 or angle > 90 then
			player:MoveTo(self.PlayerMarker)
		end
		for _, slot in ipairs({ 30, 31, 42 }) do player:UnequipItemSlot(slot) end -- head, hair, circlet
		self.MenuLight:Enable()
		if not self:CanUseFaceMenu() then return end
		game("AddAchievement", 59)
		game("ShowLimitedRaceMenu") -- HOLE(ui, gap): returns at once; must yield until the menu closes
		game("EnablePlayerControls")
		self.MenuLight:Disable()
	end

	function C:BeginSurgery()
		if self.inSurgery then return end
		game("DisablePlayerControls", true, true, false, false, true, true, true, true, 0)
		self.inSurgery = true
		self.dialoguePoll = 0.0
		self:OnTick()
	end

	function C:OnTick()
		if not self.inSurgery or self.dialoguePoll > 0 then return end
		if self.Surgeon:IsInDialogueWithPlayer() then
			self.dialoguePoll = 0.5
			return
		end
		self.inSurgery = false
		operate(self)
	end
end
