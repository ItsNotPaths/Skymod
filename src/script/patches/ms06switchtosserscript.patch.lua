-- pex: ready.ontriggerenter 18404e4a
-- OnTriggerEnter moved to state "done" at once (its own re-entry guard: "done" defines no
-- OnTriggerEnter), polled 1s for the player's 3D, waited 2s, then threw the switches at 0, 4 and
-- 4s. A stage plus one timer now walks the same steps in OnTick.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", msg) end

return function(C)
	C.Toss = rt.sequence("AwaitPlayer", "Settle", "First", "Second", "Third")
	C.__vars.toss = C.Toss.AwaitPlayer
	C.__vars.tossT = rt.timer(0.0)
	C.__vars.tossCount = rt.int(0)
	C.__vars.TickRate = rt.float(1.0)
	local S = C.Toss

	local Ready = rt.state(C, "ready")
	function Ready:OnTriggerEnter(triggerREF)
		self:GotoState("done")
		self.toss = S.AwaitPlayer
		self.tossCount = 0
		self:OnTick() -- Papyrus checked the player's 3D at once
	end

	function C:OnTick()
		if self.toss == S.AwaitPlayer then
			if not rt.static("Game", "GetPlayer"):Is3DLoaded() then
				self.tossCount = self.tossCount + 1
				trace("MS06: Recursion " .. self.tossCount .. " of Switches waiting for player 3D to load")
				return
			end
			self.toss = S.Settle
			self.tossT = 2.0
			return
		end
		if self.tossT > 0 then return end
		local player = rt.static("Game", "GetPlayer")
		if self.toss == S.Settle then
			self.toss = S.First
			self.tossT = 4.0
			trace("MS06: 1) Throw Switch #1, #2")
			self.switch1:Activate(player)
			self.switch2:Activate(player)
		elseif self.toss == S.First then
			self.toss = S.Second
			self.tossT = 4.0
			trace("MS06: 2) Throw Switch #2")
			self.switch2:Activate(player)
		elseif self.toss == S.Second then
			self.toss = S.Third
			trace("MS06: 2) Throw Switch #2,#3")
			self.switch2:Activate(player)
			self.switch3:Activate(player)
		end
	end
end
