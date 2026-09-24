-- pex: beginjyrikbattle bc804f6b
-- pex: teleport 810d7517
-- BeginJyrikBattle only tail-calls Teleport then two independent effects (SetAV, OnUpdate); it
-- needs no change now that Teleport returns at once. Teleport's banish/move/summon beats become a
-- stage plus one timer, same shape as dunReachwaterRockSigdisBossBattle.Duplicate but one actor
-- and six positions. The class already ticks (EndJyrikBattle's own wait, from the S6 split); this
-- patch's OnTick calls that first.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick

	C.TeleStage = rt.sequence("Idle", "Disable", "Move", "Finish")
	C.__vars.teleStage = C.TeleStage.Idle
	C.__vars.teleT = rt.timer(0.0)
	local S = C.TeleStage

	local function swap(self, a, b, near)
		local x, y = self[a], self[b]
		if x:GetDistance(near) < y:GetDistance(near) then self[a], self[b] = y, x end
	end

	local steps = {}
	steps[S.Disable] = function(self)
		self:GetActorRef():Disable(false)
		self.teleT = self.teleT + 2.0
		return S.Move
	end
	steps[S.Move] = function(self)
		local actor = self:GetActorRef()
		local player = rt.static("Game", "GetPlayer")
		swap(self, "Position1", "Position6", player)
		swap(self, "Position2", "Position6", player)
		swap(self, "Position3", "Position6", player)
		swap(self, "Position4", "Position6", player)
		swap(self, "Position5", "Position6", player)
		swap(self, "Position1", "Position5", actor)
		swap(self, "Position2", "Position5", actor)
		swap(self, "Position3", "Position5", actor)
		swap(self, "Position4", "Position5", actor)
		local spot = rt.static("Utility", "RandomInt", 1, 4)
		if spot == 1 then actor:MoveTo(self.Position1)
		elseif spot == 2 then actor:MoveTo(self.Position2)
		elseif spot == 3 then actor:MoveTo(self.Position3)
		else actor:MoveTo(self.Position4) end
		actor:PlaceAtMe(self.SummonFX)
		self.teleT = self.teleT + 1.0
		return S.Finish
	end
	steps[S.Finish] = function(self)
		local actor = self:GetActorRef()
		actor:SetAV("Variable06", 0.0)
		actor:Enable(true)
		actor:SetGhost(false)
		actor:SetAlpha(0.5, true)
		actor:EvaluatePackage()
		actor:StartCombat(rt.static("Game", "GetPlayer"))
		self.teleportongoing = false
		return S.Idle
	end

	function C:Teleport()
		if self.teleportongoing then return end -- lock the function
		if not self.battleactive then return end -- Papyrus locks and unlocks with nothing in between
		self.teleportongoing = true
		local actor = self:GetActorRef()
		actor:SetAV("Variable06", 1.0)
		actor:EvaluatePackage()
		actor:SetGhost(true)
		actor:PlaceAtMe(self.BanishFX)
		self.teleStage = S.Disable
		self.teleT = 0.1
	end

	function C:OnTick()
		split_tick(self)
		while self.teleStage ~= S.Idle and self.teleT <= 0 do
			self.teleStage = steps[self.teleStage](self)
		end
	end
end
