# Локальный интеграционный driver

`tools/local_lab_acceptance.jl` предоставляет пять явных операций для KVM lab.
Driver запускают с **Julia 1.13.0**, одним Julia thread и immutable environment,
содержащим QCLNEGFRunner/QCLNEGF из выбранного release. Он устанавливает один
BLAS thread. `--help` и проверки путей не загружают научные пакеты.

Все пути должны быть абсолютными, каноническими и без symlink-компонентов.
Выход должен отсутствовать; driver не принимает существующее дерево как своё
и не удаляет исходные данные. Каталоги создаются с mode `0700`. При ошибке
частично созданный выход сохраняется для диагностики; повторный запуск требует
нового пути. Exit code `0` подтверждает выполненную операцию хранения/исполнения,
а научный статус читают отдельно из commit и `series_result.json`.

Пример с установленным environment и отдельными owned путями:

```sh
export JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
DRIVER=/immutable/runner/tools/local_lab_acceptance.jl
ENVIRONMENT=/immutable/julia-environment
julia --project="$ENVIRONMENT" "$DRIVER" native /scratch/lab/native
julia --project="$ENVIRONMENT" "$DRIVER" prepare /scratch/lab/frozen
timeout 1200 julia --project="$ENVIRONMENT" "$DRIVER" pause /scratch/lab/frozen /scratch/lab/paused
timeout 1200 julia --project="$ENVIRONMENT" "$DRIVER" resume /scratch/lab/frozen /scratch/lab/paused /scratch/lab/resumed
julia --project="$ENVIRONMENT" "$DRIVER" staging /scratch/lab/native /shared/lab/native
```

Operator выделяет CPU1/RAM1792MiB и timeout1200 на физическую фазу через Slurm
либо эквивалентный внешний лимит. Сам driver не реализует ограничения памяти
или wall time и не повторяет расчёт автоматически. `native` — малая операция
хранения; для её отдельной проверки достаточно внешнего timeout300.

## Native storage fixture

`native OUTPUT` вызывает существующий
`test/support/native_physics_fixture.jl` с `energy_nodes=33`. Это seeded Green
state на сетке `Nz25/Nb2/NE33/Nk3`, без запуска SCBA/Poisson и с выключенными
каналами рассеяния, как определено владельцем fixture. Driver не добавляет
формулы и не создаёт фиктивные строки iteration history. Публичный
`commit_point_artifacts(...; storage_class=:archive)` публикует native
`physics.h5`, analysis и checked commit; `scientific_plan.json` фиксирует
описание, а `series_result.json` содержит ссылку на этот commit для независимого
StateReader/export. Неизвестный restart algorithm contract сохраняется как
неизвестный: seeded archive не выдаётся за restart-ready checkpoint.

Сначала замораживается native configuration, затем owning
`build_configured_problem` строит problem из неё, а fixture принимает именно
этот problem и `solver_options(configuration)`. Таким образом, HDF5 паспорт,
resolved model и frozen plan описывают одни и те же inputs/controls; fallback
`tutorial_options()` используется только прежними callers fixture без явных
options. Native overrides сетки/температуры/рассеяния относятся только к
storage fixture; physical двухточечное определение не меняется.

`native-evidence.json` фиксирует hashes плана/commit, manifest и
`solver_executed=false`, `scientific_accepted=false`. Серия имеет `status=failed`
и предупреждение `STORAGE_FIXTURE_NO_SOLVE`: fixture пригоден для проверки
архива/reader/export, но у него нет научно завершённой итерации. Отдельное
`storage_completed=true` не означает сходимость или физическую приёмку.

## Frozen two-point pause/resume

