-- pex: attenuatefire bc88c76e
-- pex: attenuatefrost 91f39128
-- pex: initial.onactivate c5fef392
-- pex: position01.onmagiceffectapply 9a69cb3b
-- pex: position02.onmagiceffectapply a38df71a
-- pex: position03.onmagiceffectapply 3e6754fd
-- pex: position04.onmagiceffectapply e6e7b2b6
-- pex: position05.onmagiceffectapply 88d337a1
-- pex: position06.onmagiceffectapply 7fbb6baf
-- A frost or fire spell turned the armillary one position and waited for the turn's end event,
-- then set the position (and the quest's BeamsReady at 4). Engaging it played Engage, waited for
-- TransSeq01 and opened the three buttons one after another. Now the events end the turns in
-- busy, and OnTick raises the buttons; `moving_to` is the position being turned to, `raising`
-- the button being raised.
local rt = require('skymod.rt')

return function(C)
	C.__vars.moving_to = rt.int(-1)
	C.__vars.engaging = rt.bool(false)
	C.__vars.raising = rt.int(0)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "busy")
	local converted_event = C.__fn.onanimationevent -- the "Correct" light-ray handler

	local function quest(self) return rt.cast(self.MG06, "MG06QuestScript") end
	local function button(self, n) return rt.cast(self["Button0" .. n], "MG06ButtonScript") end

	-- one turn from `from` to `to`: frost turns up, fire turns down
	local function turn(self, from, to)
		self:GotoState("busy")
		self.moving_to = to
		if to > from then
			self:AttenuateFrost(from, from)
		else
			self:AttenuateFire(from, to)
		end
	end

	function C:AttenuateFire(StateNumber, AnimEventNumber)
		self:RegisterForAnimationEvent(self, "TransBack0" .. AnimEventNumber)
		self:PlayAnimation("Fire0" .. AnimEventNumber)
	end

	function C:AttenuateFrost(StateNumber, AnimEventNumber)
		self:RegisterForAnimationEvent(self, "TransSeq0" .. (AnimEventNumber + 1))
		self:PlayAnimation("Ice0" .. AnimEventNumber)
	end

	local function frost(self, e) return e == self.FrostEffect end
	local function fire(self, e) return e == self.FlameEffect end

	rt.state(C, "Position01").OnMagicEffectApply = function(self, Caster, SpellEffect)
		if SpellEffect:HasKeyword(self.MagicDamageFrost) then turn(self, 1, 2) end
	end
	rt.state(C, "Position02").OnMagicEffectApply = function(self, Caster, SpellEffect)
		if SpellEffect:HasKeyword(self.MagicDamageFire) then
			turn(self, 2, 1)
		elseif frost(self, SpellEffect) then
			turn(self, 2, 3)
		end
	end
	rt.state(C, "Position03").OnMagicEffectApply = function(self, Caster, SpellEffect)
		if fire(self, SpellEffect) then
			turn(self, 3, 2)
		elseif frost(self, SpellEffect) then
			self:RegisterForAnimationEvent(self, "Correct")
			turn(self, 3, 4)
		end
	end
	rt.state(C, "Position04").OnMagicEffectApply = function(self, Caster, SpellEffect)
		if quest(self).CrystalLocked ~= 0 then return end
		if fire(self, SpellEffect) then
			turn(self, 4, 3)
		elseif frost(self, SpellEffect) then
			turn(self, 4, 5)
		end
	end
	rt.state(C, "Position05").OnMagicEffectApply = function(self, Caster, SpellEffect)
		if fire(self, SpellEffect) then
			self:RegisterForAnimationEvent(self, "Correct")
			turn(self, 5, 4)
		elseif frost(self, SpellEffect) then
			turn(self, 5, 6)
		end
	end
	rt.state(C, "Position06").OnMagicEffectApply = function(self, Caster, SpellEffect)
		if fire(self, SpellEffect) then turn(self, 6, 5) end
	end

	rt.state(C, "Initial").OnActivate = function(self, TriggerRef)
		if self.MG06:GetStage() ~= 40 or TriggerRef ~= rt.static("Game", "GetPlayer") or self.ReadyForSpells ~= 0 then return end
		self:GotoState("busy")
		self.MG06:SetStage(50)
		rt.static("Game", "GetPlayer"):RemoveItem(self.MG06Crystal:GetReference(), 1)
		self.engaging = true
		self:RegisterForAnimationEvent(self, "TransSeq01")
		self:PlayAnimation("Engage")
	end

	local function arrive(self, pos)
		local from = self.Positionvar
		self:GotoState("Position0" .. pos)
		if pos == 4 then quest(self).BeamsReady = true elseif from == 4 then quest(self).BeamsReady = false end
		self.Positionvar = pos
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		converted_event(self, akSource, asEventName)
		if akSource ~= self then return end
		if self.engaging and asEventName == "TransSeq01" then
			self.engaging = false
			self.ReadyForSpells = 1
			self:GotoState("Position01")
			self.Positionvar = 1
			self.raising = 1
			button(self, 1):Open()
			return
		end
		local to, from = self.moving_to, self.Positionvar
		if to == -1 then return end
		local ends = to > from and ("TransSeq0" .. (from + 1)) or ("TransBack0" .. to)
		if asEventName ~= ends then return end
		self.moving_to = -1
		arrive(self, to)
	end

	-- the three buttons open one after another, each when the one before has settled
	function C:OnTick()
		local n = self.raising
		if n == 0 or button(self, n):GetState() == "Busy" then return end
		if n == 3 then
			self.raising = 0
		else
			self.raising = n + 1
			button(self, n + 1):Open()
		end
	end
end
