-- pex: updateloop 32fb7cb7
-- UpdateLoop polled every 2 s while the quest was below myStage: if the player was within
-- distanceCheck, stop ScenetoEnd and start ScenetoStart 0.1 s later. States are the loop's steps.
-- OnLoad is unchanged (already guards with GetStageDone before calling UpdateLoop). OnUnload gets
-- one added line, GotoState(""), so the new polling state actually stops on unload; breakloop
-- alone no longer does, since nothing rereads it as a loop condition.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", "werj07 " .. tostring(self.form) .. ": " .. msg) end

return function(C)
	C.__vars.nextCheck = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:OnUnload()
		self.breakloop = true
		if self:GetState() == "Switching" then -- Papyrus always started the scene before honouring breakLoop
			self.ScenetoStart:Start()
			trace(self, "unloaded mid-switch, ScenetoStart started")
		end
		self:GotoState("")
		trace(self, "unloaded, loop stops")
	end

	function C:UpdateLoop()
		if (self:GetState() or "") ~= "" then return end -- a loop already runs; GetState() is None before any GotoState
		self.nextCheck = 0.0
		self:GotoState("Polling")
		trace(self, "loop starts")
		self:OnTick()
	end

	local Polling = rt.state(C, "Polling")
	function Polling:OnTick()
		if self.nextCheck > 0 then return end
		if self.myQuest:GetStage() >= self.myStage then
			self:GotoState("")
			trace(self, "stage reached, loop ends")
			return
		end
		local d = self:GetReference():GetDistance(rt.static("Game", "GetPlayer"))
		if d <= self.distanceCheck then
			self.nextCheck = self.nextCheck + 0.1
			self:GotoState("Switching")
			self.ScenetoEnd:Stop()
			trace(self, "near (" .. tostring(d) .. "), ScenetoEnd stopped")
		else
			self.nextCheck = self.nextCheck + 2.0
			trace(self, "far (" .. tostring(d) .. ")")
		end
	end

	local Switching = rt.state(C, "Switching")
	function Switching:OnTick()
		if self.nextCheck > 0 then return end
		self.nextCheck = self.nextCheck + 2.0
		self:GotoState("Polling")
		self.ScenetoStart:Start()
		trace(self, "ScenetoStart started")
	end
end
