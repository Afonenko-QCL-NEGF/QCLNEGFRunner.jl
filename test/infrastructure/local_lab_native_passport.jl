module LocalLabNativePassport
# Native publication only: seeded fields, no SCBA/Poisson iteration or history.
using Test, HDF5, YAML, Unitful
include("../../tools/local_lab_acceptance.jl")
const Lab = LocalLabAcceptance
Lab.load_runtime()
const R = Lab.QCLNEGFRunner

@testset "Native storage HDF5, model and frozen plan share one passport" begin
    mktempdir() do workspace
        output = joinpath(workspace,"native")
        Lab.native(output)
        plan = R.load_scientific_plan(joinpath(output,"scientific_plan.json"))
        configuration = only(plan.executions).configuration
        marker = YAML.load_file(joinpath(output,"native-evidence.json"))
        commit_path = joinpath(output,marker["commit_path"])
        commit = R.verify_point_artifacts(commit_path)
        raw_model = R.load_resolved_configuration_envelope(joinpath(dirname(commit_path),"resolved_configuration.json"))
        model_path = joinpath(workspace,"model.yaml")
        YAML.write_file(model_path,raw_model)
        model = R.load_run_configuration(model_path)
        # Compare complete typed input objects, including nested convergence policy.
        function same_fields(left,right)
            typeof(left) == typeof(right) || return false
            left isa AbstractArray && return size(left) == size(right) && all(same_fields.(left,right))
            left isa AbstractDict && return left == right
            isstructtype(typeof(left)) && !isempty(fieldnames(typeof(left))) &&
                !(left isa Number || left isa AbstractString) && return all(
                    same_fields(getfield(left,f),getfield(right,f)) for f in fieldnames(typeof(left)))
            return isequal(left,right)
        end
        for field in (:physical,:numerical,:scattering,:scales,:solver,:physical_models)
            @test same_fields(getfield(configuration,field),getfield(model,field))
        end
        configured = R.build_configured_problem(configuration)
        seed = Lab.native_physics_fixture(;problem=configured.problem,options=configuration.solver)
        @test seed.problem === configured.problem
        @test seed.options === configuration.solver
        @test same_fields(seed.problem.physical,configuration.physical)
        @test same_fields(seed.problem.numerical,configuration.numerical)
        @test same_fields(seed.problem.scattering,configuration.scattering)
        @test isempty(seed.scba.history) && isempty(seed.outer_history)
        h5open(joinpath(dirname(commit_path),"physics.h5"),"r") do file
            options = R.solver_options(configuration)
            for field in fieldnames(typeof(options.tolerances))
                @test read(file["numerical_inputs/tolerances/" * String(field)]) == getfield(options.tolerances,field)
            end
            for (name,value) in (("alpha_Sigma",options.α_Σ),("alpha_Poisson",options.α_P),
                ("max_scba",options.max_scba),("max_poisson",options.max_poisson),
                ("energy_tail_window_fraction",options.energy_tail_window_fraction),
                ("momentum_tail_window_fraction",options.momentum_tail_window_fraction))
                @test read(file["numerical_inputs/" * name]) == value
            end
            for field in fieldnames(typeof(configuration.scattering))
                @test Bool(read(file["numerical_inputs/scattering_" * String(field)])) == getfield(configuration.scattering,field)
            end
            n = configuration.numerical
            for (name,value) in (("Nz",n.N_z),("Nb",n.N_b),("P_basis",n.P_basis),("NE",n.N_E),
                ("Nk",n.N_k),("Nphi",n.N_φ),("Nqz",n.N_qz),("E_min_eV",ustrip(u"eV",n.E_min)),
                ("E_max_eV",ustrip(u"eV",n.E_max)),("M_E_eV",ustrip(u"eV",n.M_E)),
                ("k_max_per_m",ustrip(u"m^-1",n.k_max)),("qz_max_per_m",ustrip(u"m^-1",n.qz_max)),
                ("eta_seed_eV",ustrip(u"eV",n.η_seed)))
                @test read(file["numerical_inputs/" * name]) == value
            end
            p = configuration.physical
            for (name,value) in (("T_L_K",ustrip(u"K",p.Tᴸ)),("T_LO_K",ustrip(u"K",p.Tᴸᴼ)),
                ("F_bias_V_per_m",ustrip(u"V/m",p.F_bias)),("V_period_V",ustrip(u"V",p.F_bias * R.period_length(p))),
                ("layer_thickness_m",ustrip.(u"m",[l.d for l in p.layers])),
                ("layer_Ec_eV",ustrip.(u"eV",[l.Eᶜ for l in p.layers])),
                ("layer_mz_relative",[l.mᶻᵣ for l in p.layers]),("layer_mparallel_relative",[l.m_parallelᵣ for l in p.layers]),
                ("layer_epsilon_relative",[l.εᵣ for l in p.layers]),("layer_x_Al",[l.x_Al for l in p.layers]),
                ("layer_doped",Int8[l.doped for l in p.layers]),("interface_m",ustrip.(u"m",p.interfaces)))
                @test read(file["inputs/" * name]) == value
            end
        end
        @test marker["solver_executed"] === false
        @test commit["scientific_accepted"] === false
    end
end
end # module LocalLabNativePassport
