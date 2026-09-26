# Application composition only: no queue, filesystem, environment probe, optional
# HDF5 or convergence-policy changes. PrecompileTools persists generated methods
# while Julia builds its package image; this code is not run at ordinary import.
using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    physical = reference_parameters(F_bias = 0u"V/m")
    numerical = tutorial_numerics()
    scattering = ScatteringOptions(
        LO = false,
        acoustic = false,
        impurity = false,
        IFR = false,
        alloy = false,
    )
    @compile_workload begin
        problem = build_problem(; physical, numerical, scattering)
        hamiltonian = project_hamiltonians(problem, zeros(numerical.N_z))
        sigma =
            zeros(ComplexF64, numerical.N_E, numerical.N_k, numerical.N_b, numerical.N_b)
        for e in axes(sigma, 1), k in axes(sigma, 2), b in axes(sigma, 3)
            sigma[e, k, b, b] = -0.01im
        end
        green, _ = retarded_green(problem.grids.ε, hamiltonian, sigma)
        spectral_function(green)
    end
end
