# [Run configurations](@id yaml-run-configurations)

A run configuration is a YAML file with dimensional physical quantities, numerical grids, scattering
models, convergence policy and output settings. Load one or more ordered files with
`load_run_configuration`; later files override explicit fields. The schema is
`schema/run.schema.json`. The checked example is `examples/config/reference-2019-70k.yaml`.

## [Developer route: inspect the value and its source](@id developer-configuration-route)

Start with an ordered configuration input, not a current default. The goal is to report both the
resolved leaf and what the recorded history actually identifies. The following route loads/inspects
configuration only; it does not solve transport.

## Recorded assignments and value origins

`configuration_source(configuration, dotted_path)` returns the last assigning-source identifier in
that leaf's recorded provenance history. Explicit configuration leaves record source filenames;
generated overrides may record identifiers containing a `#generated:` marker. Later recorded
assignments override earlier assignments. The lookup returns `nothing` when the history is absent or
empty, even if a typed field has a value. It reads the recorded history; it does not load or
validate source files.

The
[merge-order fixture](https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl/blob/23860d9e660a3cddf6cb5203d449d1b62f3745a1/test/application/configuration_merge_order_and_fail_closed_validation.jl)
starts with a base file and applies `first.yaml` with `energy_chunk: 17`, then `second.yaml` with
`energy_chunk: 23`. The resolved value is 23 and the assigning source is `second.yaml`. Reversing
those two overrides gives 17 and `first.yaml`. These are fixture expectations; the source example is
not a production-run receipt.

To follow that exact input order in a Runner checkout, use `test/fixtures/configurations/base.yaml`
as the complete base and the two small files below. The snippets reproduce the synthetic inputs of
the fixture; the files are created by that fixture in a temporary directory.

```yaml
# first.yaml
production:
  energy_chunk: 17
output:
  directory: results/first
```

```yaml
# second.yaml
production:
  energy_chunk: 23
output:
  directory: results/second
```

```julia
# Inspection example; ordinary fenced text, not a docs-build execution.
base = "test/fixtures/configurations/base.yaml"
configured = load_run_configuration([base, "first.yaml", "second.yaml"])
configured.production.energy_chunk                            # 23
configuration_source(configured, "production.energy_chunk")  # path ending in second.yaml
reversed = load_run_configuration([base, "second.yaml", "first.yaml"])
reversed.production.energy_chunk                             # 17
configuration_source(reversed, "production.energy_chunk")     # path ending in first.yaml
```

The expected result distinguishes four facts:

