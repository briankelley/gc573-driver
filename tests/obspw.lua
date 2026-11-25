-- SPDX-License-Identifier: GPL-2.0
-- WirePlumber 0.4 rule for tests/live.sh obspw, installed in the VM as
-- ~/.config/wireplumber/main.lua.d/51-gc573-obspw.lua for the step and
-- removed after it. In a virtual machine WirePlumber gives every ALSA node
-- 8192 frames of headroom (vm.node.defaults in 50-alsa-config.lua). This
-- rule takes it off the GC573's capture node, as on bare metal.
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "matches", "alsa_input.pci-0000_07_00.0.*" } } },
  apply_properties = { ["api.alsa.headroom"] = 0 },
})
