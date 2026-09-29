-- pex: promptplayerrepair 4fd9d8d6
-- pex: promptplayersabotage 107eb533
-- pex: trytosabotage f67af573
-- PromptPlayerRepair/PromptPlayerSabotage showed a message and returned button==1; TryToSabotage
-- was their only caller and read that return to gate repair() or readyforsabotage. Now
-- TryToSabotage starts the ask itself (no other caller for the two Prompt functions, so their
-- logic moves in); OnTick reads the answer and does what TryToSabotage used to do next.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.ask_kind = rt.string("") -- "repair" | "sabotage"

	local function player() return rt.static("Game", "GetPlayer") end

	function C:TryToSabotage(triggerRef)
		if self.sabotaged then
			if triggerRef ~= player() then return end
			self.ask_kind = "repair"
			self.asking = true
			return self.RepairMessage:Show()
		end
		if self.readyForSabotage then
			if triggerRef == player() then self.SabotageReadyMessage:Show() end
			return
		end
		if triggerRef ~= player() then
			self.readyForSabotage = true
			return
		end
		self.ask_kind = "sabotage"
		self.asking = true
		self.SabotageMessage:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local msg = self.ask_kind == "repair" and self.RepairMessage or self.SabotageMessage
		local choice = msg:Answer()
		if choice < 0 then return msg:Show() end
		self.asking = false
		if choice ~= 1 then return end
		if self.ask_kind == "repair" then
			self:ChangeState(self.busy)
			self:repair()
			self:ChangeState(self.waiting)
		else
			self.readyForSabotage = true
		end
	end
end
