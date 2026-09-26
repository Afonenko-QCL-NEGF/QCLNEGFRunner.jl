include("run_group.jl")
groups = isempty(ARGS) ? TEST_GROUPS : Tuple(ARGS)
length(unique(groups)) == length(groups) || error("duplicate test groups")
all(group -> group in TEST_GROUPS, groups) || error("unknown test group")
@testset verbose=true "QCLNEGFRunner" begin
    for group in groups
        run_test_group(group)
    end
end
