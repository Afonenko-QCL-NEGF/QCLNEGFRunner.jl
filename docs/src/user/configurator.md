# Bounded configurator preview

`qcl-negf configure --catalog-root ROOT --catalog-source-id ID` reads one strict JSON object from
stdin and writes one JSON response to stdout. `--catalog` as the last argument lists the trusted
catalog without reading stdin. Both commands return status 0 for `status: available`, 2 for
`status: error`. These operations resolve metadata; they never admit, submit, recover or solve a
run.

ROOT is the immutable Research checkout, selected by the caller's trusted release configuration; ID
is its exact source identity (1–256 portable characters). Neither comes from a web request. The
fixed asset is `config/configurator-catalog.json`:

```json
{
  "schema": "qcl-negf-configurator-catalog-v1",
  "templates": [
    {
      "id": "example",
      "name": "Example",
      "study": "config/studies/example.yaml",
      "model": { "name": "Model", "path": "config/model/model.yaml" },
      "protocol": { "name": "Protocol", "path": "config/policies/policy.yaml" },
      "description": "An authored candidate, not scientific acceptance"
    }
  ]
}
```

All fields are required and unknown fields are rejected. IDs must be unique; there are 1–32 entries.
The catalog response contains `status`, `catalog_source_id`, and `templates`. Each entry includes
`study_sha256`, `model.sha256`, `protocol.sha256`, and `protocol.version` equal to exact
`ID:protocol.path`. Digests are computed from captured bytes. This asset is a small allowlist, not
an independently maintained revision lock.

A preview request has `mode`, `template_id`, `catalog_source_id`, and exactly one payload: `fields`
for `form`, or original UTF-8 `yaml` for `yaml`. Full YAML uses the existing complete
`qcl-negf-study-v2` grammar and resolver. The sources are relative to the selected study's
directory; normalized realpaths must remain inside ROOT and match the selected model or protocol
file. Order is preserved. Absolute output directories, absolute/foreign source paths, symlink
escape, meta/select/includes and uploaded files are refused. The existing `plan` command retains its
broader local-file contract.

The finite form fields are `temperature_K`, `voltage_per_period_mV`, `voltage_mode` (`independent`
or `strict`), `scba_to_poisson` (existing policy names), and `variant`. Each is optional. Values are
typed, with no string-number coercion. `variant` appends one existing grammar variant with required
`id`, `comparison_kind`, `controlled_paths`, `overrides`, and optional `method_id`. Grid changes
belong in the variant's explicit numerical overrides and controlled paths. Existing variant
validation remains authoritative. Form edits preserve all unspecified template leaves. YAML remains
authoritative; `short_form` reports `lossless: true` only for exact template equivalence, otherwise
it returns `authoritative_yaml_requires_preservation`. Clients retain original YAML bytes; the
returned semantic `draft_yaml` is not an authored-byte archive.

An available preview response contains:

- `draft_sha256`: exact input request UTF-8 bytes; form/YAML hashes differ.
- `semantic_draft_sha256`: existing canonical-byte encoding of the complete semantic draft,
  replacing ordered source spellings by logical source identities
  `source-ID digest + catalog-relative path + file digest`. The frozen assigning-source labels live
  under virtual `/@qcl-configurator/`; they are logical locators, never temporary files. A form and
  its returned YAML have identical labels and frozen plan in a fixed source/hardware fixture. This
  does not change v2 identity.
- `catalog_source_id`, `template`, `draft_yaml`, `short_form`, and `variant_diffs` (`id`,
  `comparison_kind`, `controlled_paths`, complete explicit `overrides`).
- `resolved_inputs`: execution ID, complete validated merged `configuration`, ordered leaf
  `assigning_sources` histories. Missing history remains missing.
