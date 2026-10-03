function native_physics_fixture(; energy_nodes = 513, problem = nothing, options = tutorial_options())
    if problem === nothing
        base=tutorial_numerics()
        changes=(N_z = 25, N_b = 2, N_E = energy_nodes, N_k = 3, N_qz = 9, N_φ = 8)
        numerical=NumericalParameters(;
            (
                field=>(
                    hasproperty(changes, field) ? getproperty(changes, field) :
                    getfield(base, field)
                ) for field in fieldnames(NumericalParameters)
            )...,
        )
        problem=build_problem(;
            numerical,
            scattering = ScatteringOptions(
                LO = false,
                acoustic = false,
                impurity = false,
                IFR = false,
                alloy = false,
            ),
        )
    end
    numerical=problem.numerical
    U=zeros(numerical.N_z)
    green, _=QCLNEGFRunner._seed_green(problem, project_hamiltonians(problem, U))
    embedding, plus, minus=embedding_self_energy(problem, green)
    scba=SCBAResult(
        green,
        Dict{Symbol,SelfEnergyFamily}(),
        embedding,
        plus,
        minus,
        SCBAIteration[],
        false,
        :fixture,
        :unresolved,
    )
    return NEGFSolution(
        problem,
        options,
        U,
        QCLNEGFRunner._electron_density_bar(problem, green.Gˡ),
        scba,
        OuterIteration[],
        Dict{Symbol,Any}(:warnings=>[Dict("code"=>"NATIVE_FIXTURE", "scope"=>"point")]),
        ConvergenceReport(
            false,
            Dict{Symbol,Float64}(),
            ["Storage fixture, no convergence claim"],
        ),
        false,
        :fixture,
    )
end
