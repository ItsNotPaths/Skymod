-- pex: busy.onactivate d75d2680
-- pex: waitingtobeactivated.onactivate 7ba667b7
-- OnActivate has two runs that Papyrus let overlap on one block:
-- cycle  (any activator, from WaitingToBeActivated): appear, activate the next block, hide or stay,
--        then allow activation again. Its waits are the block's Time* properties.
-- reveal (defaultActivateSelf, from WaitingToBeActivated or Busy): the goal was reached; after a
--        wait computed from the player's distance, stay visible and clear the navcuts.
-- The reveal moves the block to Done while a cycle may still run, and the cycle's end then moves it
-- back to Busy, so OnTick is in both Busy and Done.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", tostring(self.form) .. " floor: " .. msg) end

local Cycle = rt.sequence("Idle", "Enabled", "Appeared", "Linked", "Shown", "Reappeared", "Reset")
local Reveal = rt.sequence("Idle", "Waiting", "Enabled", "Done")

local function appear_sound(self) self.FloorAppearSound:Play(self.form) end

-- the cycle's steps: the wait before each, what it does
local cycle_steps = {
	Appeared = { function() return 0.1 end, appear_sound },
	Linked = { function(self) return self.TimeToActivateNextBlock end, function(self)
		local next = self:GetLinkedRef()
		if next then next:Activate(self.form) end
	end },
	Shown = { function(self) return self.TimeToDisableSelf end, function(self)
		if self.bStayVisible then
			self:EnableNoWait(true)
		else
			self.FloorHideSound:Play(self.form)
			self:DisableNoWait(true)
		end
	end },
	Reappeared = { function(self) return self.bStayVisible and 0.1 or 0.0 end, function(self)
		if self.bStayVisible then appear_sound(self) end
	end },
	Reset = { function(self) return self.TimeToResetActivation end, function(self)
		self:GoToState(self.bStayVisible and "Busy" or "WaitingToBeActivated")
	end },
}

local function player_delay(self) return rt.static("Game", "GetPlayer"):GetDistance(self.form) * 0.001 + 0.5 end

local function start_reveal(self)
	self:GoToState("Done")
	self.bStayVisible = true
	self.revealWait = player_delay(self)
	self.reveal = Reveal.Waiting
	trace(self, string.format("reveal in %.3f s", self.revealWait))
end

local function start_cycle(self)
	self:GoToState("Busy")
	local next = self:GetLinkedRef()
	if next then
		local s = rt.cast(next, "dlc2dunfloorpathpuzzlescript")
		s.TimeToActivateNextBlock = self.TimeToActivateNextBlock
		s.TimeToDisableSelf = self.TimeToDisableSelf
		s.TimeToResetActivation = self.TimeToResetActivation
	end
	self:EnableNoWait(false)
	self.cycle = Cycle.Enabled
	self.cycleClock = 0.0
	trace(self, "cycle: enabled")
end

local function tick_cycle(self)
	while self.cycle > Cycle.Idle and self.cycle < Cycle.Reset do
		local next = self.cycle + 1
		local step = cycle_steps[next.name]
		local wait = step[0](self)
		if self.cycleClock < wait then return end
		self.cycleClock = self.cycleClock - wait
		self.cycle = next
		step[1](self)
		trace(self, "cycle: " .. next.name)
	end
	if self.cycle == Cycle.Reset then self.cycle = Cycle.Idle end
end

local function tick_reveal(self)
	if self.reveal == Reveal.Waiting and self.revealWait <= 0 then
		rt.static("Debug", "Trace", "Waited " .. rt.cast(player_delay(self), "string") .. " seconds to enable " .. tostring(self.form))
		self:EnableNoWait(true)
		self.reveal = Reveal.Enabled
		self.revealWait = self.revealWait + 0.1
		trace(self, "reveal: enabled")
	end
	if self.reveal == Reveal.Enabled and self.revealWait <= 0 then
		appear_sound(self)
		for _, k in ipairs({ self.LinkCustom01, self.LinkCustom02, self.LinkCustom03 }) do
			local r = self:GetLinkedRef(k)
			if r then r:DisableNoWait() end
		end
		self.reveal = Reveal.Done
		trace(self, "reveal: navcuts off")
	end
end

return function(C)
	C.__vars.cycle = Cycle.Idle
	C.__vars.cycleClock = rt.stopwatch(0.0)
	C.__vars.reveal = Reveal.Idle
	C.__vars.revealWait = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	local Waiting = rt.state(C, "WaitingToBeActivated")
	function Waiting:OnActivate(akActionRef)
		if rt.cast(akActionRef, "defaultactivateself") then start_reveal(self) else start_cycle(self) end
	end

	local Busy = rt.state(C, "Busy")
	function Busy:OnActivate(akActionRef)
		if rt.cast(akActionRef, "defaultactivateself") then start_reveal(self) end
	end

	local function on_tick(self)
		tick_cycle(self)
		tick_reveal(self)
	end
	Busy.OnTick = on_tick
	rt.state(C, "Done").OnTick = on_tick
end
