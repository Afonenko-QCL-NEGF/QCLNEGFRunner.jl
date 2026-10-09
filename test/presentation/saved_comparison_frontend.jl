# run_group includes this file in its shared process. Keep the intrusive
# fixture syntax inert there: only a direct child invocation evaluates it.
let fixture_body = quote
using Test, SHA, QCLNEGFRunner
const R = QCLNEGFRunner
# Throwing backend adapters: an accidental compute entry is a test error and
# cannot execute numerical work. Capture wrapper counts before any IO/hash.
const backend_calls = Ref(0)
const source_calls = Ref(0)
const mutate_after_capture = Ref("")
@eval R begin
    function run_from_configuration(configuration::AbstractString; kwargs...)
        Main.backend_calls[] += 1
        error("unexpected compute: run_from_configuration")
    end
    function run_from_configuration(configuration::ResolvedRunConfiguration; kwargs...)
        Main.backend_calls[] += 1
        error("unexpected compute: run_from_configuration")
    end
    function build_configured_problem(configuration::ResolvedRunConfiguration)
        Main.backend_calls[] += 1
        error("unexpected compute: build_configured_problem")
    end
end
const HEADER = "temperature_K,voltage_per_period_V,current_A_per_m2,converged,status,scba_quality,outer_iterations,final_scba_iterations,metric_gain\n"
function fixture(dir; ref="70,0.048,10,false,not_converged,unresolved,1,1,3\n", cand="70,0.048,12,false,not_converged,unresolved,1,1,4\n", physics="p", changes="false", structure="s")
    write(joinpath(dir,"ref.csv"), HEADER*ref)
    write(joinpath(dir,"cand.csv"), HEADER*cand)
    path=joinpath(dir,"catalog.csv")
    write(path,"method_id,label,structure_id,physics_signature,modifies_physics,algorithm_family,summary_path\nref,Reference,s,p,false,direct_reference,ref.csv\ncand,Candidate,$structure,$physics,$changes,exact_optimized,cand.csv\n")
    path
end
function reason(prefix, f)
    err=try f(); nothing catch e; e end
    @test err isa ArgumentError
    @test err isa ArgumentError && startswith(err.msg,prefix)
