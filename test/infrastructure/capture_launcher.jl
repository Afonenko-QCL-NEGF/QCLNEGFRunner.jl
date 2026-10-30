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

@testset "Native paired wrapper keeps literal argv, clears both markers on fallback" begin
    mktempdir() do root
        solver=joinpath(root,"internal solver"); capture=joinpath(root,"capture")
        launcher=joinpath(root,"public"); calls=joinpath(root,"calls")
        args=joinpath(root,"args"); native=joinpath(root,"native")
        environment=joinpath(root,"environment")
        write(solver,"""#!/bin/sh
            printf 'solver\\n' >> "\$CALLS"
            printf '%s\\0' "\$@" > "\$ARGS_FILE"
            printf '%s\\n%s' "\${QCL_NEGF_CAPTURE_SPEC-unset}" "\${QCL_NEGF_NATIVE_CAPTURE_INPUT-unset}" > "\$ENV_FILE"
            if [ "\${SENTINEL_SIGNAL-}" = yes ]; then kill -TERM \$\$; fi
            exit 7
            """)
        write(capture,"""#!/bin/sh
            set -eu
            printf 'capture\\n' >> "\$CALLS"
            test "\$1" = capture-run; shift
            test "\$1" = --spec; shift 2
            test "\$1" = --solver; solver="\$2"; shift 2
            if [ "\${1-}" = --native-execution ]; then printf '%s' "\$2" > "\$NATIVE_FILE"; shift 2; fi
            test "\$1" = --; shift
            exec "\$solver" "\$@"
            """)
        chmod(solver,0o700); chmod(capture,0o700)
        template=read(joinpath(@__DIR__,"..","..","nix","launcher.sh"),String)
        write(launcher,replace(template,"@bash@"=>"/bin/sh","@solver@"=>solver,"@capture@"=>capture));chmod(launcher,0o700)
        env=merge(Dict(ENV),Dict("CALLS"=>calls,"ARGS_FILE"=>args,"NATIVE_FILE"=>native,"ENV_FILE"=>environment,
            "QCL_NEGF_CAPTURE_SPEC"=>"spec with spaces.json","QCL_NEGF_NATIVE_CAPTURE_INPUT"=>"native input 'quoted'.json"))
        argv=["run-plan","plan.json",joinpath(root,"jobs native","result 'quoted'"),"--execution-id","E","--source-graph","source-graph.json"]
        p=run(ignorestatus(setenv(Cmd(vcat([launcher],argv)),env)))
        @test p.exitcode==7 && readlines(calls)==["capture","solver"]
        @test read(args)==Vector{UInt8}(codeunits(join(argv,'\0')*'\0'))
        @test isfile(native) && read(native,String)=="native input 'quoted'.json"
        @test read(environment,String)=="spec with spaces.json\nnative input 'quoted'.json"
        rm(calls)
        p=run(ignorestatus(setenv(Cmd(vcat([launcher],argv)),merge(env,Dict("SENTINEL_SIGNAL"=>"yes")))))
        @test p.termsignal==15 && readlines(calls)==["capture","solver"]
        rm(calls);rm(native;force=true)
        p=run(ignorestatus(setenv(`$launcher plan config.yaml`,env)))
        @test p.exitcode==7 && readlines(calls)==["solver"]
        @test read(environment,String)=="unset\nunset" && !isfile(native)
        rm(calls)
        p=run(ignorestatus(setenv(Cmd(vcat([launcher],argv)),merge(env,Dict("QCL_NEGF_CAPTURE_SPEC"=>"")))))
        @test p.exitcode==7 && readlines(calls)==["solver"]
        @test read(environment,String)=="unset\nunset"
        rm(calls);rm(capture)
        p=run(ignorestatus(setenv(Cmd(vcat([launcher],argv)),env)))
        @test p.exitcode==7 && readlines(calls)==["solver"]
        @test read(environment,String)=="unset\nunset"
        # Once capture owns dispatch, an uncertain failure must never retry science.
        rm(calls);write(capture,"#!/bin/sh\nprintf 'capture\\n' >> \"\$CALLS\"\nexit 73\n");chmod(capture,0o700)
        p=run(ignorestatus(setenv(Cmd(vcat([launcher],argv)),env)))
        @test p.exitcode==73 && readlines(calls)==["capture"]
    end
end

end
