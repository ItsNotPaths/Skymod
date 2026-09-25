-- pex: onhit 2ae9f915
-- Hit by the player, a fake critter placed its container, flora and ingredient, showed them 0.01 s
-- later, disabled itself 0.1 s after that and was ready to reset hoursBeforeReset game hours
-- later. Now `hit` walks those steps; the reset wait is a game timer.
local rt = require('skymod.rt')

return function(C)
	C.Hit = rt.sequence("Idle", "Placed", "Shown", "Resetting")
	local S = C.Hit
	C.__vars.hit = S.Idle
	C.__vars.hit_t = rt.timer(0.0)
	C.__vars.reset_t = rt.gametimer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	local function show(self, r)
		if not r then return end
		r:Enable(false)
		r:MoveToNode(self, self.myLocationOffset)
	end

	function C:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		if akAggressor ~= rt.static("Game", "GetPlayer") or self.doOnce ~= 0 then return end
		self.doOnce = 1
		if self.myContainer then self.myContainerRef = self:PlaceAtMe(self.myContainer, 1, false, true) end
		if self.myFlora then self.myFloraRef = self:PlaceAtMe(self.myFlora, 1, false, true) end
		if self.myIngredient then
			self.myIngredientRef = self:PlaceAtMe(self.myIngredient)
			self.myIngredientRef:MoveToNode(self, self.myLocationOffset)
		end
		self.hit = S.Placed
		self.hit_t = 0.01
	end

	function C:OnTick()
		split_tick(self)
		if self.hit == S.Idle then return end
		if self.hit == S.Resetting then
			if self.reset_t > 0 then return end
			self.hit = S.Idle
			self.readyToReset = true
			return
		end
		if self.hit_t > 0 then return end
		if self.hit == S.Placed then
			show(self, self.myContainerRef)
			show(self, self.myFloraRef)
			self.hit = S.Shown
			self.hit_t = self.hit_t + 0.1
		else
			self:Disable()
			self.hit = S.Resetting
			self.reset_t = self.hoursBeforeReset
		end
	end
end
