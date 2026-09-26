-- The Dual Value Modifier archetype: a Value Modifier on the MGEF's actor value, and on its second
-- one by the magnitude times its weight (w: frost's stamina 1.0, fire-and-forget shock's magicka 0.5).
local rt = require('skymod.rt')
local vm = rt.load("ArchetypeValueModifier").__effect.primary
local C = rt.class("ArchetypeDualValueModifier", nil)
C.__effect = {
  primary = vm,
  secondary = { capacity = "w * " .. vm.capacity, amount = "w * " .. vm.amount },
}
return C
