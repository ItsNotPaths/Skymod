-- pex: endsigdisbattle d7d60703
-- pex: assessduplicates 26543576
-- pex: duplicate 9106e20e
-- pex: updateloop 8ec17a3b
-- Duplicate is the same banish/place/summon beat as dunGeirmundsBossBattle, gated by battleActive
-- instead of a boss health stage, three duplicates instead of two, one extra 0.5s beat before the
-- 2s one. EndSigdisBattle called DismissDuplicate on the three duplicates one at a time on its own
-- thread (a plain function call, not a new thread, so each 1s fade blocked the next call); here it
-- starts duplicate N, waits for its `dismissing` fact to clear, then moves to N+1.
-- lastDuplicationTime becomes a stopwatch.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.Stage = rt.sequence("Idle", "Ghost", "Disable", "Place", "Finish")
	C.__vars.dupStage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.notBattle = rt.bool(false)
	C.__vars.sinceDup = rt.stopwatch(0.0)
	C.__vars.pollT = rt.timer(0.0)

	local End = rt.sequence("Idle", "Prep", "Dismiss", "Finish")
	C.__vars.endStage = End.Idle
	C.__vars.endT = rt.timer(0.0)
	C.__vars.dismissIdx = rt.int(1)     -- which of the three duplicates is being dismissed
	C.__vars.dismissStarted = rt.bool(false)

	local S = C.Stage
	local dupSteps = {}
	dupSteps[S.Ghost] = function(self)
		self.notBattle = not self.battleactive
		if self.notBattle then return S.Finish end
		local actor = self:GetActorRef()
		actor:SetAV("Variable06", 1.0)
		actor:EvaluatePackage()
		actor:SetGhost(true)
		actor:PlaceAtMe(self.BanishFX)
		self.t = self.t + 0.5
		return S.Disable
	end
	dupSteps[S.Disable] = function(self)
		self:GetActorRef():Disable(false)
		self.t = self.t + 2.0
		return S.Place
	end
	dupSteps[S.Place] = function(self)
		self.Duplicate1Actor = self.Duplicate1SetupPoint:PlaceActorAtMe(self.DuplicateActorBase, self.DuplicateLevelMod, self.DuplicateEncZone)
		self.Duplicate1Alias:ForceRefTo(self.Duplicate1Actor)
		self.Duplicate1Actor:Disable()
		self.Duplicate2Actor = self.Duplicate2SetupPoint:PlaceActorAtMe(self.DuplicateActorBase, self.DuplicateLevelMod, self.DuplicateEncZone)
		self.Duplicate2Alias:ForceRefTo(self.Duplicate2Actor)
		self.Duplicate2Actor:Disable()
		self.Duplicate3Actor = self.Duplicate3SetupPoint:PlaceActorAtMe(self.DuplicateActorBase, self.DuplicateLevelMod, self.DuplicateEncZone)
		self.Duplicate3Alias:ForceRefTo(self.Duplicate3Actor)
		self.Duplicate3Actor:Disable()

		local function swap(aName, bName, near)
			local a, b = self[aName], self[bName]
			if a:GetDistance(near) < b:GetDistance(near) then
				self[aName], self[bName] = b, a
			end
		end
		local player = rt.static("Game", "GetPlayer")
		swap("Position1", "Position6", player)
		swap("Position2", "Position6", player)
		swap("Position3", "Position6", player)
		swap("Position4", "Position6", player)
		swap("Position5", "Position6", player)
		local actor = self:GetActorRef()
		swap("Position1", "Position5", actor)
		swap("Position2", "Position5", actor)
		swap("Position3", "Position5", actor)
		swap("Position4", "Position5", actor)

		local spot = rt.static("Utility", "RandomInt", 1, 4)
		if spot == 1 then
			actor:MoveTo(self.Position1)
			self.Duplicate1Actor:MoveTo(self.Position2)
			self.Duplicate2Actor:MoveTo(self.Position3)
			self.Duplicate3Actor:MoveTo(self.Position4)
		elseif spot == 2 then
			actor:MoveTo(self.Position2)
			self.Duplicate1Actor:MoveTo(self.Position3)
			self.Duplicate2Actor:MoveTo(self.Position4)
			self.Duplicate3Actor:MoveTo(self.Position5)
		elseif spot == 3 then
			actor:MoveTo(self.Position3)
			self.Duplicate1Actor:MoveTo(self.Position4)
			self.Duplicate2Actor:MoveTo(self.Position5)
			self.Duplicate3Actor:MoveTo(self.Position1)
		else -- spot == 4; Papyrus sends Duplicate3 to Position3 here, not the +3 pattern
			actor:MoveTo(self.Position4)
			self.Duplicate1Actor:MoveTo(self.Position5)
			self.Duplicate2Actor:MoveTo(self.Position1)
			self.Duplicate3Actor:MoveTo(self.Position3)
		end

		if actor:IsDead() then
			self.Duplicate1Actor:Disable()
			self.Duplicate2Actor:Disable()
			self.Duplicate3Actor:Disable()
		else
			self.SummonFXManager:GetReference():Activate(player)
		end
		actor:PlaceAtMe(self.SummonFX)
		self.t = self.t + 1.0
		return S.Finish
	end
	dupSteps[S.Finish] = function(self)
		if not self.notBattle then
			local actor = self:GetActorRef()
			actor:SetGhost(false)
			actor:SetAV("Variable06", 0.0)
			actor:Enable(true)
			actor:EquipItem(self.GauldurBlackbow, true, false)
			actor:EvaluatePackage()
			actor:StartCombat(rt.static("Game", "GetPlayer"))
		end
		self.sinceDup = 0.0
		self.DuplicationUses = self.DuplicationUses + 1
		return S.Idle
	end

	function C:Duplicate()
		if self.dupStage ~= S.Idle then return end
		self.dupStage = S.Ghost
		self.t = 0.0
		self.BanishFXManager:GetReference():Activate(rt.static("Game", "GetPlayer")) -- dismiss surviving duplicates
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

	function C:UpdateLoop()
		if self.InUpdateLoop then return end
		self.InUpdateLoop = true
		self.pollT = 0.0
	end

	-- EndSigdisBattle: see dungeirmundsbossduplicates.patch.lua for `dismissing`.
	local function dup(self, idx)
		return rt.cast(self["Duplicate" .. idx .. "Actor"], "dungeirmundsbossduplicates")
	end
	local endSteps = {}
	endSteps[End.Prep] = function(self)
		local actor = self:GetActorRef()
		actor:SetGhost(true)
		actor:PlaceAtMe(self.BanishFX)
		actor:Disable(false)
		actor:Resurrect()
		actor:SetAV("Health", 10.0)
		actor:MoveTo(actor:GetLinkedRef(self.LinkCustom02))
		self.endT = self.endT + 1.0
		self.dismissIdx = 1
		return End.Dismiss
	end
	endSteps[End.Dismiss] = function(self)
		if self.dismissIdx > 3 then
			self:GetActorRef():PlaceAtMe(self.SummonFX)
			self.endT = self.endT + 1.0
			return End.Finish
		end
		if not self.dismissStarted then
			self.dismissStarted = true
			if self.dismissIdx == 1 then
				self.BanishFXManager:GetReference():Activate(rt.static("Game", "GetPlayer"))
			end
			local d = dup(self, self.dismissIdx)
			if d then d:DismissDuplicate() end
		end
		local d = dup(self, self.dismissIdx)
		if d and d.dismissing then
			self.endT = 0.0 -- still fading; hold at zero, don't drift while polling
			return nil
		end
		self.dismissIdx = self.dismissIdx + 1
		self.dismissStarted = false
		self.endT = 0.0 -- next duplicate starts on the next tick
		return nil
	end
	endSteps[End.Finish] = function(self)
		local actor = self:GetActorRef()
		actor:Enable(true)
		actor:SetAlpha(0.33, false)
		actor:GetActorBase():SetEssential(true)
		actor:SetNoBleedoutRecovery(true)
		actor:DamageAV("Health", 10000.0)
		self.battleactive = false
		self.dunGauldursonQST:SetStage(129)
		self.dismissStarted = false
		return "done"
	end

	function C:EndSigdisBattle()
		if self.endStage ~= End.Idle then return end
		self.endStage = End.Prep
		self.endT = 0.0
	end

	function C:OnTick()
		while self.dupStage ~= S.Idle and self.t <= 0 do
			self.dupStage = dupSteps[self.dupStage](self)
		end
		while self.endStage ~= End.Idle and self.endT <= 0 do
			local nxt = endSteps[self.endStage](self)
			if not nxt then break end
			self.endStage = nxt == "done" and End.Idle or nxt
		end
		if self.InUpdateLoop and self.pollT <= 0 then
			if not self.battleactive then
				self.InUpdateLoop = false
			else
				if self.sinceDup >= 35 then
					self:Duplicate()
				elseif self.Duplicate1Actor:IsDead() and self.Duplicate2Actor:IsDead() and self.sinceDup >= 20 then
					self:Duplicate()
				end
				self.pollT = self.pollT + 1.0
			end
		end
	end
end
