-- pex: base.onactivate 8b8a0bb8
-- A standing stone told a player who already had its power so, or asked (ShowSign) whether to
-- take it; button 0 swapped the sign. It then stayed shut 15 s after a swap, else 2 s. Now OnTick
-- reads the answer, and `reopen` is the time until the stone takes an activation again.
local rt = require('skymod.rt')

local SIGNS = { "Apprentice", "Atronach", "Lady", "Lord", "Lover", "Mage", "Ritual", "Serpent", "Shadow", "Steed", "Thief", "Tower", "Warrior" }

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.reopen = rt.timer(rt.None)
	local Base = rt.state(C, "base")
	local function player() return rt.static("Game", "GetPlayer") end

	local function sign_message(self)
		for _, s in ipairs(SIGNS) do
			if self["b" .. s] then return self["pDoom" .. s .. "MSG"] end
		end
	end

	function Base:OnActivate(obj)
		if not self.doOnce or rt.cast(obj, "actor") ~= player() then return end
		self.doOnce = false
		for _, s in ipairs(SIGNS) do
			if self["b" .. s] and player():HasSpell(self["pDoom" .. s .. "Ability"]) then
				self.pDoomAlreadyHaveMSG:Show()
				self.reopen = 2.0
				return
			end
		end
		self.asking = true
		sign_message(self):Show()
	end

	function C:OnTick()
		if self.reopen ~= rt.None and self.reopen <= 0 then
			self.reopen = rt.None
			self.doOnce = true
		end
		if not self.asking then return end
		local msg = sign_message(self)
		local choice = msg:Answer()
		if choice < 0 then return msg:Show() end
		self.asking = false
		if choice ~= 0 then
			self.reopen = 2.0
			return
		end
		self:removeSign()
		self:addSign()
		self:PlayAnimation("playanim01")
		self.reopen = 15.0
	end
end