- `effective_defaults`: execution ID and finite owning `sections` projections. `point_sections`
  additionally projects each axis-applied point through the same typed loader; execution `sections`
  describes its construction template. Each section has `used`, `origin: owning_resolution_rule`,
  `rule_source` (Runner loader source digest and symbol), and `input_assigning_histories`. These are
  actual typed used values, including constructor defaults; they are not renamed raw YAML.
  Quantities use `{value, unit}`; optional absent values are null, never zero. This representation
  deliberately reports the owning resolving rule and its complete input histories, not a guessed
  direct assigning leaf or a comparison with a default instance. Fields may be derived from several
  inputs. `default_rule_sources` records computed exact source digests for the owning Runner loader
  and finite Core constructor files. Unknown projected types refuse preview; there is no
  reflection/repr fallback or silent omission.
- `plan`: exact UTF-8 JSON string emitted by the existing plan writer; `plan_sha256`, `fingerprint`,
  `scientific_fingerprint`, `counts` (`points`, `executions`), and `estimates` from the existing
  estimator. Clients must submit that same string without parsing/reserializing it. Estimates are
  not measured resource usage or physical acceptance. Cross-host full/scientific fingerprints can
  differ because the existing identity includes resource-sensitive nodes.

All metadata DTO mappings and lists are recursively projected for browser-safe integers: values in
`[-9007199254740991, 9007199254740991]` remain JSON numbers; integers outside that range use
`{kind:"integer", decimal:"9223372036854775807"}` (with the actual exact signed decimal). Booleans
remain booleans. This includes raw resolved inputs, variant overrides, quantities, typed constructor
defaults and estimates. It does not alter scientific objects, the v2 identity, or `plan`: that raw
JSON string and its exact SHA remain unchanged. Clients display the decimal string directly without
converting it to a JavaScript Number. Finite Float64 values outside the same numeric range use
`{kind:"float64", decimal:"1.0e22"}`, with the actual `repr(Float64)` decimal. This string
round-trips the underlying Float64; it does not claim an exact real number. This tag also applies
recursively to large supported physical inputs such as LO mode density. The integer tag and raw
frozen plan remain unchanged.

YAML depth and node limits are checked through the installed YAML parser's iterative event stream
before document composition/construction. Quoted strings, comments and block scalars therefore do
not affect structural depth counting; both flow and indentation-based collections use the same
nonnegative depth cap.

Errors have `{status:"error", error:{code,path,message}}`. Public messages are bounded generic
refusals, without host paths, environment or parser traceback. No raw exception is returned.
Engineering bounds are request 256 KiB, YAML 128 KiB, captured catalog/files 1 MiB, plan 4 MiB,
complete response 8 MiB, nesting 64, tree nodes 100000, and 100 points/executions. Duplicate
JSON/YAML mapping keys, non-string YAML keys and nonfinite numbers are rejected. Anchors, aliases
and YAML tags are explicitly unsupported; the conservative lexer also refuses `&`, `*`, `!` inside
quoted/comment text. Limits never reduce a grid or scientific axis. Caller owns timeout, CPU/RAM and
process-group kill/reap; this one-shot command introduces no service or background queue.

The focused contract entry is `test/focused/configurator_preview.jl`. Run only with a prepared
existing environment, within the shared verification budget; no bootstrap, package install or solver
is part of this gate.

## Structure editor metadata

The additive `structure_editor` response uses `qcl-negf.structure-editor.v1` and `status: available`
with an `executions` array. Every entry binds `execution_id` and `variant_id` to normalized
**typed** `inputs`:

- `layers`: `thickness_nm`, `material`, `aluminium_fraction`, `conduction_band_edge_eV`,
  `longitudinal_relative_mass`, `transverse_relative_mass`, `relative_permittivity`, and `doped`.
- `interfaces_nm`, `donor_sheet_density_per_m2`, `ionization_fraction`, `position_origin_nm`, and
  `reference_energy_eV`.

`geometry` contains `period_nm` and per-layer `index_1based`, `left_nm`, `right_nm`. Its coordinate
scope is one structural period before position-origin or bias sampling. These rectangles show
submitted piecewise layer properties; they are not a computed potential, normalized volume doping,
energy levels or wavefunctions. Interfaces remain explicitly authored and are not replaced by layer
edges. The existing loader checks their order and period bounds.