`prepare DIRECTORY` переносит определение из
`test/integration/portable_two_point_resume.jl` без изменения задачи:
`studies-smoke.yaml`, `Nz48/Nb3/NE49/Nk5`, energy window `[-0.5,1.5] eV`,
`70 K`, voltages `[50,56] mV`, strict voltage policy и cold-start при непригодном
предшественнике. LO/acoustic/impurity/IFR сохранены, alloy выключен, исходные
допуски неизменны. Ограничение **2 SCBA/1 Poisson относится к каждой точке**,
как в исходном integration fixture; две точки не означают глобальный лимит
двух итераций на фазу. Это диагностическая малая постановка, не production
study и не доказательство достаточности сетки.

Prepare один раз записывает `study.yaml`, `scientific_plan.json` и
`plan-identity.json` с SHA256 плана, definition/base bytes, fingerprint и
execution ID. Pause/resume загружают именно frozen plan; новые планы не
разрешают. Проверяются bytes/fingerprint, сетка, окно, каналы, допуски и budget.

`pause DIRECTORY OUTPUT` запрашивает паузу второй точки перед attempt1.
Первая точка должна опубликовать final, вторая — durable paused receipt.
`verify_pause_receipt` проверяет checkpoint и зависимость от prior final;
`pause-evidence.json` сохраняет receipt, hash первого состояния и identity.

`resume DIRECTORY PRIOR_OUTPUT OUTPUT` требует совпадения frozen plan bytes.
В `OUTPUT.portable-input` через `stage_result_tree` копируются recovery bundle
второй точки и prior archive. Attempt2 получает эти копии как explicit inputs;
оригинал сохраняется. Driver проверяет сохранение hash/attempt1 первой точки,
checkpoint initialization/attempt2 второй, cumulative restart coordinates
`last_inner<=2` и `last_completed_outer<=1`, stop receipt и
`scientific_accepted=false`. Это не отдельная проверка возобновления после
удаления исходного пути; такой случай покрывает owning integration test.

## Scratch → shared staging

`staging SOURCE DEST` принимает completed native storage fixture с hash-bound
marker и вызывает реальный `stage_result_tree`. Источник должен находиться
на выделенном local scratch, а destination оператор выбирает на NFS/shared
mount. Driver проверяет identical hashes всех файлов; owning implementation
проверяет native commits, fsync файлов/каталогов и atomic rename на filesystem
назначения. Свидетельство `DEST.staging-evidence.json` лежит рядом с деревом,
чтобы staged bytes совпадали с source. Mount identity и syscall trace должен
измерить внешний lab probe; driver их не объявляет измеренными.

## Проверки и границы вывода

Без научного окружения доступны:

```sh
julia --startup-file=no --history-file=no tools/local_lab_acceptance.jl --help
julia --startup-file=no --history-file=no test/infrastructure/local_lab_acceptance_paths.jl
```

Отдельная регрессия `test/infrastructure/local_lab_native_passport.jl` требует
exact environment и выполняет только native seeded publication. Она сравнивает
все сохранённые HDF5 tolerances, mixing/budgets/windows, численные параметры,
каналы рассеяния, температуры/bias и структуру/материалы с frozen plan, а также
полные typed physical/numerical/scattering/scales/solver/model inputs между
планом и resolved model. Никакие итерации SCBA/Poisson она не запускает.

| Утверждение | Свидетельство | Ограничение | Решение |
| --- | --- | --- | --- |
| Fresh outputs не усыновляют чужие файлы | Pure path/CLI tests | Не моделируют конкурентного злоумышленника | Сохранить |
| Native bytes пригодны для reader/export | Checked native commit, независимый consumer в lab | Driver не исполняет reader/export сам | Дополнительно измерить |
| Pause/resume сохраняет prior final и budget | Receipts, hashes, attempts, restart coordinates | Требует фактического запуска exact release | Дополнительно измерить |
| Staging публикует идентичное дерево | Tree hashes и owning fsync/rename implementation | NFS identity/syscalls отдельно измеряет lab | Дополнительно измерить |
| Диагностическая задача научно принята | `scientific_accepted=false`; прочие границы `not_measured` | Нет сходимости/сеточной/экспериментальной валидации | Данных недостаточно |
