-- pex: vampirechange 5129e11e
-- pex: vampirefeed 35978e8a
-- pex: vampireprogression 380069a0 7d4092b2
-- VampireProgression hid stages 2-4 behind a 2 s crossfade before it swapped the spells.
-- VampireChange and VampireFeed each waited under a 2 s crossfade (Change then 1 s more).
-- Each is now a run stepped by OnTick in "Busy". Callers wait while `prog` or `change` is not Idle.
local rt = require('skymod.rt')

return function(C)
	C.Prog = rt.sequence("Idle", "Fading")
	C.Change = rt.sequence("Idle", "Hiding", "Settling")
	C.Feed = rt.sequence("Idle", "Hiding")
	local P, Ch, Fe = C.Prog, C.Change, C.Feed
	local v = C.__vars
	v.prog, v.prog_t = P.Idle, rt.timer(0.0)
	v.prog_player = rt.form("Actor")
	v.prog_want = rt.int(0)                  -- the stage the player's powers should match
	v.change, v.change_t = Ch.Idle, rt.timer(0.0)
	v.change_target = rt.form("Actor")
	v.feed, v.feed_t = Fe.Idle, rt.timer(0.0)
	v.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")

	local RACES = { "Argonian", "Breton", "DarkElf", "HighElf", "Imperial", "Khajiit", "Nord", "Orc", "Redguard", "WoodElf" }
	local DISEASES = { "BoneBreakFever", "BrainRot", "Rattles", "Rockjoint", "Witbane", "PorphyricHemophelia", "Ataxia" }

	local function player() return rt.static("Game", "GetPlayer") end
	local function busy(self)
		if self:GetState() ~= "Busy" then self:GotoState("Busy") end
	end
	local function remove_crossfade() rt.static("ImageSpaceModifier", "RemoveCrossFade") end

	-- Stages 2-4 replace the lower stages' spells; stage 1 replaces all the others.
	local function others(n)
		if n == 1 then return { 2, 3, 4 } end
		local t = {}
		for k = 1, n - 1 do t[#t] = k end
		return t
	end

	local function swap_spells(self, p, n)
		local function s(name, k) return self[name .. "0" .. k] end
		local drain = s("VampireDrain", n)
		if n == 1 then
			p:AddSpell(self.ABVampireSkills, false)
			p:AddSpell(self.ABVampireSkills02, false)
		end
		for _, k in ipairs(others(n)) do
			p:RemoveSpell(s("AbVampire", k))
			p:RemoveSpell(self["AbVampire0" .. k .. "b"])
		end
		p:AddSpell(s("AbVampire", n), false)
		p:AddSpell(self["AbVampire0" .. n .. "b"], false)
		p:AddSpell(drain, false)
		for hand = 0, 1 do
			for _, k in ipairs(others(n)) do
				if p:GetEquippedSpell(hand) == s("VampireDrain", k) then p:EquipSpell(drain, hand) end
			end
		end
		for _, k in ipairs(others(n)) do
			p:RemoveSpell(s("VampireDrain", k))
			p:RemoveSpell(s("VampireRaiseThrall", k))
			p:RemoveSpell(s("VampireSunDamage", k))
		end
		p:AddSpell(s("VampireRaiseThrall", n), false)
		p:AddSpell(s("VampireSunDamage", n), false)
		if n == 1 then
			p:RemoveSpell(self.VampireCharm)
			p:RemoveSpell(self.VampireInvisibilityPC)
		elseif n == 2 then
			p:AddSpell(self.VampireCharm)
		elseif n == 4 then
			p:AddSpell(self.VampireInvisibilityPC)
		end
	end

	-- A call during a fade changes the stage that fade ends on.
	function C:VampireProgression(Player, VampireStage)
		self.prog_player, self.prog_want = Player, VampireStage
		if VampireStage == 1 then return swap_spells(self, Player, 1) end -- no wait; runs even mid-fade
		if self.prog ~= P.Idle then return end
		if VampireStage < 2 or VampireStage > 4 then return end
		self.prog = P.Fading
		self.prog_t = 2.0
		busy(self)
		self.VampireTransformIncreaseISMD:ApplyCrossFade(2.0)
	end

	local function prog_tick(self)
		if self.prog ~= P.Fading or self.prog_t > 0 then return end
		self.prog = P.Idle
		remove_crossfade()
		if self.prog_want >= 1 and self.prog_want <= 4 then swap_spells(self, self.prog_player, self.prog_want) end
	end

	function C:VampireChange(Target)
		if self.change ~= Ch.Idle then return end
		self.change = Ch.Hiding
		self.change_t = 2.0
		self.change_target = Target
		busy(self)
		rt.static("Game", "DisablePlayerControls")
		self.VampireChangeFX:Play(Target)
		self.VampireTransformIncreaseISMD:ApplyCrossFade(2.0)
		local marker = Target:PlaceAtMe(self.Xmarker)
		self.MAGVampireTransform01:Play(marker)
		marker:Disable()
	end

	local function turn(self, target)
		remove_crossfade()
		self.VampireChangeFX:Stop(target)
		local race = target:GetActorBase():GetRace()
		for _, name in ipairs(RACES) do
			if race == self[name .. "Race"] then
				self.CureRace = race
				target:SetRace(self[name .. "RaceVampire"])
				break
			end
		end
		for _, prefix in ipairs({ "Disease", "TrapDisease" }) do
			for _, name in ipairs(DISEASES) do target:RemoveSpell(self[prefix .. name]) end
		end
		self.VampireStatus = 1
		self:VampireProgression(player(), 1)
		self:RegisterForUpdateGameTime(12)
		self.LastFeedTime = self.GameDaysPassed:GetValue()
		self.PlayerIsVampire:SetValue(1)
	end

	local function change_tick(self)
		if self.change == Ch.Idle or self.change_t > 0 then return end
		local target = self.change_target
		if self.change == Ch.Hiding then
			self.change = Ch.Settling
			self.change_t = self.change_t + 1.0
			return turn(self, target)
		end
		self.change = Ch.Idle
		rt.static("Game", "EnablePlayerControls")
		if self.VC01:GetStageDone(200) then self.VC01:SetStage(25) end
	end

	function C:VampireFeed()
		if self.feed ~= Fe.Idle then return end
		self.feed = Fe.Hiding
		self.feed_t = 2.0
		busy(self)
		self.VampireTransformDecreaseISMD:ApplyCrossFade(2.0)
	end

	local function feed_tick(self)
		if self.feed ~= Fe.Hiding or self.feed_t > 0 then return end
		self.feed = Fe.Idle
		remove_crossfade()
		rt.static("Game", "IncrementStat", "Necks Bitten")
		self.VampireFeedMessage:Show()
		self.VampireFeedReady:SetValue(0)
		self.LastFeedTime = self.GameDaysPassed:GetValue()
		self.VampireStatus = 1
		local p = player()
		self:VampireProgression(p, 1)
		p:RemoveFromFaction(self.VampirePCFaction)
		p:SetAttackActorOnSight(false)
		self.CrimeFactions = self.DLC1CrimeFactions
		for i = 0, self.CrimeFactions:GetSize() - 1 do
			rt.cast(self.CrimeFactions:GetAt(i), "Faction"):SetPlayerEnemy(false)
		end
		self:UnregisterForUpdateGameTime()
		self:RegisterForUpdateGameTime(12)
	end

	function Busy:OnTick()
		prog_tick(self)
		change_tick(self)
		feed_tick(self)
		if self.prog == P.Idle and self.change == Ch.Idle and self.feed == Fe.Idle then self:GotoState("") end
	end
end
