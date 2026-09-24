-- pex: solvemaze 25297b80
-- solveMaze: open the portal, place the dremora, wait for the player to arrive and for the
-- dremora to be hurt, swap both out with summon FX, call in two atronachs, then wait for the
-- dremora's death. A named stage plus one timer walks the steps in OnTick; a step that sets no
-- wait lets the next one run in the same tick, as Papyrus runs on without a Wait.
local rt = require('skymod.rt')

local S = rt.sequence("Idle", "PortalOn", "AwaitPlayer", "AwaitHurt", "DremoraOut", "PlayerOut",
	"Reinforce", "Atronach1", "Atronach2", "AwaitDeath", "Done")

local steps = {}

steps[S.PortalOn] = function(self)
	self.myPortal:PlayAnimation("playAnim02")
	self.dremora = self.dremoraPoint:PlaceAtMe(self.lvlDremoraMelee)
	self.dremora:AddItem(self.dunLabyrinthianMazeCircletReward, 1)
	self.dremora:EquipItem(self.dunLabyrinthianMazeCircletReward, true)
	return S.AwaitPlayer
end

steps[S.AwaitPlayer] = function(self)
	if rt.static("Game", "GetPlayer"):GetDistance(self.summonPoint) > 256 then
		self.solveT = 2.0
		return nil
	end
	return S.AwaitHurt
end

steps[S.AwaitHurt] = function(self)
	if self.dremora:GetActorValuePercentage("Health") > 0.75 then
		self.solveT = 1.0
		return nil
	end
	self.myPortal:Disable()
	self.dremora:PlaceAtMe(self.summonTargetFXActivator)
	self.solveT = 0.33
	return S.DremoraOut
end

steps[S.DremoraOut] = function(self)
	self.dremora:MoveTo(self.reappearDremoraPoint)
	rt.static("Game", "GetPlayer"):PlaceAtMe(self.summonTargetFXActivator)
	self.solveT = 0.33
	return S.PlayerOut
end

steps[S.PlayerOut] = function(self)
	rt.static("Game", "GetPlayer"):MoveTo(self.reappearPlayerPoint)
	self.reappearPlayerPoint:PlaceAtMe(self.summonTargetFXActivator)
	self.reappearDremoraPoint:PlaceAtMe(self.summonTargetFXActivator)
	self.solveT = 1.75
	return S.Reinforce
end

steps[S.Reinforce] = function(self)
	self.atronach01SummonPoint:PlaceAtMe(self.summonTargetFXActivator)
	self.solveT = 0.33
	return S.Atronach1
end

steps[S.Atronach1] = function(self)
	self.atronach01SummonPoint:PlaceAtMe(self.lvlAtronachAny)
	self.atronach02SummonPoint:PlaceAtMe(self.summonTargetFXActivator)
	self.solveT = 0.33
	return S.Atronach2
end

steps[S.Atronach2] = function(self)
	self.atronach02SummonPoint:PlaceAtMe(self.lvlAtronachAny)
	return S.AwaitDeath
end

steps[S.AwaitDeath] = function(self)
	if not self.dremora:IsDead() then
		self.solveT = 1.0
		return nil
	end
	return S.Done
end

return function(C)
	C.__vars.solve = S.Idle
	C.__vars.solveT = rt.timer(0.0)
	C.__vars.dremora = rt.form("Actor")

	function C:solveMaze()
		if self.solve ~= S.Idle then return end -- checkMaze's hasSolved already guards this
		self.myPortal:Enable()
		self.solve, self.solveT = S.PortalOn, 0.1
	end

	function C:OnTick()
		while steps[self.solve] and self.solveT <= 0 do
			local next = steps[self.solve](self)
			if not next then return end
			self.solve = next
		end
	end
end
