-- The Peak Value Modifier archetype moves its actor value like a Value Modifier; its no-stack
-- keyword is a stacking rule (worldstate/stacking.odin).
local rt = require('skymod.rt')
return rt.class("ArchetypePeakValueModifier", "ArchetypeValueModifier")