end
@testset "saved comparison frontend" begin
    @test isdefined(R,:compare_saved_results)
    if isdefined(R,:compare_saved_results)
        @eval R function _saved_capture(path::String, remaining::Int)
            Main.source_calls[] += 1
            snapshot = invoke(_saved_capture,Tuple{Any,Any},path,remaining)
            if path == Main.mutate_after_capture[]
                write(path,"not a catalog anymore")
                Main.mutate_after_capture[] = ""
            end
            snapshot
        end
        mktempdir() do d
            path=fixture(d); out=joinpath(d,"analysis")
            before=Dict(p=>bytes2hex(sha256(read(p))) for p in (path,joinpath(d,"ref.csv"),joinpath(d,"cand.csv")))
            result=R.compare_saved_results(path,out;reference_id=:ref,temperature_atol=0,voltage_atol=0)
            row=only(filter(x->x.metric==:current_A_per_m2,result.comparison.rows))
            @test row.absolute_error==2
            @test row.relative_error==0.2
            @test !row.reference_converged && !row.candidate_converged
            @test result.analysis_status==:completed
            @test row.speedup===missing && row.memory_ratio===missing
            @test !occursin("Current-density accuracy",read(result.paths.markdown,String))
            @test all(bytes2hex(sha256(read(p)))==h for (p,h) in before)
            @test all(s.sha256==before[s.path] && s.byte_count==filesize(s.path) for s in result.source_snapshots)
            @test all(!hasproperty(s,:bytes) && hasproperty(s,:source_selectors) for s in result.source_snapshots)
            @test occursin("declared_saved_report",read(result.paths.markdown,String))
            @test occursin("unavailable",read(result.paths.markdown,String))
            # Mutating a toy source after capture cannot change what is parsed.
            mutate_after_capture[]=path
            frozen=R.compare_saved_results(path,out;reference_id=:ref)
            @test only(filter(x->x.metric==:current_A_per_m2,frozen.comparison.rows)).absolute_error==2
            @test first(frozen.source_snapshots).sha256==before[path]
            @test read(path,String)=="not a catalog anymore"
            fixture(d)
            for option in (:temperature_atol,:voltage_atol), value in (NaN,Inf,-Inf,-1,"bad",big"1e400")
                calls_before=source_calls[]
                reason("invalid_matching_tolerance",()->R.compare_saved_results("/does/not/exist.csv",joinpath(d,"invalid");reference_id=:ref,NamedTuple{(option,)}((value,))...))
                @test source_calls[]==calls_before
                @test backend_calls[]==0
                @test !ispath(joinpath(d,"invalid"))
            end
            reason("invalid_matching_tolerance",()->R.compare_saved_results(path,out;reference_id=:ref,temperature_atol=Inf,voltage_atol=Inf))
            reason("input_budget_exceeded",()->R.compare_saved_results(path,out;reference_id=:ref,maximum_input_bytes=1))
            reason("output_collision",()->R.compare_saved_results(path,d;reference_id=:ref))
            reason("unsupported_saved_input",()->R.compare_saved_results("plan.yaml",out;reference_id=:ref))
            @test R.main(["compare",path,joinpath(d,"cli"),"--reference-id","ref"])==0
            @test R.main(["compare",path,out,"--reference-id","ref","--temperature-atol","Inf"])==2
            @test R.main(["compare",path,out,"--reference-id","ref","--reference-id","ref"])==2
            fixture(d;ref="70,0.048,0,false,not_converged,unresolved,1,1,3\n",cand="70,0.048,2,false,not_converged,unresolved,1,1,4\n")
            z=R.compare_saved_results(path,out;reference_id=:ref)
            @test only(filter(x->x.metric==:current_A_per_m2,z.comparison.rows)).relative_error===missing
            fixture(d;physics="different")
            reason("incomparable_inputs",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d;physics="different",changes="true")
            @test all(x.modifies_physics for x in R.compare_saved_results(path,out;reference_id=:ref).comparison.rows)
            fixture(d;structure="different")
            reason("incomparable_inputs",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d;cand="700,1,12,false,not_converged,unresolved,1,1,4\n")
            reason("insufficient_data",()->R.compare_saved_results(path,out;reference_id=:ref,temperature_atol=0,voltage_atol=0))
            fixture(d;cand="70.0000000001,0.0480000000001,12,false,not_converged,unresolved,1,1,4\n")
            roundtrip=R.compare_saved_results(path,out;reference_id=:ref)
            @test only(roundtrip.matches).delta_temperature_K>0
            @test only(roundtrip.matches).delta_voltage_V>0
            fixture(d;cand="70,0.048,12,false,not_converged,unresolved,1,1,\n")
            partial=R.compare_saved_results(path,out;reference_id=:ref)
            @test partial.analysis_status==:partial
            @test any(x.reason==:missing_metric for x in partial.coverage)
            fixture(d;cand="70,0.048,NaN,false,not_converged,unresolved,1,1,4\n")
            partial=R.compare_saved_results(path,out;reference_id=:ref)
            @test partial.analysis_status==:partial
            @test any(x.reason==:nonfinite_metric for x in partial.coverage)
            @test occursin("NaN",read(partial.paths.points_csv,String))
            fixture(d;cand="70,0.048,NaN,false,not_converged,unresolved,1,1,NaN\n")
            reason("insufficient_data",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d;ref="70,0.048,10,false,not_converged,unresolved,1,1,3\n70,0.048,11,false,not_converged,unresolved,1,1,3\n")
            reason("ambiguous_points",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d;cand="70,0.048,12,false,not_converged,unresolved,1,1,4\n70.0000000001,0.048,13,false,not_converged,unresolved,1,1,4\n")
            reason("ambiguous_points",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d;ref="70,0.048,10,false,not_converged,unresolved,1,1,3\n80,0.05,10,false,not_converged,unresolved,1,1,3\n")
            partial=R.compare_saved_results(path,out;reference_id=:ref)
            @test partial.analysis_status==:partial
            @test any(x.reason==:unmatched_reference_point for x in partial.coverage)
            fixture(d)
            write(path,replace(read(path,String),"cand,Candidate"=>"ref,Candidate"))
            reason("incomparable_inputs",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d)
            write(path,join(first(split(read(path,String),'\n'),2),'\n')*"\n")
            reason("insufficient_data",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d); rm(joinpath(d,"cand.csv"))
            reason("insufficient_data",()->R.compare_saved_results(path,out;reference_id=:ref))
            fixture(d); write(joinpath(d,"cand.csv"),"temperature_K\n70\n")
            reason("insufficient_data",()->R.compare_saved_results(path,out;reference_id=:ref))
            # Hand source warnings and unsupported assessment fields are retained
            # in the captured bytes and never promoted into scientific acceptance.
            fixture(d)
            write(joinpath(d,"cand.csv"), "temperature_K,voltage_per_period_V,current_A_per_m2,converged,status,scba_quality,outer_iterations,final_scba_iterations,metric_gain,warnings_json,scientific_accepted,discretization_verified\n70,0.048,12,false,not_converged,unresolved,1,1,4,\"[{code: failed_physics, scope: point}]\",false,not_measured\n")
            warned=R.compare_saved_results(path,out;reference_id=:ref)
            @test only(warned.comparison.runs[2].points).warnings[1]["code"]=="failed_physics"
            @test occursin("failed_physics",read(warned.paths.points_csv,String))
            @test occursin("unavailable",read(warned.paths.markdown,String))
            # Real output-only coverage failure must not publish completed Markdown.
            fixture(d)
            io_fail_output=joinpath(d,"io-failure")
            mkpath(joinpath(io_fail_output,"comparison_coverage.csv"))
            err=try
                R.compare_saved_results(path,io_fail_output;reference_id=:ref)
                nothing
            catch error
                error
            end
            @test err isa SystemError || err isa Base.IOError
            final_report=joinpath(io_fail_output,"expert_report.md")
            @test !isfile(final_report) || !occursin("Analysis status: completed",read(final_report,String))
            @test !isfile(final_report) || !occursin("Analysis status: partial",read(final_report,String))
            @test backend_calls[]==0
        end
    end
