-- pex: waiting.onactivate 3da07c05
-- Placing or taking the pitcher played its animation and waited for "done", shook the room, then
-- played the linked door's Open or Close and waited for it. Now the pitcher's event starts the
-- door and OnTick in busy waits for the door's animation; `inserting` says which way.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Pitcher", "Door")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.inserting = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")

	local function start(self, inserting, anim)
		self.inserting = inserting
		self.step = S.Pitcher
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation(anim)
	end

	function Waiting:OnActivate(akActionRef)
		local player = rt.static("Game", "GetPlayer")
		if akActionRef ~= player then return end
		self:GotoState("busy")
		self.myLink = self:GetLinkedRef()
		if self.bInserted then
			player:AddItem(self.pitcher)
			return start(self, false, "Take")
		end
		if player:GetItemCount(self.pitcher) < 1 then
			self.myMessage:Show()
			return self:GotoState("waiting")
		end
		player:RemoveItem(self.pitcher)
		start(self, true, "Place")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if self.step ~= S.Pitcher or akSource ~= self or asEventName ~= "done" then return end
		self.bInserted = self.inserting
		self.myDust:Activate(self)
		rt.static("Game", "ShakeCamera", self, 0.3, 2)
		rt.static("Game", "ShakeController", 0.7, 0.7, 2)
		self.myLink:PlayAnimation(self.inserting and "Open" or "Close")
		self.step = S.Door
	end

	function Busy:OnTick()
		if self.step ~= S.Door or self.myLink:IsAnimRunning(self.inserting and "Open" or "Close") then return end
		self.step = S.Idle
		self:GotoState("waiting")
	end
end
