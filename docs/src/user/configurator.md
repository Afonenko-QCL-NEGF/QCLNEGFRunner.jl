# Bounded configurator preview

`qcl-negf configure --catalog-root ROOT --catalog-source-id ID` reads one strict
JSON object from stdin and writes one JSON response to stdout. `--catalog` as the
last argument lists the trusted catalog without reading stdin. Both commands
return status 0 for `status: available`, 2 for `status: error`. These operations
resolve metadata; they never admit, submit, recover or solve a run.

ROOT is the immutable Research checkout, selected by the caller's trusted release
configuration; ID is its exact source identity (1–256 portable characters).
Neither comes from a web request. The fixed asset is
`config/configurator-catalog.json`:

```json
{"schema":"qcl-negf-configurator-catalog-v1","templates":[{"id":"example","name":"Example","study":"config/studies/example.yaml","model":{"name":"Model","path":"config/model/model.yaml"},"protocol":{"name":"Protocol","path":"config/policies/policy.yaml"},"description":"An authored candidate, not scientific acceptance"}]}
```

All fields are required and unknown fields are rejected. IDs must be unique;
there are 1–32 entries. The catalog response contains `status`,
`catalog_source_id`, and `templates`. Each entry includes `study_sha256`,
`model.sha256`, `protocol.sha256`, and `protocol.version` equal to exact
`ID:protocol.path`. Digests are computed from captured bytes. This asset is a
small allowlist, not an independently maintained revision lock.

A preview request has `mode`, `template_id`, `catalog_source_id`, and exactly one
payload: `fields` for `form`, or original UTF-8 `yaml` for `yaml`. Full YAML uses
the existing complete `qcl-negf-study-v2` grammar and resolver. The sources are
relative to the selected study's directory; normalized realpaths must remain
inside ROOT and match the selected model or protocol file. Order is preserved.
Absolute output directories, absolute/foreign source paths, symlink escape, meta/select/includes and uploaded files
are refused. The existing `plan` command retains its broader local-file contract.

The finite form fields are `temperature_K`, `voltage_per_period_mV`,
`voltage_mode` (`independent` or `strict`), `scba_to_poisson` (existing policy
names), and `variant`. Each is optional. Values are typed, with no string-number
coercion. `variant` appends one existing grammar variant with required `id`,
`comparison_kind`, `controlled_paths`, `overrides`, and optional `method_id`.
Grid changes belong in the variant's explicit numerical overrides and controlled
paths. Existing variant validation remains authoritative. Form edits preserve
all unspecified template leaves. YAML remains authoritative; `short_form` reports
`lossless: true` only for exact template equivalence, otherwise it returns
`authoritative_yaml_requires_preservation`. Clients retain original YAML bytes;
the returned semantic `draft_yaml` is not an authored-byte archive.

An available preview response contains:

- `draft_sha256`: exact input request UTF-8 bytes; form/YAML hashes differ.
- `semantic_draft_sha256`: existing canonical-byte encoding of the complete
  semantic draft, replacing ordered source spellings by logical source identities
  `source-ID digest + catalog-relative path + file digest`. The frozen assigning-source
  labels live under virtual `/@qcl-configurator/`; they are logical locators,
  never temporary files. A form and its returned YAML have identical labels and
  frozen plan in a fixed source/hardware fixture. This does not change v2 identity.
- `catalog_source_id`, `template`, `draft_yaml`, `short_form`, and `variant_diffs`
  (`id`, `comparison_kind`, `controlled_paths`, complete explicit `overrides`).
- `resolved_inputs`: execution ID, complete validated merged `configuration`,
  ordered leaf `assigning_sources` histories. Missing history remains missing.
- `effective_defaults`: execution ID and finite owning `sections` projections.
  `point_sections` additionally projects each axis-applied point through the same
  typed loader; execution `sections` describes its construction template.
  Each section has `used`, `origin: owning_resolution_rule`, `rule_source` (Runner loader
  source digest and symbol), and `input_assigning_histories`. These are actual
  typed used values, including constructor defaults; they are not renamed raw
  YAML. Quantities use `{value, unit}`; optional absent values are null, never
  zero. This representation deliberately reports the owning resolving rule and
  its complete input histories, not a guessed direct assigning leaf or a
  comparison with a default instance. Fields may be derived from several inputs.
  `default_rule_sources` records computed exact source digests for the owning
  Runner loader and finite Core constructor files. Unknown projected types refuse
  preview; there is no reflection/repr fallback or silent omission.
- `plan`: exact UTF-8 JSON string emitted by the existing plan writer;
  `plan_sha256`, `fingerprint`, `scientific_fingerprint`, `counts` (`points`,
  `executions`), and `estimates` from the existing estimator. Clients must submit
  that same string without parsing/reserializing it. Estimates are not measured
  resource usage or physical acceptance. Cross-host full/scientific fingerprints
  can differ because the existing identity includes resource-sensitive nodes.

All metadata DTO mappings and lists are recursively projected for browser-safe
integers: values in `[-9007199254740991, 9007199254740991]` remain JSON numbers;
integers outside that range use `{kind:"integer", decimal:"9223372036854775807"}`
(with the actual exact signed decimal). Booleans remain booleans. This includes
raw resolved inputs, variant overrides, quantities, typed constructor defaults
and estimates. It does not alter scientific objects, the v2 identity, or `plan`:
that raw JSON string and its exact SHA remain unchanged. Clients display the
decimal string directly without converting it to a JavaScript Number.
Finite Float64 values outside the same numeric range use
`{kind:"float64", decimal:"1.0e22"}`, with the actual `repr(Float64)` decimal.
This string round-trips the underlying Float64; it does not claim an exact real
number. This tag also applies recursively to large supported physical inputs
such as LO mode density. The integer tag and raw frozen plan remain unchanged.

YAML depth and node limits are checked through the installed YAML parser's
iterative event stream before document composition/construction. Quoted strings,
comments and block scalars therefore do not affect structural depth counting;
both flow and indentation-based collections use the same nonnegative depth cap.

Errors have `{status:"error", error:{code,path,message}}`. Public messages are
bounded generic refusals, without host paths, environment or parser traceback.
No raw exception is returned. Engineering bounds are request 256 KiB, YAML
128 KiB, captured catalog/files 1 MiB, plan 4 MiB, complete response 8 MiB,
nesting 64, tree nodes 100000, and 100 points/executions. Duplicate JSON/YAML
mapping keys, non-string YAML keys and nonfinite numbers are rejected. Anchors,
aliases and YAML tags are explicitly unsupported; the conservative lexer also
refuses `&`, `*`, `!` inside quoted/comment text. Limits never reduce a grid or
scientific axis. Caller owns timeout, CPU/RAM and process-group kill/reap; this
one-shot command introduces no service or background queue.

The focused contract entry is `test/focused/configurator_preview.jl`. Run only
with a prepared existing environment, within the shared verification budget;
no bootstrap, package install or solver is part of this gate.
