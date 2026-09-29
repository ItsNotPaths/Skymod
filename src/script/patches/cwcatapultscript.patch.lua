-- pex: launch e328fe49
-- pex: showpositioningmenu 4296af79
-- pex: showaimingmenu 761d7b6d
-- launch() played the fire animation and waited for aeLaunch before firing the weapon. Now the
-- event fires it; `launching` says the arm is up with its payload.
-- showPositioningMenu/showAimingMenu showed a menu, read the button, acted (or opened the other
-- menu), then recursed on itself until "done". Now `menu` says which is open; OnTick answers it,
-- acts, and either reshows the same menu or opens the other. Simplification: "done" now always
-- ends the session (the original popped back one menu switch at a time via the call stack; we
-- don't carry that depth, so done in either menu just stops asking).
local rt = require('skymod.rt')

return function(C)
	C.__vars.launching = rt.bool(false)
	C.__vars.asking = rt.bool(false)
	C.__vars.menu = rt.string("") -- "aiming" | "positioning"
	local converted = C.__fn.onanimationevent

	local function cos(a) return rt.static("math", "cos", a) end
	local function sin(a) return rt.static("math", "sin", a) end

	local function menu_message(self)
		return self.menu == "aiming" and self.CWCatapultMsgAngle or self.CWCatapultMsgPosition
	end

	local function open(self, which)
		self.menu = which
		self.asking = true
		menu_message(self):Show()
	end

	function C:launch()
		self:GotoState(self.busy)
		self.launching = true
		self:PlayAnimation(self.aeFire) -- OnLoad registered aeLaunch
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if self.launching and asEventName == self.aeLaunch then
			self.launching = false
			self.WeaponToFire:Fire(self, self.AmmoToFire)
		end
		converted(self, akSource, asEventName)
	end

	function C:showPositioningMenu()
		open(self, "positioning")
	end

	function C:showAimingMenu()
		open(self, "aiming")
	end

	-- button order: left, right, back, forward, up, down, nextMenu, log, done
	local function act_positioning(self, choice)
		local speed, offset = 100.0, 1.0
		local x, y, z = self.X, self.Y, self.Z
		local ax, ay, az = self:GetAngleX(), self:GetAngleY(), self:GetAngleZ()
		if choice == 0 then
			local xo, yo = offset * cos(az), offset * (-sin(az))
			self:TranslateTo(x + xo, y + yo, z, ax, ay, az, speed, 0.0)
		elseif choice == 1 then
			local xo, yo = offset * cos(az), offset * (-sin(az))
			self:TranslateTo(x - xo, y - yo, z, ax, ay, az, speed, 0.0)
		elseif choice == 2 then
			local xo, yo = offset * sin(az), offset * cos(az)
			self:TranslateTo(x + xo, y + yo, z, ax, ay, az, speed, 0.0)
		elseif choice == 3 then
			local xo, yo = offset * sin(az), offset * cos(az)
			self:TranslateTo(x - xo, y - yo, z, ax, ay, az, speed, 0.0)
		elseif choice == 4 then
			self:TranslateTo(x, y, z + offset, ax, ay, az, speed, 0.0)
		elseif choice == 5 then
			self:TranslateTo(x, y, z - offset, ax, ay, az, speed, 0.0)
		elseif choice == 6 then
			return open(self, "aiming")
		elseif choice == 7 then
			self:logPositionAndAngle()
		end
		if choice ~= 8 then open(self, "positioning") end
	end

	-- button order: left, right, back, forward, face, nextMenu, log, done
	local function act_aiming(self, choice)
		local speed, offset = 100.0, 1.0
		local x, y, z = self.X, self.Y, self.Z
		local ax, ay, az = self:GetAngleX(), self:GetAngleY(), self:GetAngleZ()
		if choice == 0 then
			self:TranslateTo(x, y, z, ax, ay, az - offset, speed, 0.0)
		elseif choice == 1 then
			self:TranslateTo(x, y, z, ax, ay, az + offset, speed, 0.0)
		elseif choice == 2 then
			self:TranslateTo(x, y, z, ax, ay - offset, az, speed, 0.0)
		elseif choice == 3 then
			self:TranslateTo(x, y, z, ax, ay + offset, az, speed, 0.0)
		elseif choice == 4 then
			self:TranslateTo(x, y, z, ax, ay, self:GetFacingToTarget(self.FaceTarget, true), speed, 0.0)
		elseif choice == 5 then
			return open(self, "positioning")
		elseif choice == 6 then
			self:logPositionAndAngle()
		end
		if choice ~= 7 then open(self, "aiming") end
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = menu_message(self):Answer()
		if choice < 0 then return menu_message(self):Show() end
		self.asking = false
		if self.menu == "aiming" then act_aiming(self, choice) else act_positioning(self, choice) end
	end
end
