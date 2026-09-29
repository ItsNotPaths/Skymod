-- pex: default.onactivate 21b13755
-- Each perk activator asked to swap it in; button 0 disabled the orb that unlocks it. A perk
-- whose prerequisite orb was not enabled showed RejectMsg instead, with no pick to read. OnTick
-- reads the pick for whichever perk was asked.
local rt = require('skymod.rt')

local PERKS = {
	[0] = { act = "perk1act", msg = "perk1msg", orb = "perk1orb" },
	[1] = { act = "perk2act", msg = "perk2msg", orb = "perk2orb", prereq = "perk1orb" },
	[2] = { act = "perk3act", msg = "perk3msg", orb = "perk3orb", prereq = "perk1orb" },
	[3] = { act = "perk4act", msg = "perk4msg", orb = "perk4orb", prereq = "perk1orb" },
	[4] = { act = "perk5act", msg = "perk5msg", orb = "perk5orb", prereq = "perk2orb" },
	[5] = { act = "perk6act", msg = "perk6msg", orb = "perk6orb", prereq = "perk3orb" },
	[6] = { act = "perk7act", msg = "perk7msg", orb = "perk7orb", prereq = "perk4orb" },
	[7] = { act = "perk8act", msg = "perk8msg", orb = "perk8orb", prereq = "perk6orb" },
}

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.asking_msg = rt.form("Message")
	C.__vars.asking_orb = rt.form("ObjectReference")

	function C:OnActivate(obj)
		if obj ~= rt.static("Game", "GetPlayer") then return end
		for i = 0, 7 do
			local p = PERKS[i]
			if self[p.act] then
				if p.prereq and not self[p.prereq]:IsEnabled() then return self.RejectMsg:Show() end
				self.asking = true
				self.asking_msg, self.asking_orb = self[p.msg], self[p.orb]
				return self.asking_msg:Show()
			end
		end
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.asking_msg:Answer()
		if choice < 0 then return self.asking_msg:Show() end
		self.asking = false
		if choice == 0 then self.asking_orb:Enable(false) end
	end
end
