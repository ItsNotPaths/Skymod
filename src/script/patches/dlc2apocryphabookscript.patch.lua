-- pex: waiting.onactivate 11a03644
-- Activating the book went Busy, read it through the controller (which waited for the whole
-- read), then went back to Waiting. Now Busy waits in OnTick until the controller's read is over.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	local function controller(self) return rt.cast(self.DLC2BookDungeonController, "DLC2BookDungeonControllerScript") end

	function Waiting:OnActivate(akActivator)
		if akActivator ~= rt.static("Game", "GetPlayer") then return end
		self:GotoState("Busy")
		controller(self):ReadApocryphaBook(self, self.requireQuestStageToMove, false, false, false)
		self:OnTick()
	end

	function Busy:OnTick()
		local c = controller(self)
		if c.read.name == "Idle" and not c.rewards_book then self:GotoState("Waiting") end
	end
end
