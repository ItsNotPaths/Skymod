-- pex: ready.onactivate 6b0d9bde
-- pex: referenceattach c1cec1a7 cfd2abb6
-- Placing shards played the crest's animation for each and waited for it; taking the crest did
-- the same. ReferenceAttach waited up to about 25 s for the crest's 3D, then replayed every
-- animation up to animState, each after the last. Now OnTick polls the crest's animation;
-- `crest_anim` is the one playing for an activation, `replay` the next one to replay.
local rt = require('skymod.rt')

local REPLAY = { { 2, "crest01" }, { 3, "crest02" }, { 4, "crest03" }, { 5, "crest04" }, { 6, "take" }, { 6, "open" } }

return function(C)
	C.__vars.crest_anim = rt.string("")
	C.__vars.replay = rt.int(-1) -- -1 idle, 0 waiting for 3D, 1..6 the replay step whose animation plays
	C.__vars.replay_sw = rt.stopwatch(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Ready, Animating = rt.state(C, "Ready"), rt.state(C, "Animating")

	local function player() return rt.static("Game", "GetPlayer") end
	local function crest(self) return self.CrestPedestal:GetReference() end

	local function play(self, anim)
		self.crest_anim = anim
		crest(self):PlayAnimation(anim)
	end

	-- the next shard the player can place, as the four ifs of one activation pass
	local function next_shard(self)
		local n = self.animState
		if n < 1 or n > 4 then return false end
		local shard = self["Shard" .. n]:GetReference()
		if player():GetItemCount(shard) < 1 then return false end
		player():RemoveItem(shard, 1)
		play(self, "crest0" .. n)
		self.hasPerformedAction = true
		return true
	end

	local function done(self)
		self.crest_anim = ""
		self:GotoState("Ready")
	end

	function Ready:OnActivate(akActivator)
		if akActivator ~= player() then return end
		self:GotoState("Animating")
		self.hasPerformedAction = false
		if self.animState < 5 then
			if next_shard(self) then return end
			self.DLC1LD_PedestalFailMessage:Show()
			return done(self)
		end
		if self.animState == 5 and not player():IsInCombat() and not self.Katria:GetActorRef():IsInCombat() then
			self:GetReference():Disable()
			self.DLC1LD:SetStage(179)
			play(self, "take")
			self.hasPerformedAction = true
			return
		end
		self.DLC1LD_PedestalFailCombatMessage:Show()
		done(self)
	end

	local function activation_tick(self)
		local anim = self.crest_anim
		if anim == "" or crest(self):IsAnimRunning(anim) then return end
		if anim == "take" then
			self.DLC1LD:SetStage(180)
			self.animState = 6
			return done(self)
		end
		self.animState = self.animState + 1
		if self.animState == 5 then self.DLC1LD:SetStage(175) end
		if self.animState < 5 and next_shard(self) then return end
		done(self)
	end

	function C:ReferenceAttach()
		if not crest(self) or not self.DLC1LD:IsRunning() then return end
		self.replay = 0
		self.replay_sw = 0.0
		self:OnTick()
	end

	local function replay_tick(self)
		if self.replay == -1 then return end
		if self.replay == 0 then
			if self.replay_sw > 25.25 then -- only the timeout aborts; the wait's own end falls through
				self.replay = -1
				return
			end
			if crest(self) and self.DLC1LD:IsRunning() and not crest(self):Is3DLoaded() then return end
		elseif crest(self):IsAnimRunning(REPLAY[self.replay - 1][1]) then
			return
		end
		while self.replay < #REPLAY do
			self.replay = self.replay + 1
			local step = REPLAY[self.replay - 1]
			if self.animState >= step[0] then return crest(self):PlayAnimation(step[1]) end
		end
		self.replay = -1
	end

	function C:OnTick() replay_tick(self) end

	function Animating:OnTick()
		activation_tick(self)
		replay_tick(self)
	end
end
