-- pex: waiting.onactivate 8b6cbb3c
-- Solving the puzzle read the pick from Show at once. The event now asks; OnTick reads the answer
-- and finishes the puzzle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	local Waiting = rt.state(C, "waiting")

	local function player() return rt.static("Game", "GetPlayer") end

	function Waiting:OnActivate(akActionRef)
		if not (akActionRef == player() and self.MQ203:GetStageDone(140) == 1) then return end
		if self.MQ203:GetStageDone(150) ~= 0 then return end
		self.asking = true
		self.PuzzleActivatorMessage:Show()
	end

	function Waiting:OnTick()
		if not self.asking then return end
		local choice = self.PuzzleActivatorMessage:Answer()
		if choice < 0 then return self.PuzzleActivatorMessage:Show() end
		self.asking = false
		if choice ~= 0 then return end
		self:GotoState("Finished")
		self.MQ203:SetStage(150)
	end
end
