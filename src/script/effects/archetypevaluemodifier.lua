-- The Value Modifier archetype (CK wiki, Magic Effect): the MGEF's actor value moves by the
-- magnitude. Held (Recover, or a lasting effect): on the capacity while it runs. Otherwise the
-- magnitude a second, all at once when the duration is 0, and then the taper; the change stays.
-- Pure formulas, so the engine runs it with no instance. A mod replaces it like any script.
-- (hole ability-value-modifier :tags magic :sev polish) a lasting Value Modifier without Recover (VampireAbSkills02) is held like a fortify; the CK says an unrecovered one applies every second, which for an ability would never stop. Unsourced either way.
local rt = require('skymod.rt')
local C = rt.class("ArchetypeValueModifier", nil)
C.__effect = { primary = {
  capacity = "sign * select(held, m, 0)",
  amount = "sign * select(held, 0, select(d, m * min(t, d), m) + select(td, m * tw * td / (tc + 1) * (1 - (1 - clamp(t - d, 0, td) / td) ^ (tc + 1)), 0))",
} }
return C
