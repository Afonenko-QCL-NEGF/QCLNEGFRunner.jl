# Source-only SCI08-R2 fixtures. Not included in runtests until execution grant.
# Arithmetic oracle is handwritten; a true result is NOT a growth permit.
struct _ResidentFixtureAuthority <: QCLNEGFRunner.AbstractResidentAuthority end

@testset "authority unknown never releases capacity" begin
    authority = _ResidentFixtureAuthority()
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner.resident_snapshot(authority, :fake_binding)
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner.reserve_growth!(authority, 1, :fake_descriptor)
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner.materialize_growth!(authority, :fake_lease, 1, 40)
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner.commit_growth!(authority, :fake_lease, :unknown)
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner.release_unmaterialized!(authority, :fake_lease, :create_failed_unknown)
end

@testset "resident baseline arithmetic" begin
    # Literal independent oracle: E=100 includes duplicate=40. Only after an
    # independently proven deletion would E=60; no API here grants deletion.
    @test 100 - 40 == 60
    @test QCLNEGFRunner._resident_budget_predicate(100, 0, 0, 0, 100, 0)
    @test !QCLNEGFRunner._resident_budget_predicate(100, 1, 0, 0, 100, 1)
    @test !QCLNEGFRunner._resident_budget_predicate(60, 1, 0, 0, 100, 0)
    @test QCLNEGFRunner._resident_budget_predicate(60, 40, 0, 0, 100, 40)
    @test !QCLNEGFRunner._resident_budget_predicate(60, 40, 0, 1, 100, 40)
    @test !QCLNEGFRunner._resident_budget_predicate(0, 0, 0, 0, nothing, 0)
    @test !QCLNEGFRunner._resident_budget_predicate(0, 0, 0, 0, 0, nothing)
    @test !QCLNEGFRunner._resident_budget_predicate(typemax(Int), 1, 0, 0, typemax(Int), 1)
    @test !QCLNEGFRunner._resident_budget_predicate(0, true, 0, 0, 100, 100)
end

@testset "refusal is before mutation and carries unknown state" begin
    # Fake events never invoke FS; the callback is unreachable under strict.
    events = Symbol[]
    for operation in (:point, :operator, :stage, :history, :atomic_text,
                      :import_finally, :checkpoint_import_delete, :optical_finally,
                      :scratch_success_cleanup, :nested_finalizer)
        @test_throws QCLNEGFRunner.ResidentGrowthRefusal begin
            QCLNEGFRunner._resident_writer_preflight(:campaign_strict, operation)
            push!(events, :mutate)
        end
    end
    @test isempty(events)
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner._observability_atomic_text(
        "/unreachable-resident-fixture", io -> push!(events, :write);
        resource_policy=:campaign_strict)
    @test_throws QCLNEGFRunner.ResidentGrowthRefusal QCLNEGFRunner.stage_result_tree(
        "/unreachable-source", "/unreachable-target"; resource_policy=:campaign_strict)
    @test isempty(events)
    @test isnothing(QCLNEGFRunner._resident_writer_preflight(:standalone, :point))
end

# Nominal controls deliberately NOT asserted as implemented: parent/child permits,
# partial→next-growth denial on all four writers, atomic partial/create failure,
# pre/post-rename outcomes, protected/invalid generation, unlink unknown debt,
# deferred success cleanup→one-byte-short denial, primary/secondary finalizers.
# These require lifecycle/authority implementation, absent in this partial ticket.
