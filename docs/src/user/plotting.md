# Plotting and reports

Load CairoMakie in the same Julia environment to activate the optional plotting
extension. The core numerical package has no plotting dependency.

```julia
using QCLNEGF
using QCLNEGFRunner
using CairoMakie
```

Band profiles, spectral maps, current spectra and convergence plots help diagnose a
solution. Plot labels and units refer to the saved or supplied scientific state.
Keep unconverged and unavailable quantities visibly distinguished. A plot cannot
replace conservation checks, eigenvalue tests for positive semidefiniteness, or
comparison across independently refined grids.

The [physical atlas](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/main/docs/src/tutorials/physical-atlas.md)
explains the physical functions using labelled analytic and coordinate-model
illustrations. Those illustrations do not establish device-level experimental agreement.
