-- pex: beginvision 57ec98d3
-- pex: visionone.onactivate a9b0211e
-- pex: endvision 2669b82c
-- pex: visionone.onupdate 9989113d
-- BeginVision and EndVision each waited 3 s mid-sequence; now two owed/timer pairs, read from
-- OnTick in the VisionOne state (the object stays in that state from OnLoad on). OnUpdate still
-- polls the heading angle at its native 1 Hz registration, and now just starts EndVision instead
-- of blocking inside it; the disable/delete that used to follow the wait happens once OnTick sees
-- EndVision finish.
local rt = require('skymod.rt')

return function(C)
	C.__vars.beginOwed = rt.bool(false)
	C.__vars.beginT = rt.timer(0.0)
	C.__vars.endOwed = rt.bool(false)
	C.__vars.endT = rt.timer(0.0)
	C.__vars.finishOwed = rt.bool(false)

	function C:BeginVision()
		if self.beginOwed then return end
		rt.static("Game", "DisablePlayerControls", true, true, false, false, true, true, false, false)
		self.whiteout:apply()
		self.beginOwed = true
		self.beginT = 3.0
	end

	function C:EndVision()
		if self.endOwed then return end
		self.da13visionobjectsparent:disable()
		self.whiteout:apply()
		self.endOwed = true
		self.endT = 3.0
	end

	local Vision = rt.state(C, "VisionOne")

	function Vision:OnTick()
		if self.beginOwed and self.beginT <= 0 then
			self.beginOwed = false
			self.da13peryitevisionimod:applyCrossFade(2.0)
			self.da13visionobjectsparent:enable()
			self.peryite:activate(rt.static("Game", "GetPlayer"))
		end
		if self.endOwed and self.endT <= 0 then
			self.endOwed = false
			self.da13peryitevisionimod:Remove()
			rt.static("Game", "EnablePlayerControls")
			if self.finishOwed then
				self.finishOwed = false
				self:disable()
				self:delete()
			end
		end
	end

	-- setUpVars() is unchanged (still converted); only the stage checks below replace it.
	function Vision:OnActivate(actronaut)
		self:setUpVars()
		local player = rt.static("Game", "GetPlayer")
		if actronaut ~= player then return end

		local justStarted = false
		if self.da13:getStage() == 21 then
			self.da13:setStage(30)
			self.triggerstage = 45
			self:BeginVision()
			justStarted = true
		end
		if not justStarted then
			local s = self.da13:getStage()
			if s > 21 and s < 45 then self.peryite:activate(player) end
		end

		if self.da13:getStage() >= 75 and self.da13:getStage() < 100 then
			self.da13:setStage(80)
			self.triggerstage = 100
			self:BeginVision()
			justStarted = true
		end
		if not justStarted then
			local s = self.da13:getStage()
			if s > 75 and not self.da13:getStageDone(100) then self.peryite:activate(player) end
		end
	end

	function Vision:OnUpdate()
		local continueUpdating = true
		if not self.da13:getStageDone(self.triggerstage) then
			local angle = self.player:getHeadingAngle(self.peryite)
			if not self.peryite:isInDialogueWithPlayer() and (angle > 50 or angle < -50) then
				self.peryite:activate(self.player)
			end
		else
			self:EndVision()
			continueUpdating = false
			if self.triggerstage == 100 then self.finishOwed = true end
		end
		if continueUpdating then self:registerForSingleUpdate(1.0) end
	end
end
