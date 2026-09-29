-- The Spawn Hazard archetype: the effect's hazard (Blizzard, Circle of Protection) where its target
-- stands, cast by its caster.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeSpawnHazard", nil)
C.__fn["oneffectstart"] = function(self) rt.spawn_hazard(self) end
return C
