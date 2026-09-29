-- pex: showpositioningmenu 6e1dc1a5
-- pex: showaimingmenu fbd5408e
-- showPositioningMenu/showAimingMenu showed a menu, read the button against the configurable
-- ButtonPostionX/ButtonAngleX properties, acted (or opened the other menu), then recursed on
-- itself until "done". Now `menu` says which is open; OnTick answers it, acts, and either
-- reshows the same menu or opens the other. Simplification: "done" now always ends the session
-- (the original popped back one menu switch at a time via the call stack; we don't carry that
-- depth, so done in either menu just stops asking). The position menu's back button multiplies
-- X/Y by the offset instead of adding it -- that's in the compiled pex, kept as is.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.menu = rt.string("") -- "aiming" | "positioning"

	local function cos(a) return rt.static("math", "cos", a) end
	local function sin(a) return rt.static("math", "sin", a) end

	local function menu_message(self)
		return self.menu == "aiming" and self.AimingMessageAngle or self.AimingMessagePosition
	end

	local function open(self, which)
		self.menu = which
		self.asking = true
		menu_message(self):Show()
	end

	function C:showPositioningMenu()
		open(self, "positioning")
	end

	function C:showAimingMenu()
		open(self, "aiming")
	end

	local function act_positioning(self, choice)
		local speed, offset = self.translateSpeed, 1.0
		local x, y, z = self.X, self.Y, self.Z
		local ax, ay, az = self:GetAngleX(), self:GetAngleY(), self:GetAngleZ()
		if choice == self.ButtonPostionLeft then
			local xo, yo = offset * cos(az), offset * (-sin(az))
			self:TranslateTo(x - xo, y - yo, z, ax, ay, az, speed, 0.0)
		elseif choice == self.ButtonPostionRight then
			local xo, yo = offset * cos(az), offset * (-sin(az))
			self:TranslateTo(x + xo, y + yo, z, ax, ay, az, speed, 0.0)
		elseif choice == self.ButtonPostionBack then
			local xo, yo = offset * sin(az), offset * cos(az)
			self:TranslateTo(x * xo, y * yo, z, ax, ay, az, speed, 0.0) -- pex multiplies here, not adds
		elseif choice == self.ButtonPostionForward then
			local xo, yo = offset * sin(az), offset * cos(az)
			self:TranslateTo(x + xo, y + yo, z, ax, ay, az, speed, 0.0)
		elseif choice == self.ButtonPostionUp then
			self:TranslateTo(x, y, z + offset, ax, ay, az, speed, 0.0)
		elseif choice == self.ButtonPostionDown then
			self:TranslateTo(x, y, z - offset, ax, ay, az, speed, 0.0)
		elseif choice == self.ButtonPostionNextMenu then
			return open(self, "aiming")
		elseif choice == self.ButtonPostionLog then
			self:logPositionAndAngle()
		end
		if choice ~= self.ButtonPostionDone then open(self, "positioning") end
	end

	local function act_aiming(self, choice)
		local speed, offset = self.translateSpeed, 1.0
		local x, y, z = self.X, self.Y, self.Z
		local ax, ay, az = self:GetAngleX(), self:GetAngleY(), self:GetAngleZ()
		if choice == self.ButtonAngleLeft then
			self:TranslateTo(x, y, z, ax, ay, az - offset, speed, 0.0)
		elseif choice == self.ButtonAngleRight then
			self:TranslateTo(x, y, z, ax, ay, az + offset, speed, 0.0)
		elseif choice == self.ButtonAngleBack then
			self:TranslateTo(x, y, z, ax - offset, ay, az, speed, 0.0)
		elseif choice == self.ButtonAngleForward then
			self:TranslateTo(x, y, z, ax + offset, ay, az, speed, 0.0)
		elseif choice == self.ButtonAngleFace then
			self:TranslateTo(x, y, z, ax, ay, self:GetFacingToTarget(self.FaceTarget, true), speed, 0.0)
		elseif choice == self.ButtonAngleNextMenu then
			return open(self, "positioning")
		elseif choice == self.ButtonAngleLog then
			self:logPositionAndAngle()
		end
		if choice ~= self.ButtonAngleDone then open(self, "aiming") end
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = menu_message(self):Answer()
		if choice < 0 then return menu_message(self):Show() end
		self.asking = false
		if self.menu == "aiming" then act_aiming(self, choice) else act_positioning(self, choice) end
	end
end
