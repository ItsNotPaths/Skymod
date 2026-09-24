-- pex: idling.onupdate 17b65302
-- pex: landatperch b3c51045
-- pex: playidle d37eb8f9
-- pex: takeflight f08d0be6
-- A bird's update first handled the leash and its goal perch (take off, land), waiting for each
-- animation, then chose what to do from its (maybe new) sState. Now takeFlight, landAtPerch and
-- playIdle start their animation and `action` names it until its event; `deciding` says the
-- update has yet to choose, which OnTick does once no action runs.
local rt = require('skymod.rt')

return function(C)
	C.__vars.action = rt.string("") -- "takeoff", "landing", "idle"
	C.__vars.deciding = rt.bool(false)
	local Idling = rt.state(C, "idling")
	local split_tick = C.__fn.ontick
	local function rnd(a, b) return rt.static("Utility", "RandomInt", a, b) end

	local function play(self, action, anim, event)
		self.action = action
		self:RegisterForAnimationEvent(self, event)
		self:PlayAnimation(anim)
	end

	function C:takeFlight() play(self, "takeoff", "takeOff", "end") end

	function C:landAtPerch(goal)
		self:SplineTranslateTo(goal.X, goal.Y, goal.Z, 0, 0, rt.static("Utility", "RandomFloat", 0.0, 360.0), 300, self.fSpeed / 2)
		play(self, "landing", "startGrndFlap", "StartGrndLook")
	end

	function C:playIdle()
		self.iDice = rnd(1, 2)
		if self.iDice == 1 then play(self, "idle", "StartGrndPeck", "StartGrndLook") else play(self, "idle", "startGrndFlap", "StartGrndLook") end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.action == "takeoff" and asEventName == "end" then
			self.action = ""
			self.sState = "inFlight"
			self:SplineTranslateTo(self.X, self.Y, self.Z + 64, 0, 0, self:GetAngleZ(), 50, self.fSpeed / 2)
		elseif (self.action == "landing" or self.action == "idle") and asEventName == "StartGrndLook" then
			self.action = ""
		end
	end

	-- the second half of the update: behaviour by sState
	local function decide(self)
		self.deciding = false
		local s = self.sState
		if s == "inFlight" then
			-- Papyrus compared (iDice == randomInt) instead of assigning: the last roll decides
			if self.iDice == 1 then
				local goal = self:findPerch()
				if goal then self:flyToPerch(goal) end
			elseif self.iDice == 2 then
				self:FlyTo(self.player)
			end
		elseif s == "perched" or s == "onGround" then
			self.iDice = rnd(1, 3)
			if self.iDice == 1 then self:playIdle() elseif self.iDice == 2 then self:takeFlight() else self:groundHop() end
		end
	end

	function Idling:OnUpdate()
		if self.action ~= "" or self.deciding then return end
		if self.player:GetDistance(self) > self.fMaxPlayerDistance then return self:disableAndDelete() end
		if not self.spawner:isActiveTime() then return end
		if self:GetDistance(self.spawner) > self.leashLength then
			if self.sState == "inFlight" then
				self:GotoState("Flying")
				self:flyAwayHome()
			else
				self:takeFlight()
			end
		end
		if self.goalPerch and self:GetDistance(self.goalPerch) < 32 then
			self:GotoState("Flying")
			self:landAtPerch(self.goalPerch)
		end
		self.deciding = true
		self:OnTick()
	end

	function C:OnTick()
		split_tick(self)
		if self.deciding and self.action == "" then decide(self) end
	end
end