`material_presets` deduplicates complete material tuples from the current execution, excluding
thickness and doping mask. Present these as “набор выбранной модели”. Copy the complete tuple when
selecting one; changing aluminium fraction does not imply recomputed masses or band edge. Presets
and execution entries carry `source_binding`: `execution_id`, `variant_id`, `catalog_source_id`,
`template_id`, `template_sha256`, `model` (with its catalog path/name/SHA),
`execution_provenance.sources`, `default_rule_sources`, `physical_rule_source`, and
`input_assigning_histories`. Histories describe actual resolving inputs, not per-constant
experimental attribution or evidence that a catalog identity was published. Preserve unknown or
fixture source identity as supplied by the trusted caller.

There is no new request grammar. Use existing `fields.variant` with a unique ID,
`comparison_kind: physical_parameter`, and explicit whole-leaf controlled paths: `physical.layers`,
`physical.interfaces`, `physical.donor_sheet_density`, `physical.ionization_fraction`,
`physical.position_origin`, `physical.reference_energy`. Its `overrides.physical` contains the
complete chosen values using existing quantity strings, such as `2 nm`, `0.2 eV`, `1e14 m^-2`.
Baseline and unspecified template fields remain present. Indexed layer paths are not supported.
Changing geometry is a physical variant; the existing loader may derive a changed field from voltage
and period. This is not a resource shortcut.

Editor quantities must be finite browser-safe scalars. At most 256 layers and 256 interfaces per
execution, material labels up to 256 UTF-8 bytes, and a 1 MiB editor projection are supported.
Oversize or unsupported editor metadata returns
`{schema:"qcl-negf.structure-editor.v1",status:"unavailable",reason:"unsupported_structure_editor"}`.
It preserves the existing preview, full semantic YAML and frozen plan. If adding the editor would
exceed the existing complete-response cap, only that additive projection becomes unavailable.
Invalid configurations still use the existing whole-preview refusal; limits do not silently alter
the structure.

An older producer without `structure_editor` remains usable with unavailable editor capability.
Editing invalidates any prior plan/resource confirmation; expert YAML preservation and
`short_form.lossless` semantics still apply. Preview never calls grid/profile/basis construction,
solve, submission or artifact writers; all scientific acceptance axes remain unknown. New-structure
energy levels and wavefunctions require a separate explicit bounded owning operation.

The additional prepared-environment focused entry is `test/focused/structure_editor.jl`. Run it
together with the existing configurator preview contract only within the assigned finite
verification envelope.

## Quantum basis preview (source adapter; delivery binding pending)

`qcl-negf quantum-preview --runner-source-id ID --core-source-id ID [--output FILE]` reads a single
strict JSON request from stdin. This separate, explicit operation never calls run-plan, SCBA,
Poisson, builds kernels or constructs a dummy `NEGFProblem`. Expected source IDs and output path
belong to the trusted caller; stdin cannot name files, a runtime context, environment variables or
CLI flags. The command returns 0 for `available`, 2 for refusal/unavailable. `--output` must be a
new file in an existing caller-owned directory. Atomic file and stdout contain identical UTF-8
bytes, including their final newline; no HDF/checkpoint or registry is produced. Output failure is
terminal, with no retry.

The exact request keys are:

```json
{
  "schema": "qcl-negf.quantum-preview-request.v1",
  "plan": "<exact frozen JSON string>",
  "plan_sha256": "<64 lowercase hex>",
  "expected_runner_source_id": "<trusted Runner graph ref>",
  "expected_core_source_id": "<trusted Core graph ref>",
  "execution_id": "<one execution>",
  "point_id": "<one point in that execution>",
  "variant_id": "<that execution variant>",
  "budget_policy_id": "quantum-preview-reference-v1"
}
```

