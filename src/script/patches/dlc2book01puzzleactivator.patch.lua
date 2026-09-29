-- pex: waiting.onactivate 51c1112f
-- Placing or removing a book read the pick from whichever message matched BookNumberPlaced, right
-- after Show. The event now asks; OnTick in "busy" (the state OnActivate already switches to)
-- reads the answer and runs the same tail: give/take the book, tell MyController, and return to
-- "Waiting".
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")

	local function player() return rt.static("Game", "GetPlayer") end

	local function message(self)
		local n = self.BookNumberPlaced
		if n == 0 then return self.DLC2Book01PuzzleActivatorEmptyMessage end
		if n == 1 then return self.DLC2Book01PuzzleActivatorBook1Message end
		if n == 2 then return self.DLC2Book01PuzzleActivatorBook2Message end
		if n == 3 then return self.DLC2Book01PuzzleActivatorBook3Message end
		if n == 4 then return self.DLC2Book01PuzzleActivatorBook4Message end
	end

	function Waiting:OnActivate(akActivator)
		if self.QuestScript == rt.None then self.QuestScript = self.DLC2Book01PuzzleQst end
		if akActivator ~= player() then return end
		self:GotoState("busy")
		self.asking = true
		message(self):Show()
	end

	function Busy:OnTick()
		if not self.asking then return end
		local msg = message(self)
		local choice = msg:Answer()
		if choice < 0 then return msg:Show() end
		self.asking = false
		if self.BookNumberPlaced == 0 then
			self.BookNumberPlaced = choice
		elseif choice == 1 then
			self.QuestScript:GiveBookToPlayer(self.BookNumberPlaced)
			self.BookNumberPlaced = 0
		end
		if self.BookNumberPlaced ~= 0 then
			self:GetLinkedRef():Enable(false)
			self.QuestScript:TakeBookFromPlayer(self.BookNumberPlaced)
		end
		if self.BookNumberPlaced == self.CorrectBookNumber then
			self.MyController:BookPlaced(self.CorrectBookNumber)
		elseif self.BookNumberPlaced == 0 then
			self.MyController:BookRemoved(self.CorrectBookNumber)
			self:GetLinkedRef():Disable(false)
		end
		self:GotoState("Waiting")
	end
end