| Fact                       | What this example establishes                                                                                                                                         | What to inspect for another run                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Model/formula meaning      | `energy_chunk` bounds scheduling work in energy-node counts; it is not an energy spacing or a physical NEGF parameter. No physical formula is inferred from its name. | The [owning schema](https://github.com/Afonenko-QCL-NEGF/qcl-negf-contracts/blob/02a564b78dc9c5e19eacf496bc8c891361eafaab/src/qcl_negf_contracts/schemas/run.schema.json) and [Core formula-to-function reference](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/blob/f5b73369a96d1225bd96fb34f5262c8dcf965f86/docs/src/developer/traceability.md) for physical leaves; a scheduling leaf does not supply a physical formula. |
| Numeric value              | The merged input has positive integer 23 (or 17 in reverse order).                                                                                                    | The exact resolved input retained with that attempt.                                                                                                                                                                                                                                                                                                                                                                            |
| Assigning-source origin    | [`configuration_source`](@ref) names the last recorded assignment, `second.yaml` (or `first.yaml`).                                                                   | The same leaf's recorded history; absent/empty history returns `nothing`, even while the value remains 23.                                                                                                                                                                                                                                                                                                                      |
| Effective execution origin | This load example has not selected a resource execution plan.                                                                                                         | The effective configuration **and** retained [`ExecutionPlan`](@ref); this lookup alone cannot reconstruct the complete planning chain.                                                                                                                                                                                                                                                                                         |

[`resolve_execution_strategy`](@ref) can apply a selected plan. For the `auto_exact` production
path, its recorded assigning policy is `application:auto_exact`; the selected plan supplies
effective chunk/worker values. Other paths need not add that marker. Preserve the plan's hardware,
strategy and reasons separately; a marker is not a measurement receipt or the full causal origin of
a value. The
[implementation](https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl/blob/23860d9e660a3cddf6cb5203d449d1b62f3745a1/src/application/auto_strategy.jl)
and [resource limits](@ref resource-planning) define this boundary. Missing effective-plan
provenance is unknown; do not infer it from 23, 17 or a constructor default.

The merged declarative input requires a positive integer `production.energy_chunk` and assigns no
schema default. It sets the maximum number of energy points per execution chunk for work scheduling;
it does not set energy-grid spacing. The Core `ProductionOptions` constructor has its own default
of 64. The base fixture also explicitly assigns 64. Equal values do not establish the same assigning
source, and an absent history does not identify that constructor as an origin. The existing
[generated-provenance fixture](https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl/blob/23860d9e660a3cddf6cb5203d449d1b62f3745a1/test/contracts/generated_scientific_configuration_provenance.jl)
expects `configuration_source(configuration, "physical.lattice_temperature")` to return
`definition_path * "#generated:temperature-axis"`. That recorded identifier names the generated
assigning policy; it does not identify a physical data source. Freeze/load preserves such recorded
histories. The lookup returns these markers when present; it does not reconstruct the complete
effective-value origin chain, including any further resource-planning decisions.

The owning
[schema provenance contract](https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl/blob/23860d9e660a3cddf6cb5203d449d1b62f3745a1/docs/schema-provenance.md)
defines packaged-byte verification and comparison with a selected workspace Contracts copy.

## [Scientific plans](@id scientific-plans)

A `qcl-negf-study-v2` definition names configuration sources, variants and operating points.
Temperature and voltage axes must be explicit; no device-specific operating point is assumed.
`qcl-negf plan examples/config/operator-algebra.yaml` emits an immutable
`qcl-negf-scientific-plan-v2` JSON plan. Store this plan as an AiiDA input.
`qcl-negf run-plan plan.json result --execution-id ID` runs one declared execution; ID must be an
entry from `plan.executions`, never an unrelated process identifier. Continuation points within that
execution remain sequential.

Voltage policy accepts `independent` (the default, no predecessor reuse) and `strict`. Strict reuse
requires consistent final whole/inner convergence and quality plus ready Core stationary assessment
with its known registry version and all four stationary certificate flags true. Live reuse also
requires the actual final report to pass; completed restore reads the retained assessment from a
verified native commit and checks original final flags against commit and series metadata.
Operational `restart` is not a final convergence verdict. This gate is separate from inner
SCBA→Poisson permission and from campaign discretization or experimental validation; `not_measured`
is not promoted to pass.

Legacy voltage `research` finite-predecessor policy is retired with an explicit error. This is a
breaking boundary for typed frozen-plan load, re-execution, resume, and Runner helpers that load
such plans. Choose a new explicit strict or independent plan with a new identity; existing
fingerprints, statuses, qualities and warnings are not rewritten or automatically migrated.
Independent Results readers and raw archive inspection remain separate from executable typed
loading. Compatibility with every historical archive schema has not been established. Strict invalid
predecessors leave declared descendants skipped and not evaluated. Only explicit `cold_start`
permits a cold suffix; an accepted suffix does not erase the earlier branch failure. Metadata
routing evidence does not establish full S06 native recovery or scientific acceptance.

The CLI writes scientific result JSON to stdout and artifacts below the output directory. Exit code
0 means successful process completion. Inspect scientific status and point quality before treating a
result as accepted. Invalid arguments and configuration errors produce exit code 2.

Resource discovery and admission are described in [resource limits](@ref resource-planning).
Numerical meaning, units and convergence criteria are documented by
[QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/tree/main/docs/src).

## Node-local scratch

`qcl-negf run-plan PLAN OUTPUT --scratch-root /absolute/local/scratch` runs in a unique local
directory and copies a closed result tree to a fresh destination. Runner verifies copied bytes and
native commit manifests, then publishes the destination directory. The destination must not already
exist.

Staging uses the selected execution's existing `output.recovery.byte_budget` and `reserve_bytes` as
its operational policy even when periodic recovery is disabled. For several selected executions it
uses the smallest budget and largest reserve; an incompatible combination is rejected before
computing. Recovery-enabled plans publish directly to output storage and bypass end-only scratch
staging.

`stage_result_tree(SOURCE, DEST; byte_budget=8*1024^3, reserve_bytes=64*1024^2)` counts the
simultaneous logical bytes of the closed source and pending destination copy, plus the reserve. Each
controlled copy write checks projected growth and observed destination free space. Refusal does not
replace an existing destination or alter the source, and removes only its own incomplete staging
directory. This is a logical copy guard, not a filesystem quota or an aggregate limit on unrelated
scratch directories, logs, AiiDA retrieval or concurrent writers.

On computation or transfer failure, the local workspace is retained and its path is reported on
stderr. This option starts a fresh execution; explicit restart uses the normal execution path and
compatible checkpoint state. It does not merge results or turn an incomplete calculation into an
accepted one.

The [bounded configurator preview](configurator.md) exposes the same scientific resolver to short
forms and full study YAML without executing a run.

## Полный снимок разрешённых входов

`resolved_configuration_dict(configuration)` сохраняет прежний смысл: это копия исходного слитого
YAML, без обещания перечислить defaults typed constructors. Для фактически выбранных значений
используйте общий API:

```julia
configuration = load_run_configuration("run.yaml")
snapshot = resolved_configuration_snapshot(configuration)
metadata = resolved_snapshot_dict(snapshot)
metadata["sections"]["domain_adaptation"]["used"]
metadata["model_binding"]
```

Снимок владеет неизменяемыми байтами; возвращённый словарь — отдельная копия. Его создание проверяет
соответствие raw и typed inputs тем же resolver. Это declarative phase, без solver, изменения
потоков или admission. Callback/runtime state в такой снимок не принимается.

Каждая секция содержит `used`, единицы, `origin="owning_resolution_rule"`, hash и symbol правила
разрешения, а также полную историю присваиваний входов правила. История не приписывает каждому полю
фиктивный источник default по совпадению величин. Явно записанный default и пропущенный default
могут иметь одинаковое использованное значение и model digest при разном raw/provenance.

`model_binding.sha256` связывает stationary transport inputs: физику, дискретизацию, scattering,
алгоритмы и критерии. Эквивалентные записи единиц сравниваются после owning unit conversion;
приближённое сравнение и округление при хешировании не используются. Имя файла, описание,
Root/source locator и runtime allocation не подменяют модель. Scientific plan fingerprint
дополнительно связывает точки и продолжение; logical plan fingerprint включает metadata;
`plan_sha256` означает hash фактических frozen bytes. Exact Core restart имеет собственную
numerical/runtime identity и требует отдельной проверки.

`resolved_configuration_diff(base, candidate; controlled_paths=["numerical.energy_nodes"])`
показывает изменения typed values и derived inputs. `comparable=true` означает, что изменения
scientific inputs объясняются перечисленными declarative путями: Runner применяет их к baseline и
повторяет общий resolver. Это не экспериментальная валидация и не доказательство точности.
Необъявленные изменения scattering, model или tolerance остаются `undeclared_changes`.

`scientific_resource_estimate(configuration; worker_capacity=4)` возвращает analytical receipt, а не
RSS или ресурсную резервацию. При адаптации он сохраняет полный declared energy-node cap и
одновременно живущие domains. Runtime/allocator overhead, measured RSS, admitted RAM и полный memory
request остаются `nothing`, пока нет owning свидетельств. Для forecast с явным target и trusted
margin policy используется прежний `resource_proposal`; неизвестная capacity не заменяется
административным максимумом.

Point passport применяет фактические temperature/bias axes и отмечает их историю как
`#generated:point-axes`. Исходный `field_bias` при выборе оси voltage per period снимается, чтобы
сохранить правило ровно одного заданного представления bias. Расчёт получает те же явно выбранные
оси. Histories алгоритмов включают execution backend, production — алгоритмы и backend, scattering —
физические входы validation; источник не ограничивается одним YAML разделом, если owning правило
принимает несколько разделов.