Duplicate/unknown keys, nonfinite scalars, depth>64 or >100000 JSON nodes refuse. Envelope≤1536 KiB,
exact plan≤1 MiB, ≤64 executions/256 points/256 layers per configuration. The existing owning loader
validates both frozen fingerprints, point passports and membership. Selected bias and temperature
are applied through `_point_resolved_raw` and the existing configuration loader. Healthy bias is
nonnegative; negative bias refuses before basis construction. No plan/grid/model rewrite,
coarsening, sampling or first-K truncation is performed.

Before grids/profiles/basis, checked integer guards require W=(2P+1)Nz≤1536, S=(2P+1)Nb≤256 and S≤W,
1≤Nb≤min(Nz,32), NzNb≤16384, NkNb²≤65536, A=NE+Nqz+Nphi+Nk+Nz≤65536. The preallocation screen is
64MiB+256W²+128WS+192S²+128Nz²+128NzNb+256Nb²+32NkNb²+128A≤1GiB. It is an engineering screen, not a
measured LAPACK/JIT/GC/RSS upper bound. Reference Nz198/Nb5/P3/W1386 screens at570928352 bytes;
catalog analytical Nz96/Nb5/P3/W672 at191176864 bytes. Both are eligible without changing
dimensions; no runtime fit is implied. Full h[Nk,Nb,Nb] is allocated by the Core pure API.

The caller must separately admit/enforce 1 CPU, 2 GiB memory, swap0,64pids, 180s full invocation
plus≤5s confirmed cleanup, Julia/GC/BLAS/OMP threads1, stdout/artifact≤2MiB,stderr≤64KiB,temp≤8MiB.
There is no automatic warmup, precompile/install/network access, retry, cap increase or alternate
grid. This Runner adapter bounds serialization while writing; it does not install cgroups or claim a
timeout/RSS proof. Portal's direct190s deadline includes reading the body; quantum-only browser195s
abort and shared Configurator gate are consumer responsibilities. They are not implemented in Runner
or the AiiDA actor.

### Meaning and DTO

The artifact schema is `qcl-negf.quantum-preview.v1`. Available response contains `preview_id`,
`identity`, `budget_policy_id`, `policy_revision`, `payload`, `payload_sha256`,
`payload_digest_encoding`, `limits`, `assessment`, `measurements`. `preview_id` is SHA256 of
existing canonical bytes of `{request,policy_revision}`; `request` includes the unchanged raw plan.
`identity.request_sha256` instead hashes the exact original envelope bytes. `identity` binds plan
SHA/both fingerprints, execution/point/variant, owning point passport and verified runtime source
view. No run/attempt or native provenance is fabricated.

`payload_sha256` hashes **existing qcl-negf-canonical-bytes-v1 bytes of payload**, not its enclosing
JSON and not itself. The file/stdout transport may additionally be hashed as exact bytes by the
consumer. Payload contains all ascending `energy_eV[Nb]`, `z_nm[Nz]`, scalar `dx_nm`,
`psi_real[Nz][Nb]`, `psi_imag[Nz][Nb]`, `density_per_nm[Nz][Nb]`, `shape:[Nz,Nb]`, dimensions,
units, actual numerical/scattering/model inputs, diagnostic residuals and scope. Rows are explicitly
z-major; matrices are never silently flattened. Wavefunction unit is nm^-1/2, density nm^-1;
energies eV. Data must be finite. Refusal has `payload:null`, `plan_changed:false`, reason and
available actual/allowed limit plus preserved identity. It contains no partial arrays or private
path/error trace.

Core owns resolve_physical_models/build_grids/build_profiles/build_basis and project_hamiltonians.
Configured pzp/none/real_space is retained. Pure h(k0) has U_H=0 and excludes T±; parabolic and Kane
in-plane transverse terms are zero at k0. Basis window is zero-field with Dirichlet endpoints.
Onsite central block retains the same window seam-face diagonals, not a rebuilt isolated cell. PzP
uses central-column selection, cell restriction and Löwdin. `band_edge_eV` is explicitly the
zero-field material band, without bias tilt or Hartree. Doping metadata does not generate a Hartree
solution. Point T is recorded, with no thermal scattering computed.

