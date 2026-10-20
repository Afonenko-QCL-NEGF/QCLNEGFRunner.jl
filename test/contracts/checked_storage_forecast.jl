module CheckedStorageForecastTests
include("../support/common.jl")
const R = QCLNEGFRunner
const M = typemax(Int)
const C = 16777216
forecast(ne, nk, nb, sizes = Int[], f = 0) =
    R._checkpoint_storage_forecast_bytes(ne, nk, nb, sizes, f)
# The oracle never invokes a production validator or forecast.
oracle(ne, nk, nb, sizes, f) = big(C) + 4 *
    (big(128) * ne * nk * nb * nb + sum(BigInt.(sizes); init = big(0)) + f)

@testset "F1 literal nontrivial forecast" begin
    @test forecast(2, 3, 5, [7, 11], 13) == 16854140
end
@testset "F2 empty and known zero kernels" begin
    @test forecast(1, 1, 1) == 16777728
    @test forecast(1, 1, 1, [0, 0], 0) == 16777728
end
@testset "F3 dimensions reject independently" begin
    for index in 1:3, bad in (true, 0, -1, 1.0, nothing, big(M) + 1)
        args = Any[1, 1, 1]
        args[index] = bad
        @test_throws ArgumentError forecast(args...)
    end
end
@testset "F4 kernel and F sizes reject independently" begin
    for bad in (true, -1, 1.0, nothing, big(M) + 1)
        @test_throws ArgumentError forecast(1, 1, 1, Any[bad], 0)
        @test_throws ArgumentError forecast(1, 1, 1, Int[], bad)
    end
end
@testset "F5 six isolated checked arithmetic boundaries" begin
    # Each chosen intermediate exceeds M, while its immediate operands fit Int.
    nb = isqrt(M) + 1
    @test big(nb) * nb > M
    @test_throws OverflowError forecast(1, 1, nb)
    ne = fld(M, 128) + 1
    @test big(128) * ne > M
    @test_throws OverflowError forecast(ne, 1, 1)
    @test big(M) + 1 > M
    @test_throws OverflowError forecast(1, 1, 1, [M, 1], 0)
    @test big(128) + (M - 127) > M
    @test_throws OverflowError forecast(1, 1, 1, [M - 127], 0)
    k_scale = fld(M, 4) - 128 + 1
    @test big(128) + k_scale <= M
    @test 4 * (big(128) + k_scale) > M
    @test_throws OverflowError forecast(1, 1, 1, [k_scale], 0)
    k_add = fld(M - C, 4) - 128 + 1
    scaled = 4 * (big(128) + k_add)
    @test scaled <= M
    @test big(C) + scaled > M
    @test_throws OverflowError forecast(1, 1, 1, [k_add], 0)
end
@testset "F6 adjacent representable boundary" begin
    k = fld(M - C, 4) - 128
    expected = oracle(1, 1, 1, [k], 0)
    @test expected <= M
    @test forecast(1, 1, 1, [k], 0) == expected
    @test oracle(1, 1, 1, [k + 1], 0) > M
    @test_throws OverflowError forecast(1, 1, 1, [k + 1], 0)
end
@testset "B1 exact budget fit" begin
    @test R._storage_budget_used(17, 25, 3, 5) == 17
end
@testset "B2 budget one byte short" begin
    @test_throws ArgumentError R._storage_budget_used(17, 24, 3, 5)
end
@testset "B3 known zero and already exhausted" begin
    @test R._storage_budget_used(0, 1, 0, 0) == 0
    @test_throws ArgumentError R._storage_budget_used(26, 25, 0, 0)
end
@testset "B4 malformed budget inputs before reader" begin
    for index in 1:4, bad in (true, -1, 1.0, nothing, big(M) + 1)
        args = Any[17, 25, 3, 5]
        args[index] = bad
        @test_throws ArgumentError R._storage_budget_used(args...)
    end
    @test_throws ArgumentError R._storage_budget_used(0, 0, 0, 0)
    reads = Ref(0)
    reader = paths -> (reads[] += 1; 17)
    for index in 1:3, bad in (true, -1, 1.0, nothing, big(M) + 1)
        args = Any[25, 3, 5]
        args[index] = bad
        @test_throws ArgumentError R._check_storage_budget(String[], args...; storage_reader = reader)
    end
    @test_throws ArgumentError R._check_storage_budget(String[], 0, 0, 0; storage_reader = reader)
    @test reads[] == 0
    @test R._check_storage_budget(String[], 25, 3, 5; storage_reader = reader) == 17
    @test reads[] == 1
end
@testset "B5 first and second addition overflow" begin
    @test_throws OverflowError R._storage_budget_used(M, M, 1, 0)
    @test_throws OverflowError R._storage_budget_used(M - 1, M, 1, 1)
end
@testset "D1 exact free capacity" begin
    @test R._storage_free_permit(25, 25) == 25
end
@testset "D2 one byte free capacity short" begin
    @test_throws ArgumentError R._storage_free_permit(24, 25)
end
@testset "D3 known zero and malformed free inputs" begin
    @test R._storage_free_permit(0, 0) == 0
    for index in 1:2, bad in (true, -1, 1.0, nothing, big(M) + 1)
        args = Any[25, 25]
        args[index] = bad
        @test_throws ArgumentError R._storage_free_permit(args...)
    end
end
@testset "D4 unavailable disk and validation before reader" begin
    reads = Ref(0)
    available = path -> (reads[] += 1; 25)
    for bad in (true, -1, 1.0, nothing, big(M) + 1)
        @test_throws ArgumentError R._check_storage_free("fake-only", bad; available_reader = available)
    end
    @test reads[] == 0
    @test R._check_storage_free("fake-only", 25; available_reader = available) == 25
    @test reads[] == 1
    @test_throws ArgumentError R._check_storage_free("fake-only", 0; available_reader = path -> nothing)
    @test_throws ErrorException R._check_storage_free("fake-only", 0; available_reader = path -> error("fixture disk unavailable"))
end
end
