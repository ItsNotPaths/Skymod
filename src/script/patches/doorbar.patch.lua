-- pex: down.onactivate 1d026491
-- pex: up.onactivate 72136a2d
-- pex: down.setbarposition 0ad46c01
-- pex: up.setbarposition f209f075
-- The bar played its move and waited for "done" in busy. Now the event ends the move; `moving` is
-- the state it ends in. SetBarPosition(false) in up waited 0.5 s and called itself again until
-- the door was closed; now `lowerWanted` is that request and OnTick in up retries it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.moving = rt.string("")
	C.__vars.lowerWanted = rt.bool(false)
	C.__vars.retry = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Down, Up, Busy = rt.state(C, "down"), rt.state(C, "up"), rt.state(C, "busy")

	local function move(self, to)
		self.lowerWanted = false
		self.doorScript.busy = true
		self:GotoState("busy")
		if to == "up" then self.myNavCutLink:Disable() else self.myNavCutLink:Enable() end
		self.moving = to
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation(to)
	end

	function Down:OnActivate(actronaut) move(self, "up") end

	function Up:OnActivate(actronaut)
		if self.myLink:GetOpenState() ~= 3 then return end -- can't drop a bar while the door is open
		move(self, "down")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" or self.moving == "" then return end
		local barred = self.moving == "down"
		self.doorScript.barred = barred
		self.myLink:BlockActivation(barred)
		self:GotoState(self.moving)
		self.moving = ""
		self.doorScript.busy = false
	end

	function Down:SetBarPosition(setBarUp)
		if setBarUp then self:OnActivate(self) end
	end

	function Up:SetBarPosition(setBarUp)
		if setBarUp then return end
		self.lowerWanted = true
		self.retry = 0.0
		self:OnTick()
	end

	function Up:OnTick()
		if not self.lowerWanted or self.retry > 0 then return end
		local open = self.myLink:GetOpenState()
		if open == 1 then
			self.myLink:Activate(self)
			self.retry = 0.5
		elseif open == 2 or open == 4 then
			self.retry = 0.5
		else
			self:OnActivate(self)
		end
	end
end
