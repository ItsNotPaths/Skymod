-- pex: onactivate f4437c78
-- pex: onequipped a91ebd7d
-- pex: readoghmainfinium 14801a67
-- Reading the Oghma Infinium waited 2 s (WaitMenuMode) before ReadOghmaInfinium, which S6 splits.
-- Now `open_t` holds the 2 s, a real timer (script-api.md section 7), and `from_world` which way
-- it was read. ReadOghmaInfinium itself asked which skills to raise; the event now asks, and
-- OnTick reads the pick, raises the skills, and (unless cancelled) arms the S6 split's own 0.1 s
-- wait that consumes the book.
local rt = require('skymod.rt')

return function(C)
	C.__vars.open_t = rt.timer(rt.None)
	C.__vars.from_world = rt.bool(false)
	C.__vars.asking = rt.bool(false)
	local split_tick = C.__fn.ontick
	local function player() return rt.static("Game", "GetPlayer") end

	local function raise(self, group)
		for _, av in ipairs(group) do rt.static("Game", "IncrementSkillBy", av, self.Advancement) end
	end
	-- choice 1/2/3 (0 is cancel); keyed explicitly since {a, b} starts at 0 in this Lua fork
	local SKILLS = {
		[1] = { "Smithing", "HeavyArmor", "Block", "TwoHanded", "OneHanded", "Marksman" },
		[2] = { "LightArmor", "Sneak", "Lockpicking", "Pickpocket", "Speechcraft", "Alchemy" },
		[3] = { "Illusion", "Conjuration", "Destruction", "Restoration", "Alteration", "Enchanting" },
	}

	local function open(self, from_world)
		if self.open_t ~= rt.None then return end
		self.from_world = from_world
		self.open_t = 2.0
	end

	function C:OnEquipped(reader)
		if reader == player() then open(self, false) end
	end

	function C:OnActivate(reader)
		if reader == player() and not self:IsActivationBlocked() then open(self, true) end
	end

	function C:ReadOghmaInfinium(fromWorld)
		if self.asking or self.vars["readoghmainfinium.t"] ~= rt.None then return end -- a call while it waits is dropped
		if self.HasBeenRead or not self.DA04:GetStageDone(200) then return end
		local choiceGlobal = rt.cast(rt.static("Game", "GetFormFromFile", 16779742, "Update.esm"), "GlobalVariable")
		if choiceGlobal:GetValue() >= 1.0 then return end
		self.asking = true
		self.ChoiceMessage:Show()
	end

	function C:OnTick()
		split_tick(self)
		if self.asking then
			local choice = self.ChoiceMessage:Answer()
			if choice < 0 then return self.ChoiceMessage:Show() end
			self.asking = false
			if SKILLS[choice] then raise(self, SKILLS[choice]) end
			if choice ~= 0 then
				self.HasBeenRead = true
				rt.cast(rt.static("Game", "GetFormFromFile", 16779742, "Update.esm"), "GlobalVariable"):SetValue(1.0)
				self.vars["readoghmainfinium.fromworld"] = self.from_world
				self.vars["readoghmainfinium.t"] = 0.1
			end
			return
		end
		if self.open_t == rt.None or self.open_t > 0 then return end
		self.open_t = rt.None
		self:ReadOghmaInfinium(self.from_world)
	end
end
