-- pex: assessduplicates 87a5ce1e
-- pex: duplicate 54adce3f
-- pex: ongetup 94a81316
-- pex: updateloop f0c01056
-- Duplicate ran the banish/place/summon beats through three Waits, guarded by duplicationOngoing;
-- now a stage plus one timer. lastDuplicationTime (GetCurrentRealTime, a frozen stub) becomes a
-- stopwatch reset when Duplicate finishes. UpdateLoop's while-poll becomes OnTick at TickRate.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.Stage = rt.sequence("Idle", "Banish", "Place", "Summon", "Finish")
	C.__vars.dupStage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.dupDead = rt.bool(false)
	C.__vars.sinceDup = rt.stopwatch(0.0) -- real time since the last Duplicate finished
	C.__vars.pollT = rt.timer(0.0)        -- UpdateLoop's Wait(1)
	local S = C.Stage
	local split_tick = C.__fn.ontick -- OnDeath's own wait, from the S6 split

	local function swap(self, aName, bName, near)
		local a, b = self[aName], self[bName]
		if a:GetDistance(near) < b:GetDistance(near) then
			self[aName], self[bName] = b, a
		end
	end

	local steps = {}
	steps[S.Banish] = function(self)
		local actor = self:GetActorRef()
		self.dupDead = actor:IsDead()
		if self.dupDead then return S.Finish end -- Place/Summon below no-op when dead; matches EndIf skip
		actor:SetAV("Variable06", 1.0)
		actor:EvaluatePackage()
		actor:SetGhost(true)
		actor:PlaceAtMe(self.BanishFX)
		actor:Disable(true)
		self.t = self.t + 2.0
		return S.Place
	end
	steps[S.Place] = function(self)
		self.Duplicate1Actor = self.Duplicate1SetupPoint:PlaceActorAtMe(self.DuplicateActorBase, self.DuplicateLevelMod, self.DuplicateEncZone)
		self.Duplicate1Alias:ForceRefTo(self.Duplicate1Actor)
		self.Duplicate1Actor:Disable()
		self.Duplicate2Actor = self.Duplicate2SetupPoint:PlaceActorAtMe(self.DuplicateActorBase, self.DuplicateLevelMod, self.DuplicateEncZone)
		self.Duplicate2Alias:ForceRefTo(self.Duplicate2Actor)
		self.Duplicate2Actor:Disable()

		local player = rt.static("Game", "GetPlayer")
		swap(self, "Position1", "Position4", player)
		swap(self, "Position2", "Position4", player)
		swap(self, "Position3", "Position4", player)
		local actor = self:GetActorRef()
		swap(self, "Position1", "Position3", actor)
		swap(self, "Position2", "Position3", actor)

		if rt.static("Utility", "RandomInt", 1, 2) == 1 then
			actor:MoveTo(self.Position1)
			self.Duplicate1Actor:MoveTo(self.Position2)
		else
			actor:MoveTo(self.Position2)
			self.Duplicate1Actor:MoveTo(self.Position1)
		end
		self.Duplicate2Actor:MoveTo(self.Position3)
		self.t = self.t + 0.1
		return S.Summon
	end
	steps[S.Summon] = function(self)
		self.SummonFXManager:GetReference():Activate(rt.static("Game", "GetPlayer"))
		self:GetActorRef():PlaceAtMe(self.SummonFX)
		self.t = self.t + 0.5
		return S.Finish
	end
	steps[S.Finish] = function(self)
		if not self.dupDead then
			local actor = self:GetActorRef()
			actor:SetGhost(false)
			actor:SetAV("Variable06", 0.0)
			actor:Enable(true)
			actor:EvaluatePackage()
			actor:StartCombat(rt.static("Game", "GetPlayer"))
		end
		self.sinceDup = 0.0
		self.DuplicationUses = self.DuplicationUses + 1
		return S.Idle
	end

	function C:Duplicate()
		if self.dupStage ~= S.Idle then return end -- duplicationOngoing lock
		if self.dunGeirmundsQST:GetStage() >= 10 then return end
		self.dupStage = S.Banish
		self.t = 0.0
	end

	function C:AssessDuplicates()
		local actor = self:GetActorRef()
		if actor:GetAV("Health") <= 0 or self.BlockHitTesting then return end
		self.BlockHitTesting = true
		if self.threshold == 0 and actor:GetActorValuePercentage("Health") <= 0.75 then
			self.threshold = 1
			self.DuplicationUsesLastThreshold = self.DuplicationUses
			if self.DuplicationUses == 1 then self:Duplicate() end
		elseif self.threshold == 1 and actor:GetActorValuePercentage("Health") <= 0.5 then
			self.threshold = 2
			if self.DuplicationUses == self.DuplicationUsesLastThreshold then
				self:Duplicate()
			else
				self.DuplicationUsesLastThreshold = self.DuplicationUses
				if self.DuplicationUses == 2 then self:Duplicate() end
			end
		elseif self.threshold == 2 and actor:GetActorValuePercentage("Health") <= 0.25 then
			self.threshold = 3
			if self.DuplicationUses == self.DuplicationUsesLastThreshold then
				self:Duplicate()
			else
				self.DuplicationUsesLastThreshold = self.DuplicationUses
				if self.DuplicationUses == 3 then self:Duplicate() end
			end
		end
		self.BlockHitTesting = false
	end

	function C:OnGetUp(akFurniture)
		self:GetActorRef():SetAV("Variable07", 1.0)
		if self.dunGeirmundsQST:GetStage() >= 10 then return end
		self:Duplicate()
		if not self.InUpdateLoop then self:UpdateLoop() end
	end

	function C:UpdateLoop()
		if self.InUpdateLoop then return end
		self.InUpdateLoop = true
		self.pollT = 0.0
	end

	function C:OnTick()
		split_tick(self)
		while self.dupStage ~= S.Idle and self.t <= 0 do
			self.dupStage = steps[self.dupStage](self)
		end
		if self.InUpdateLoop and self.pollT <= 0 then
			local actor = self:GetActorRef()
			local going = not actor:IsDead() and self.dunGeirmundsQST:GetStage() < 10
				and rt.static("Game", "GetPlayer"):GetCurrentLocation() == self.GeirmundsHallLocation
			if not going then
				self.InUpdateLoop = false
			else
				if self.sinceDup >= 25 then
					self:Duplicate()
				elseif self.Duplicate1Actor:IsDead() and self.Duplicate2Actor:IsDead() and self.sinceDup >= 15 then
					self:Duplicate()
				end
				self.pollT = self.pollT + 1.0
			end
		end
	end
end
