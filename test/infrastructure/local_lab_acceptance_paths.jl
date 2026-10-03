# Pure path guards; no QCL package loading, solver, HDF5 or environment setup.
using Test
include("../../tools/local_lab_acceptance.jl")
const LabAcceptance = LocalLabAcceptance
@testset "Acceptance never adopts an existing or symlinked output tree" begin
    mktempdir() do root
        fresh = joinpath(root, "fresh")
        @test LabAcceptance.fresh_output(fresh) == fresh
        @test_throws ArgumentError LabAcceptance.fresh_output(root)
        @test_throws ArgumentError LabAcceptance.fresh_output("relative-output")
        @test_throws ArgumentError LabAcceptance.fresh_output(joinpath(root, "x", "..", "fresh"))
        owned = joinpath(root, "owned")
        mkdir(owned)
        symlink(owned, joinpath(root, "link"))
        @test_throws ArgumentError LabAcceptance.fresh_output(joinpath(root, "link", "new"))
        write(joinpath(owned, "plan.json"), "original")
        @test LabAcceptance.contained_file(owned, "plan.json") == joinpath(owned, "plan.json")
        @test_throws ArgumentError LabAcceptance.contained_file(owned, "../outside")
        symlink(joinpath(owned, "plan.json"), joinpath(owned, "alias.json"))
        @test_throws ArgumentError LabAcceptance.contained_file(owned, "alias.json")
        @test read(joinpath(owned, "plan.json"), String) == "original"
    end
end
@testset "CLI rejects unknown modes and incomplete arguments before runtime loading" begin
    @test_throws ArgumentError LabAcceptance.validate_arguments(["native"])
    @test_throws ArgumentError LabAcceptance.validate_arguments(["unknown", "/tmp/output"])
    @test_throws ArgumentError LabAcceptance.validate_arguments(["resume", "/tmp/plan", "/tmp/prior"])
    @test LabAcceptance.validate_arguments(["native", "/tmp/output"])[1] == "native"
end
@testset "Admission protects portable inputs and staging evidence before package load" begin
    mktempdir() do root
        input = joinpath(root,"input")
        mkdir(input)
        output = joinpath(root,"output")
        @test LabAcceptance.preflight("resume",[input,input,output]) === nothing
        mkdir(output * ".portable-input")
        @test_throws ArgumentError LabAcceptance.preflight("resume",[input,input,output])
        @test !ispath(output)
        write(output * ".staging-evidence.json","foreign")
        @test_throws ArgumentError LabAcceptance.preflight("staging",[input,output])
        @test read(output * ".staging-evidence.json",String) == "foreign"
        @test_throws ArgumentError LabAcceptance.main(["native",input])
        @test !isdefined(LabAcceptance,:QCLNEGFRunner)
    end
end