The thin standard eigen/phase/unit adapter follows existing `save_analysis_physics` precedent
without calling that HDF/Green-dependent helper. It uses the actual Core Hermiticity constants.
Largest spatial amplitude fixes phase real-positive, ψ=(χV)/sqrt(L0_nm), density=abs2ψ and
energies=λE0+Eref. The discrete sum(dx_nm*density)=1 is the declared metric. Individual vectors
**and densities** in a degenerate block are not unique; compare whole-block projector/summed
density. Never infer state correspondence across previews. Residuals are diagnostics;
SCBA/Poisson=`not_performed`, scientific=`not_assessed`. Elapsed/peak default null with
external-measurement reason because handler timing cannot measure the full cold/JIT process
invocation or its actual cgroup peak.

### Trusted delivery port and current limitation

The production default is deliberately `runtime_source_binding_unavailable`. Source-ready does not
mean native available. No matching source label/version, nearby file hash or arbitrary client
context can enable the command. No standalone binding file/flags or separate attestation protocol is
added.

The internal producer accepts trusted keyword `runtime_verifier(expected,actual)`. `expected` is
`(runner_source_id,core_source_id)` from fixed caller arguments; `actual` contains real loaded
`(runner,core,project,manifest)` paths from pkgdir(QCLNEGFRunner), pkgdir(QCLNEGF), active Project
and sibling Manifest. The callback must have verified the **existing delivery** graph→drv→output→NAR
and compiled-image/depot association and context digest before returning this exact NamedTuple
`trusted_runtime_context`:

```
release_id, solver_executable, solver_output, nar_hash, drv_path,
source_graph_sha256, julia_manifest_sha256, runner_source_id,
core_source_id, context_sha256
```

These fields correspond to the agreed existing release.json/service.env port; the callback is not a
browser approval flag. Runner requires selected immutable `/nix/store/<hash>-<output>`, exact
executable `<output>/bin/qcl-negf`, loaded Runner/Core under `<output>/share/qcl-negf/components`,
active Project/Manifest under its julia directory, expected source refs and captured Manifest SHA.
It captures hashes of fixed small configuration/planning/snapshot/quantum and Core
grids/basis/hamiltonian/model_operators/observables/invariant rule files in that same output
(bounded2MiB aggregate). Those observed hashes are diagnostics, not substitutes for delivery's
NAR/compiled binding; expected per-rule receipt fields are not invented. No depot/NAR scan or
Git/network is done per request. Wrong paths/Manifest or refusing/missing verifier blocks before
basis. Public DTO omits private runtime paths and includes graph/Manifest/context/rule/source
hashes. Production CLI cannot become available until the owning existing delivery getter is wired
into this default port; injectable synthetic fixtures are not that gate.

The default quantum runtime verifier now consumes the existing root-owned delivery
`runtime/release.json` at its fixed system path, with protected ancestry, bounded regular-file read,
matching installed application/solver profiles, ready state, canonical source-graph/context digests
and exact server-built context environment. Environment labels alone cannot authorize it. Loaded
package, Project, Manifest and fixed rule checks remain unchanged. Missing/mismatched delivery stays
unavailable; NAR/build correlation is verified at delivery, not rescanned per request. No standalone
proof file or new CLI flags are accepted.

### Общая семантика preview

Форма, YAML, файловый resolver и CLI используют один resolved snapshot. Поле `resolved_snapshots`
содержит actual typed sections и их owning origins; raw input остаётся отдельным объяснением.
`variant_diffs` содержит effective diff относительно baseline, включая проверку объявленных
`controlled_paths`. UI не должен самостоятельно вычислять defaults. `resource_estimates` —
conservative analytical receipts с явными unknowns. Они не доказывают наличие allocation, измеренный
RSS или научную сходимость. Native grant и exact restart проверяются своими владельцами.
