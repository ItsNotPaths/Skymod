-- The Absorb archetype: a Value Modifier on the target, and the same the other way on the caster
-- (not Detrimental: the caster loses, the target gains).
-- (hole absorb-cap :tags magic :sev polish) Absorb gives the caster the full amount even when the target had less; the CK says "by the amount of damage done". Wanted: av_gain returns what it changed after clamping, and the caster half takes that.
local rt = require('skymod.rt')
local vm = rt.load("ArchetypeValueModifier").__effect.primary
local C = rt.class("ArchetypeAbsorb", nil)
C.__effect = {
  primary = { amount = vm.amount },
  caster = { primary = { amount = "-(" .. vm.amount .. ")" } },
}
return C
