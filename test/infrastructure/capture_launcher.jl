module CaptureLauncherTests
using Test

@testset "Public capture composition preserves one internal solver and argv" begin
    mktempdir() do root
        solver = joinpath(root, "internal solver")
        capture = joinpath(root, "capture")
        marker = joinpath(root, "calls")
        args = joinpath(root, "args")
        write(solver, "#!/bin/sh\nprintf 'solver\\n' >> \"\$CALLS\"\nprintf '%s\\n' \"\$@\" > \"\$ARGS_FILE\"\nprintf '%s' \"\${QCL_NEGF_CAPTURE_SPEC-unset}\" > \"\$CAPTURE_ENV\"\nexit 7\n")
        write(capture, """#!/bin/sh
            printf 'capture\\n' >> "\$CALLS"
            test "\$1" = capture-run; shift
            test "\$1" = --spec; shift 2
            test "\$1" = --solver; solver="\$2"; shift 2
            test "\$1" = --; shift
            exec "\$solver" "\$@"
            """)
        chmod(solver, 0o700); chmod(capture, 0o700)
        template = read(joinpath(@__DIR__, "..", "..", "nix", "launcher.sh"), String)
        launcher = joinpath(root, "public")
        write(launcher, replace(template, "@bash@"=>"/bin/sh", "@solver@"=>solver, "@capture@"=>capture))
        chmod(launcher, 0o700)
        capture_env=joinpath(root,"capture-env")
        env = merge(Dict(ENV), Dict("CALLS"=>marker, "ARGS_FILE"=>args,"CAPTURE_ENV"=>capture_env, "QCL_NEGF_CAPTURE_SPEC"=>"spec with spaces.json"))
        p = run(ignorestatus(setenv(`$launcher run-plan plan.json result --execution-id E`, env)))
        @test p.exitcode == 7
        @test readlines(marker) == ["capture", "solver"]
        @test readlines(args) == ["run-plan", "plan.json", "result", "--execution-id", "E"]
        @test read(capture_env,String)=="spec with spaces.json"
        rm(marker)
        p = run(ignorestatus(setenv(`$launcher plan config.yaml`, env)))
        @test p.exitcode == 7 && readlines(marker) == ["solver"]
        @test read(capture_env,String)=="unset"
        rm(marker); rm(capture)
        p = run(ignorestatus(setenv(`$launcher run-plan plan.json result`, env)))
        @test p.exitcode == 7 && readlines(marker) == ["solver"]
        @test read(capture_env,String)=="unset"
    end
end
end
