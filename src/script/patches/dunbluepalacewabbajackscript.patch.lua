-- pex: nightmarehandler 6406ca4c
-- pex: oneffectstart b847eb68
-- The first hit bound the three controller scripts and waited 0.5 s before dispatching. The
-- mare's first nightmare started a 120 s window after which, unless every dream was fixed, the
-- dreams undid one per second. Now the first dispatch waits on a timer, and the window runs on
-- the mare controller (dunbluepalacenightmarescript.StartRevert), whose dreams it is about.
local rt = require('skymod.rt')

return function(C)
	C.__vars.settle_t = rt.timer(rt.None)
	C.__vars.first_target = rt.form("Actor")
	local split_tick = C.__fn.ontick

	local function spawn(self, mare, i)
		local nightmare = mare["nightmare" .. i]
		mare["xSpawn" .. i]:PlaceAtMe(self.visualExplosion)
		nightmare:MoveTo(mare["xSpawn" .. i])
		nightmare:Enable()
		rt.cast(nightmare, "Actor"):SetAV("health", 5000)
	end

	-- nightmare i fixed: it becomes dream i
	local function fix(self, mare, i)
		local nightmare, dream = mare["nightmare" .. i], mare["dream" .. i]
		mare.dreamFixed = i
		nightmare:PlaceAtMe(self.visualExplosion)
		if i <= 3 then dream:MoveTo(nightmare) end
		nightmare:Disable()
		dream:Enable()
	end

	local function dispatch(self, target)
		local arena, fear = self.bwpArenaScript, self.bwpFearScript
		if target == arena.playerThrallStorm or target == arena.playerThrallFrost or target == arena.playerThrallFire
			or target == arena.bodyguardA or target == arena.bodyguardB then
			self:arenaTransformation(target)
		elseif self:amIANightmare(target) then
			self:nightMareHandler(target)
		elseif target == fear.pelagiusFear1 or target == fear.pelagiusFear2 or target == fear.pelagiusFear3
			or target == fear.taunter1 or target == fear.taunter2 or target == fear.taunter3 then
			if self.pDA15Loathing:GetStage() <= 40 then self:loathingTransformation(target) end
		end
	end

	function C:OnEffectStart(akTarget, akCaster)
		if not self.doOnce then return dispatch(self, akTarget) end
		self.bwpArenaScript = rt.cast(self.bwpArenaController, "dunBluePalaceArenaSCRIPT")
		self.bwpMareScript = rt.cast(self.bwpMareController, "dunBluePalaceNightmareSCRIPT")
		self.bwpFearScript = rt.cast(self.bwpFearController, "dunBluePalaceFearSCRIPT")
		self.doOnce = false
		self.first_target = akTarget
		self.settle_t = 0.5
	end

	function C:OnTick()
		split_tick(self)
		if self.settle_t == rt.None or self.settle_t > 0 then return end
		self.settle_t = rt.None
		dispatch(self, self.first_target)
	end

	function C:nightMareHandler(akTarget)
		local mare = self.bwpMareScript
		rt.cast(mare.pelagiusMare, "Actor"):EvaluatePackage()
		if akTarget == mare.pelagiusMare then
			local fixed = mare.dreamFixed
			if fixed == 0 then
				spawn(self, mare, 1)
				mare:StartRevert(self.visualExplosion)
			elseif fixed >= 1 and fixed <= 4 then
				spawn(self, mare, fixed + 1)
			end
		end
		for i = 1, 5 do
			if akTarget == mare["nightmare" .. i] then
				fix(self, mare, i)
				if i == 5 then
					self.pDA15Terror:SetStage(40)
					local pelagius = rt.cast(mare.pelagiusMare, "Actor")
					pelagius:StopCombat()
					pelagius:SetGhost(true)
					pelagius:StopCombat()
				end
				return
			end
		end
	end
end
