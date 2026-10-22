# Named ROOT-admitted RED/GREEN command only. Never included by test/runtests.jl.
using Test
using SHA
include("resident_direct_entry_support.jl")
const R = ResidentDirectEntrySandbox
include("resident_direct_entry_cases.jl")