end
end
    if abspath(PROGRAM_FILE) == @__FILE__
        # Evaluate top-level expressions sequentially so imports precede macros.
        for expression in fixture_body.args
            expression isa LineNumberNode && continue
            Core.eval(Main,expression)
        end
    else
        project = Base.active_project()
        project === nothing && error("saved comparison child requires an active project")
        command = Cmd(vcat(Base.julia_cmd().exec, [
            "--project=" * dirname(project),
            "--threads=$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))",
            "--startup-file=no", "--compiled-modules=existing", "--check-bounds=yes",
            @__FILE__,
        ]))
        # No shell, package setup, or numerical execution. One child inherits
        # the caller's depots/offline environment and allocated thread counts.
        maximum_output_bytes = 128 * 1024
        output = Pipe()
        captured = IOBuffer()
        exceeded = Ref(false)
        timed_out = false
        started = time_ns()
        process = run(pipeline(command; stdout=output,stderr=output); wait=false)
        close(output.in)
        reader = @async begin
            while !eof(output)
                bytes = read(output,4096)
                remaining = maximum_output_bytes - position(captured)
                write(captured,@view bytes[1:min(length(bytes),remaining)])
                if length(bytes) > remaining
                    exceeded[] = true
                    process_running(process) && kill(process)
                    break
                end
            end
        end
        try
            while process_running(process)
                if time_ns()-started >= 180 * 10^9
                    timed_out = true
                    kill(process)
                    break
                end
                if istaskfailed(reader)
                    kill(process)
                    break
                end
                sleep(0.05)
            end
            wait(process)
            wait(reader)
        finally
            process_running(process) && kill(process)
            close(output)
        end
        bytes = take!(captured)
        log_path, log_stream = mktemp(; cleanup=false)
        try
            write(log_stream,bytes)
        finally
            close(log_stream)
        end
        # Preserve the bounded full child log and keep shared-caller console
        # output small, including on a failure. No globals or Runner methods
        # were installed by this branch.
        println("[saved comparison child] log=$log_path bytes=$(length(bytes)) threads=$(Threads.nthreads(:default)),$(Threads.nthreads(:interactive))")
        write(stdout,@view bytes[1:min(length(bytes),8192)])
        timed_out && error("saved comparison child exceeded 180 s; log=$log_path")
        exceeded[] && error("saved comparison child exceeded 128 KiB output; log=$log_path")
        success(process) || error("saved comparison child failed; log=$log_path")
    end
end
