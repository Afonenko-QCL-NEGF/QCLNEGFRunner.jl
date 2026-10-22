# Only test adapters live here. Owning production files are included WHOLE below.
# No package import, VERSION patch, AST rewriting or copied production method body.
module ResidentDirectEntrySandbox
using SHA
const SOURCE_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const EVENTS = Any[]
const STREAM_PATHS = IdDict{IO,String}()
const FS_HOOK = Ref{Function}((kind, args...) -> nothing)
event(kind, args...) = (push!(EVENTS, (kind, args...)); FS_HOOK[](kind, args...))

# Module-local FS adapters forward to Base. Faults are before/after explicit
# primitives; actual writer catch/finally/publication bodies remain untouched.
function mkpath end
function mktemp end
function mktempdir end
function open end
function write end
function close end
function chmod end
function rm end
function mkpath(path; kwargs...)
    event(:mkdir_before, String(path))
    value = Base.mkpath(path; kwargs...)
    event(:mkdir_after, String(path))
    return value
end
function mktemp(parent; kwargs...)
    event(:temp_before, String(parent))
    path, stream = Base.mktemp(parent; kwargs...)
    STREAM_PATHS[stream] = path
    event(:temp_after, path)
    return path, stream
end
function mktempdir(parent; kwargs...)
    event(:tempdir_before, String(parent))
    path = Base.mktempdir(parent; kwargs...)
    event(:tempdir_after, path)
    return path
end
function open(f::Function, path::AbstractString, args...; kwargs...)
    event(:open_before, String(path), args)
    return Base.open(path, args...; kwargs...) do stream
        STREAM_PATHS[stream] = String(path)
        f(stream)
    end
end
function write(stream::IO, args...)
    value = Base.write(stream, args...)
    event(:write_after, get(STREAM_PATHS, stream, "unknown"))
    return value
end
function close(stream::IO)
    Base.close(stream)
    event(:close_after, get(STREAM_PATHS, stream, "unknown"))
    return nothing
end
function chmod(path, mode)
    event(:chmod_before, String(path), mode)
    Base.chmod(path, mode)
end
function rm(path; kwargs...)
    event(:delete, String(path))
    Base.rm(path; kwargs...)
end

# Tiny typed payloads satisfy source signatures, never numerical equations.
struct NEGFSolution
    observables::Dict{Symbol,Any}
    scba::NamedTuple
    status::Symbol
    problem::NamedTuple
end
struct FaultJSON
    cause::Exception
end
const JSON_FAULT_HOOK = Ref{Function}(() -> nothing)
Base.string(value::FaultJSON) = (JSON_FAULT_HOOK[](); throw(value.cause))
struct SCBAIteration end
struct OuterIteration end
struct NEGFProblem end
struct ScientificPlan end
struct ExecutionEnvelope end
const _CHECKPOINT_SCHEMA_VERSION = 4
const _RESULT_CONTRACT_SET = "handwritten-fixture-only"
const _SERIALIZATION_SLAB_BYTES = 1048576
const PAYLOAD_HOOK = Ref{Function}((path, stream) -> nothing)

# TEST ONLY: allow whole-source macro expansion without Unitful. The expanded
# expression always throws IF a scientific unit branch is actually executed.
macro u_str(literal)
    message = "TEST-ONLY SCI08 unit literal reached scientific branch: " * string(literal)
    return :(throw(ErrorException($message)))
end
unit_literal_guard_control() = u"A/m^2"

# TEST ONLY lower-time bindings for the whole point_artifacts.jl include.
# H5L_info_t below is NOT an ABI representation. No HDF5 library is imported
# or loaded. Any visit that could reach its ccall must first take liblock,
# whose method throws. The impossible library path is a second fail-closed
# barrier even if a compiler tried to resolve that dead native branch early.
module HDF5
module API
const herr_t = Cint
const hid_t = Int64
struct H5L_info_t
    linktype::Cint
    u::UInt64
end
struct ForbiddenNativeLock end
const liblock = ForbiddenNativeLock()
Base.lock(::ForbiddenNativeLock) = error("TEST-ONLY SCI08 native HDF5 branch forbidden")
Base.unlock(::ForbiddenNativeLock) = error("TEST-ONLY SCI08 native HDF5 branch forbidden")
const libhdf5 = "/dev/null/SCI08_TEST_ONLY_HDF5_FORBIDDEN"
const H5P_DEFAULT = hid_t(0)
const H5L_TYPE_HARD = Cint(0)
h5p_get_external_count(args...) = error("TEST-ONLY SCI08 native HDF5 properties forbidden")
end
abstract type Group end
abstract type Dataset end
get_create_properties(args...) = error("TEST-ONLY SCI08 native HDF5 properties forbidden")
end
hdf5_guard_control() = Base.lock(HDF5.API.liblock)

module QCLExecutionPolicy
_grant_integer(x, label; minimum=0) =
    x isa Integer && !(x isa Bool) && x >= minimum ? Int(x) : throw(ArgumentError(label))
