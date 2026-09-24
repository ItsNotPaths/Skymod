-- pex: bellshapetranslatetorefatspeed d4b50ccc
-- pex: kickoffonstart.onupdate fda25bc9
-- pex: placedummymarker d02e79fd
-- pex: placelandingmarker 6dd42b1b
-- pex: splinetranslatetorefatspeed cd634be1
-- pex: translatetorefatspeed 96b5ea6d
-- pex: warptorefandgotostate 241a1c46
-- pex: warptorefnodeandgotostate 81ee10ee
-- The marker polls waited while a marker had no 3D and the critter had. A marker placed at a
-- loaded critter (PlaceAtMe) has its 3D at once here, and MoveToNode / SetPosition keep it, so
-- the polls always pass at once and are gone. The Translate* and WarpTo* functions waited only
-- through PlaceLandingMarker / PlaceDummyMarker and need no change.
local rt = require('skymod.rt')

return function(C)
	local Kick = rt.state(C, "KickOffOnStart")

	function Kick:OnUpdate()
		self:GotoState("")
		self.landingMarker = self:PlaceAtMe(self.LandingMarkerForm)
		self.dummyMarker = self:PlaceAtMe(self.LandingMarkerForm)
		self:OnStart()
		self:Enable()
	end

	function C:PlaceLandingMarker(arTarget, asTargetNode)
		local m = self.landingMarker
		if asTargetNode ~= "" then return m:MoveToNode(arTarget, asTargetNode) end
		local function R(a, b) return rt.static("Utility", "RandomFloat", a, b) end
		m:SetPosition(arTarget.X + R(-self.fPositionVarianceX, self.fPositionVarianceX),
			arTarget.Y + R(-self.fPositionVarianceY, self.fPositionVarianceY),
			arTarget.Z + R(self.fPositionVarianceZMin, self.fPositionVarianceZMax))
		m:SetAngle(arTarget:GetAngleX() + R(-self.fAngleVarianceX, self.fAngleVarianceX), arTarget:GetAngleY(),
			arTarget:GetAngleZ() + R(-self.fAngleVarianceZ, self.fAngleVarianceZ))
	end

	function C:PlaceDummyMarker(arTarget, asTargetNode)
		self.dummyMarker:MoveToNode(arTarget, asTargetNode)
	end
end