end
include(joinpath(SOURCE_ROOT, "src/infrastructure/resources/resident_storage.jl"))
include(joinpath(SOURCE_ROOT, "src/infrastructure/persistence/atomic_files.jl"))
include(joinpath(SOURCE_ROOT, "src/infrastructure/telemetry/progress.jl"))
include(joinpath(SOURCE_ROOT, "src/infrastructure/persistence/light_results.jl"))
include(joinpath(SOURCE_ROOT, "src/application/contracts.jl"))
include(joinpath(SOURCE_ROOT, "src/infrastructure/persistence/point_artifacts.jl"))
include(joinpath(SOURCE_ROOT, "src/infrastructure/persistence/scientific_history.jl"))
include(joinpath(SOURCE_ROOT, "src/composition/scratch_execution.jl"))

# TEST ONLY availability INPUT for paths in the bound tiny fixture tree.
# This finite literal exceeds the real R1 forecast floor; it is NOT measured
# filesystem capacity or native admission. The production forecast/predicates
# remain unchanged, and Root's actual tmpfs hard cap remains 16MiB.
function _storage_available(path::String)
    scope = get(ENV, "SCI08_CASE_ROOT", "")
    isempty(scope) && error("TEST-ONLY availability requires bound fixture root")
    isabspath(scope) || error("TEST-ONLY availability requires absolute fixture root")
    root = normpath(scope)
    target = abspath(path)
    (target == root || startswith(target,root*string(Base.Filesystem.path_separator))) ||
        error("TEST-ONLY synthetic availability denied outside fixture tree")
    return 33554432 # Literal FAKE FS input, not diskstat or a storage grant.
end

# Handwritten dependency doubles: NO estimate/ledger implementation is copied.
# They stop at a tiny partial payload; actual HDF5/schema/durability not proven.
_bound_final_audit(::NEGFSolution, identity; final_state=false) = nothing
solution_scientific_assessment(::NEGFSolution) = Dict{String,Any}()
function _write_checkpoint(path, ::NEGFSolution; kwargs...)
    open(path, "w") do stream
        write(stream, "literal partial fixture payload")
        PAYLOAD_HOOK[](path, stream)
    end
    return path
end
# Actual history flush reaches this fake serializer then its real catch/finally.
function h5open(f::Function, path, mode)
    open(path, mode) do stream
        write(stream, "literal partial history rows")
        PAYLOAD_HOOK[](path, stream)
        error("HDF5 body intentionally outside focused harness")
    end
end

mutable struct Authority <: AbstractResidentAuthority
    events::Vector{Any}
    snapshot::StorageSnapshot
    writer_hook::Function
    identity_hook::Function
    settle_hook::Function
end
resident_snapshot(a::Authority, binding) = a.snapshot
resident_monotonic_ns(::Authority) = UInt64(15)
validate_resident_binding!(::Authority, snapshot, descriptor) = true
function reserve_growth!(a::Authority, revision, descriptor)
    push!(a.events, (:reserve, revision, descriptor.digest))
    ResidentLeaseProof("literal-lease", revision, descriptor.digest)
end
function validate_resident_writer!(a::Authority, descriptor, writer, path, payload)
    push!(a.events, (:validate, writer, path))
    a.writer_hook(writer, path, payload)
end
resident_created_identity(a::Authority, domain, path) = a.identity_hook(path)
function materialize_growth!(a::Authority, lease, seq, delta)
    push!(a.events, (:materialize, seq, delta))
end
function commit_growth!(a::Authority, lease, evidence)
    push!(a.events, (:commit, evidence)); a.settle_hook(:commit)
end
function release_unmaterialized!(a::Authority, lease, evidence)
    push!(a.events, (:release, evidence)); a.settle_hook(:release)
end

function fixture(parent, writer; slots=(), logical=8192)
    id = ResidentIdentity("campaign", "plan", "run", "attempt", "point", "source", "admission", "operation", 1)
    domain = StorageDomain("fixture-fs", "fixture-ns", "fixture-boot", "fixture-owner", abspath(parent), "binding")
    children = Tuple(StorageOperationInventory(id, domain, name, "slot-$(i)", "payload", "stop", 1024,1024,1,()) for (i,name) in enumerate(slots))
    descriptor = StorageOperationInventory(id, domain, writer, "literal-root", "payload", "stop", logical,logical,16,children)
    snapshot = StorageSnapshot(id, domain, "revision",10,20,
        (64,64,0),(0,0,0),(0,0,0),(0,0,0),(65536,65536,100),(32768,32768,100),"inventory","epoch")
    a = Authority(Any[], snapshot, (writer,path,payload)->true, path->"fixture-object:"*path, kind->nothing)
    return a, reserve_storage_operation(a, descriptor)
end
solution() = NEGFSolution(Dict{Symbol,Any}(:restart_contract=>:fixture), (restart_contract=:fixture,), :completed,
    (numerical=(N_E=1,N_k=1,N_b=1), kernels=(K=Dict{Symbol,Any}(),Fᴸᴼ=UInt8[])))
function recorder(parent)
    ScientificHistoryRecorder(parent, Dict{String,Any}(), Ref(1), Ref(0),
        [(1,1,SCBAIteration())], Tuple{Int,OuterIteration}[], 0, "fixture-problem",
        Dict{String,Any}[], 0,0,UInt64(1),UInt64(0),()->UInt64(15),nothing)
end
function reset_hooks!()
    FS_HOOK[] = (kind,args...)->nothing
    PAYLOAD_HOOK[] = (path,stream)->nothing
    JSON_FAULT_HOOK[] = ()->nothing
    empty!(EVENTS); empty!(STREAM_PATHS)
end
end # module
