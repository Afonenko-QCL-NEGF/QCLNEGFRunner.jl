# Durability generic runtime checkpoint

Статус: контракт DEV17 для независимого CP-DESIGN; реализация DEV18 и её
runtime-проверки ещё не выполнены. Этот документ не является native receipt.
Owner — Runner. Физическая модель, scientific generation, схемы HDF5 и
критерии scientific acceptance этим решением не меняются.

## Источник и обнаруженный разрыв

Срез Runner: `12e4d025948847c1b5d18ef4eb43a9934d8e20da`. Локаторы ниже
относятся к этому commit; будущий исполнитель сверяет выбранный source и diff.
Первичные файлы: [repository](../src/infrastructure/runtime/filesystem_repository.jl),
[atomic rename](../src/infrastructure/persistence/atomic_files.jl),
[coordinator](../src/application/coordinator.jl),
[scientific comparison](../src/infrastructure/persistence/point_artifacts.jl).

| Наблюдение | Локатор в `src/` | Следствие |
| --- | --- | --- |
| `checkpoint!` прямо возвращает `save_runtime_checkpoint!` | `application/coordinator.jl:checkpoint!` | Между записью и возвратом application barrier отсутствует |
| Payload: codec writer → SHA/size → `mv(force=false)`; envelope: `_immutable_yaml` → `_atomic_yaml` → `_atomic_replace_file` | `infrastructure/runtime/filesystem_repository.jl:save_runtime_checkpoint!`, `_immutable_yaml`, `_atomic_yaml` | Ни file fsync, ни directory fsync нет |
| `_atomic_replace_file` выполняет один `jl_fs_rename`, без copy/delete fallback | `infrastructure/persistence/atomic_files.jl:_atomic_replace_file` | Это атомарность namespace, а не подтверждение persistence |
| Lock охватывает только выделение event sequence | `infrastructure/runtime/filesystem_repository.jl:_next_event_sequence!` | Выделение checkpoint generation и публикация сейчас не сериализованы даже для одного repository object |
| Reader сортирует metadata paths и проверяет только последний; без metadata возвращает `nothing` | `infrastructure/runtime/filesystem_repository.jl:_checkpoint_metadata_paths`, `load_latest_checkpoint` | Metadata filename — commit/selection boundary; отдельного pointer файла нет |
| Reader проверяет run/point, положительный attempt, bytes/SHA, затем codec | `infrastructure/runtime/filesystem_repository.jl:_validate_checkpoint_envelope`, `load_latest_checkpoint` | Другой положительный attempt без внешнего ожидания допустим |
| Coordinator читает latest при resume, после point runner и в exception path | `application/coordinator.jl:run_sweep!` | Ни один caller не добавляет persistence barrier; status/result/event записи тоже используют YAML rename без fsync |
| Production codec копирует закрытый current HDF5 в выделенный temporary; проверяет HDF5 schema | `composition/production_runtime_adapter.jl:_runtime_write_production_checkpoint`, `_runtime_production_checkpoint_codec` | Копирование codec payload не является commit primitive; generic envelope/barriers всё равно принадлежат repository |

Таким образом, enclosing barrier не найден. SHA подтверждает прочитанные
байты; `close`, `rename`, проверка схемы и последующее чтение из page cache
не заменяют persistence barrier. Решение — добавить только checkpoint-scoped
barriers; не менять durability всех callers `_atomic_yaml`.

Сравнение с scientific-путём ограничено
`infrastructure/persistence/point_artifacts.jl:commit_point_artifacts`,
`_prepare_generation!`, `_write_bundle_receipt`: там закрытая generation
синхронизируется, публикуется, проверяется, получает receipt, затем меняются
`current.json`/`previous.json` с barriers. Эти функции находятся в другом
module, не входят в `composition/application_runtime.jl` и не оборачивают
generic save. Generic checkpoint не получает scientific receipt, pruning,
fallback на previous или новые pointer/schema файлы.

## Граница гарантий

Поддерживаемая persistence-гарантия условна: локальная POSIX filesystem на
Unix с работающими file fsync, directory fsync и атомарным same-directory
rename; ОС, filesystem, mount и устройство должны выполнять свой контракт
успешного fsync. Репозиторий и его directory ancestry — доверенные реальные
каталоги без symlink-компонентов и внешних изменений checkpoint во время
операции. Run directory имеет одного writer между
процессами/машинами; два repository object для одного дерева не дают
координации. Repository lock координирует только задачи одного object.

NFS, другие network filesystems, Windows, отказ устройства и восстановление
после реального power loss этим source/design packet не проверены. На Unix
одна успешная syscall sequence не доказывает тип filesystem. Код не угадывает
его по имени пути. Для NFS persistence остаётся `not_measured`/unknown до
отдельного OPS receipt; `CheckpointReference` не объявляется доказательством
native delivery. На platform без Unix fsync implementation save отклоняется
до первой записи с `ArgumentError`; silent no-op barrier запрещён.

Различаются три события:

1. После metadata rename другие readers могут видеть новый полный checkpoint.
2. После последнего directory fsync persistence barriers завершены.
3. Только после readback verification и успешного возврата save writer
   подтверждает новый checkpoint в пределах поддерживаемой filesystem.

Успешный `load_latest_checkpoint` подтверждает integrity прочитанного
поколения. Он не доказывает, что другой writer уже вернулся, и не выдаёт
дополнительную persistence-гарантию. До возврата save crash допускает старое
полное поколение, новое полное поколение или явную unavailable/error; latest
не обещается. После успешного возврата новое поколение обязано независимо
читаться с точными identity, длиной и SHA. Ошибки и unavailable не равны pass.

## API, identity и совместимость

Позиционные аргументы и keywords `save_runtime_checkpoint!` сохраняются.
`CheckpointReference`, `LoadedCheckpoint`, имена поколений и
`reference2019-runtime-checkpoint-v1` сохраняются без добавления wire fields.
Старые полные v1 checkpoints читаются без перезаписи. Новый save не приписывает
старым данным задним числом успешный persistence barrier.

Единственное расширение reader API DEV18:

```julia
load_latest_checkpoint(
    repository::FilesystemRunRepository,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString,
    point_id::AbstractString;
    expected_attempt::Union{Nothing,Integer} = nothing,
)
```

`nothing` сохраняет current cross-attempt resume. Заданный expectation должен
быть положительным non-Bool integer, представимым как `Int`, иначе
`ArgumentError` до перечисления checkpoint. После проверки envelope, до
открытия payload и до `codec.reader`, несовпадение `attempt` с expectation
вызывает `CheckpointIntegrityError(metadata_path, "attempt mismatch")`.
Отсутствие metadata по-прежнему возвращает `nothing`, включая guarded call.
Guard проверяет declared attempt envelope; он не добавляет отсутствующий
attempt в произвольный payload и не заменяет codec/model validation.

Существующие три места `run_sweep!` оставляют default `nothing`: checkpoint
из attempt 1 может законно инициализировать context attempt 2 и оставаться
latest, если attempt 2 не сохранила новый checkpoint. `latest_checkpoint`
status/result уже несёт исходный `checkpoint.attempt`; его нельзя заменять
номером текущей попытки. Эти callers не заявляют exact-attempt rejection.
Exact-attempt потребитель вызывает новый keyword явно; DEV18 проверяет
production reader этим вызовом, а не только assertion в fixture oracle.

Reader сохраняет fail-closed выбор последнего metadata filename: повреждённое
последнее поколение вызывает error без fallback на старое и без fresh start.
Перед decode он дополнительно проверяет regular non-symlink metadata/payload
и соответствие имени `NNNNNNNNNNNN.metadata.yaml` declared generation.
Невалидные YAML/envelope/read failures возвращаются как
`CheckpointIntegrityError` с locator и причиной; `InterruptException`
пробрасывается. Файлы reader никогда не исправляет.

## Точная последовательность DEV18

До mutation: проверить run/point ids, non-Bool положительные `attempt` и
`iteration` (либо `nothing`), portable kind/metadata и представимость `Int`.
Codec writer обязан завершить запись и закрыть все свои handles до возврата;
background writes/sidecars не входят в codec contract. Оба пути YAML и
callback используют один repository protocol.

Весь save, включая выбор generation, barriers и readback, выполняется под
`lock(repository.lock) do ... end`. В `FilesystemRunRepository` добавляется
private `_checkpoint_active::Bool`, начальное `false`; однопараметрический
constructor сохраняется. После получения lock active=true запрещает nested
save того же object с `ArgumentError` до выделения generation/temporary.
Обычная другая task ждёт lock; callbacks могут читать immutable checkpoint
или записать event, но не вызывать nested save. `finally` всегда снимает
active и lock, не удаляя файлы и не маскируя исходную ошибку. Reader lock не
требуется: metadata появляется только после полного payload, старые файлы
immutable; cross-process writer остаётся явной precondition.

| № | Операция под writer lock | Barrier / boundary |
| --- | --- | --- |
| 0 | До `mkpath` найти anchor: ближайший существующий directory начиная с `dirname(repository.root)` и вверх; ancestor выше anchor считается уже устойчивым. Создать checkpoint directory; generation взять выше всех existing named payload/metadata, включая orphan | Root, `run/points/point/checkpoints` и недостающие ancestors не должны потерять свои directory entries |
| 1 | Создать payload temporary в checkpoint directory; закрыть mktemp handle; вызвать codec writer; проверить regular non-symlink; chmod `0640` | `:payload_closed` |
| 2 | Вычислить SHA-256 и byte count закрытого temporary; сохранить точные run/point/generation/attempt в envelope | `:payload_hashed` |
| 3 | fsync payload temporary после chmod/hash | `:payload_synced` |
| 4 | Одним same-directory rename опубликовать immutable payload basename | `:payload_published` |
| 5 | fsync directories снизу вверх: checkpoint directory, point, points, run, repository root и каждый ancestor до anchor включительно | `:payload_ancestry_synced`; payload и вся новая path chain устойчивы до metadata |
| 6 | Создать отдельный metadata temporary в том же каталоге; записать portable envelope и закрыть writer; проверить regular non-symlink; chmod `0640` | `:metadata_closed` |
| 7 | fsync metadata temporary | `:metadata_synced` |
| 8 | Одним same-directory rename опубликовать immutable `NNNNNNNNNNNN.metadata.yaml` | `:metadata_published`; это и есть logical pointer/selection update |
| 9 | fsync checkpoint directory | `:metadata_directory_synced`; commit namespace устойчив |
| 10 | Заново прочитать опубликованный YAML, сопоставить canonical envelope с ожидаемым; проверить exact basename/identity, regular files, payload bytes/SHA; не вызывать codec reader повторно | `:publication_verified` |
| 11 | Вернуть reference, содержащий именно проверенные paths/identity | Единственное успешное writer acknowledgement |

На шаге 5 нельзя ограничиться fsync checkpoint directory: `initialize_run!`
сам не синхронизирует ранее созданные run/points entries. Anchor ищется до
`mkpath`; если root существовал, в цепочку всё равно входит его parent.
Неизвестные родительские mount/ownership/recovery свойства не «чинятся».
Синхронизация directory обязательна после каждого publication boundary;
дополнительные fsync всех status/events/results не нужны для этого контракта.

Publication обоих файлов использует один private primitive
`_publish_runtime_checkpoint_file(source::AbstractString,
destination::AbstractString)::String`: same-directory regular source,
destination отсутствует (`ispath || islink` отклоняется), далее один
`jl_fs_rename` с проверкой libuv error code, без дополнительного chmod.
`_atomic_replace_file` здесь не вызывается: его chmod после file fsync
повторно менял бы inode metadata. При единственном writer и object lock
это immutable publication, не конкурентный POSIX no-replace primitive.
Коллизия — error, без overwrite, `mv`, copy/delete или retry fallback.
Production codec может скопировать исходный payload в temporary как раньше;
это не разрешает копирование как fallback при публикации.

Любая write/close/hash/chmod/fsync/open/rename/readback ошибка прекращает
save без reference; исходная exception пробрасывается, включая ENOSPC/EIO.
Ошибка после metadata rename допускает видимый новый полный checkpoint,
но save не подтверждён. Уже опубликованные payload/metadata, старые поколения,
частичные temporaries и исходные production payload сохраняются. Не применять
`rm` в failure cleanup, не перезаписывать generation, не удалять orphan для
успешного retry. Allocation учитывает named orphan; случайные temporaries
reader игнорирует. Сборка мусора, repair и migration требуют другого ticket.

## Единственный injectable seam

Публичный save делегирует private entry point; тесты не monkeypatch глобальные
методы и не используют изменяемый process-wide hook:

```julia
struct _RuntimeCheckpointIO
    sync_file::Function        # (path::String)::Nothing
    sync_directory::Function   # (path::String)::Nothing
    publish_file::Function     # (source::String, destination::String)::String
    write_metadata::Function   # (path::String, envelope::Dict{String,Any})::Nothing
    cut::Function              # (stage::Symbol, context::NamedTuple)::Nothing
end

_save_runtime_checkpoint!(
    repository::FilesystemRunRepository,
    codec::AbstractCheckpointCodec,
    run_id::AbstractString, point_id::AbstractString,
    attempt::Integer, state, io::_RuntimeCheckpointIO;
    kind::AbstractString = "iteration", iteration = nothing,
    metadata = Dict{String,Any}(),
)

_runtime_checkpoint_io()::_RuntimeCheckpointIO
_sync_runtime_checkpoint_file(path::String)::Nothing
_sync_runtime_checkpoint_directory(path::String)::Nothing
_write_runtime_checkpoint_metadata(path::String, envelope::Dict{String,Any})::Nothing
```

Production `sync_file`/`sync_directory` используют fsync, проверяют код возврата
и пробрасывают `SystemError` при отказе. Они принадлежат generic runtime,
не вызывают scientific `_sync_artifact_*` с silent `!Sys.isunix()` branch.
`publish_file` — описанный primitive; metadata writer — closed YAML write;
production `cut` всегда возвращает `nothing`. Factory `_runtime_checkpoint_io()`
связывает эти defaults и publisher без изменения constructor/public save
signature. General
`_atomic_yaml`, `_immutable_yaml` и `_atomic_replace_file` не получают
неявной durability-семантики; checkpoint metadata идёт через этот seam.

`context` имеет ровно поля `run_id::String`, `point_id::String`, `attempt::Int`,
`generation::Int`, `directory::String`, `payload_temporary::String`,
`payload_path::String`, `metadata_temporary::Union{Nothing,String}`,
`metadata_path::String`. `metadata_temporary=nothing` до шага 6. Hook вызывается
один раз после каждой из десяти названных границ, пока writer держит lock.
Для синтетического отказа hook бросает один заранее созданный exception;
для ENOSPC `write_metadata` закрывает частичный файл и бросает `SystemError`.
Sync/rename adapters бросают до операции при выбранном ordinal call; остальные
вызовы делегируют production implementation. Trace фиксирует порядок и paths.
Отдельного `after_pointer` hook нет: ему точно соответствует
`:metadata_published`. Scientific pointer hooks не вызываются.

## Конечный DEV18 fixture packet

Owning writable paths DEV18: `src/infrastructure/runtime/filesystem_repository.jl`,
existing
`test/infrastructure/yaml_repository_provenance_spans_and_checkpoint_integrity.jl`,
new `test/infrastructure/runtime_checkpoint_durability_faults.jl`, этот документ
для фактических locators. `src/infrastructure/persistence/atomic_files.jl`
остаётся read-only comparison: private publisher находится в runtime file.
Другие production, scientific, schema, coordinator или test harness paths
не включены.

Новый testset `Runtime checkpoint publication faults` использует только
Test/SHA/YAML и реальный выбранный `src/composition/application_runtime.jl`
через source include внутри изолированного test module. Он не включает
`test/support/common.jl`, не импортирует Core/HDF5 и не создаёт substitute
packages. Receipt указывает `realpath` включённого source и source hash;
такой запуск доказывает source-selected implementation, а owning package
import остаётся отдельной проверкой existing fixture. Dependencies/runtime
не устанавливаются. Нет `run_sweep!`, solver, subprocess kill или real crash.

Каждая из следующих **55** cells строится заново в отдельном temporary tree.
Payload ≤1 KiB, metadata ≤4 KiB, совокупный retained output ≤8 MiB; failed
fixtures/trace сохраняются до снятия receipt, не удаляются для rerun/pass.
Это конечная матрица, без автоматического произведения дополнительных осей.

| Cells | Конструкция | Обязательные assertions |
| --- | --- | --- |
| C01–C20 (20) | Десять cuts × два baseline: пусто либо literal old g1/attempt1; candidate g1 либо g2/attempt2 | Exception identity сохранён; reference не возвращён; old bytes неизменны. До `:metadata_published` independent reader даёт ровно old либо `nothing`; начиная с этой границы — ровно complete new в живом synthetic tree. Все cuts сохраняют ожидаемый syscall prefix, partial temporaries и raw files |
| E01–E09 (9) | Partial payload codec ENOSPC; payload fsync EIO; payload publish EIO; первый ancestry directory fsync EIO; partial metadata ENOSPC; metadata fsync EIO; metadata publish EIO; последний directory fsync EIO; same-size corruption опубликованного new payload hook-ом `:metadata_directory_synced`, который возвращает `nothing`. Baseline old g1 | Ни один отказ не возвращает reference; E01–E08 сохраняют точный original error, E09 требует writer readback `CheckpointIntegrityError`. Первые семь дают old; E08 даёт complete new при live read без acknowledgement; E09 — explicit unavailable без fallback. Старый SHA неизменен; metadata ENOSPC не публикует partial metadata. Trace прекращается на отказе; отсутствие copy/delete fallback отдельно проверяется по native rename source |
| R01–R16 (16) | Literal independent v1 trees: missing payload; truncated payload; same-size wrong SHA bytes; malformed digest; missing envelope field; truncated YAML; wrong run; wrong point; metadata filename/generation mismatch; escaped payload filename; wrong extension; attempt0; attemptBool; positive attempt2 при `expected_attempt=1`; metadata symlink; payload symlink | Public production reader отвергает каждое дерево `CheckpointIntegrityError`; independent reader тоже unavailable. Codec reader counter=0. Последнее плохое g2 не скрывается fallback на good g1. Для wrong run/point дерево лежит в запрошенном directory с чужим envelope id |
| R17–R18 (2) | `expected_attempt=0`, `expected_attempt=true` при literal valid tree | `ArgumentError` до payload/codec; ни записи, ни returned checkpoint |
| H01–H05 (5) | Fresh YAML save; второй sequential save; tiny closed callback codec; literal old v1 attempt1 с default и отдельно matching guard; named orphan g2 перед новым save | Без инъекции writer возвращает только после exact full trace. Independent reader требует новый exact identity/payload/SHA; public load возвращает то же state. Default законно читает historical attempt1; explicit matching guard принимает его. Orphan не удалён, новый generation=3. Payload decoder вызывается только после успешной integrity/attempt проверки |
| L01–L03 (3) | Два task save одного object/point с Channel pause первого; error первого и последующий save; nested save в codec callback | Второй task не доходит до allocation/codec до отпускания lock, затем distinct generations. Error освобождает lock/active; orphan учитывается. Nested save получает `ArgumentError` до filesystem mutation, outer raw data сохраняются; следующая обычная запись возможна |

Для H04 baseline attempt1 явно читается как источник будущего context attempt2;
fixture не делает новый solve и не меняет coordinator. Для H05 и L02
generation определяется имеющимися named files, а не числом удачных returns.
H01 обязан включить отсутствующую вложенную `repository.root` и проверить
точную ancestry sync chain до зафиксированного anchor; H02 проверяет existing
path chain. E04 использует отказ первого directory sync, E08 — final sync;
проверка полного healthy trace не позволяет пропустить intermediate parents.

Independent oracle в new fixture сам перечисляет имена с suffix
`.metadata.yaml`, выбирает последнее лексикографически, проверяет его форму
`^[0-9]{12}\.metadata\.yaml$`, читает raw YAML/bytes,
проверяет literal schema/identity/generation/expected attempt, basename,
regular files, длину и `bytes2hex(SHA.sha256(read(payload)))`. Его expected
states задаются literal bytes, а не writer envelope. Он не вызывает
`_validate_checkpoint_envelope`, `_checkpoint_reference`, `file_sha256`,
`load_latest_checkpoint`, codec validator или writer verification helper.
YAML parser и SHA library общие; independence касается selection/identity/
длины/hash assertions, не независимой реализации SHA/YAML. Для malformed
generation oracle возвращает explicit unavailable с причиной и locator.
В R-cells public reader проверяется отдельно от этого oracle. В H-cells
unavailable всегда failure; одной допустимой disjunction недостаточно.

Fault exception в живом процессе не моделирует потерю dirty pages, NFS cache
coherence или power failure. Cut assertions доказывают порядок и fail-closed
чтение существующих bytes; persistence обоснована протоколом и требует
отдельной native проверки на выбранном storage.

## Приёмка и передача

DEV18 становится READY только после независимого CP-DESIGN на этом документе,
согласования exact permitted paths/55-cell matrix и отдельного DEV grant.
Этот документ сам не запускает DEV18. Бюджет исполнения берётся из grant;
не превышать L-JL: две targeted invocations, каждая ≤120 s, 1 CPU/2 GiB,
суммарно ≤4 min, ≤16 MiB temporary/2 MiB logs, либо более строгий master cap.
Первый failed log сохраняется; повтор — только после различающего изменения
в оставшемся общем бюджете. Отсутствующая Julia/YAML/prepared dependency или
компиляция сверх cap оставляет runtime `not_measured`, без install/full suite.

Будущие команды из superproject root, каждая через утверждённый bounded runner:

```sh
julia --startup-file=no --project=julia --threads=1 --check-bounds=yes -e 'include("components/QCLNEGFRunner.jl/test/infrastructure/runtime_checkpoint_durability_faults.jl")'
julia --startup-file=no --project=julia --threads=1 --check-bounds=yes -e 'include("components/QCLNEGFRunner.jl/test/infrastructure/yaml_repository_provenance_spans_and_checkpoint_integrity.jl")'
```

Existing YAML fixture сохраняет immutable provenance, tagged NaN, generation
skip и integrity assertions. Её импорт HDF5/owning package может выйти за
budget; это честный отдельный blocker, не повод ослабить assertions. Ни new
fixture, ни успешный return не закрывают numerical/model/experimental gates,
NFS/real-crash acceptance или S1; EE и strict criteria не меняются.

| Утверждение | Свидетельство | Ограничение | Решение |
| --- | --- | --- | --- |
| Enclosing generic persistence barrier отсутствует | Runner `12e4d025…`, `checkpoint!` → save → YAML rename и callers, перечисленные выше | Source review; runtime не запускался | изменить |
| Existing v1 identity и cross-attempt resume сохраняются | Неизменный schema/reference; default reader и explicit expected_attempt contract | Новая optional guard capability реализуется DEV18; старым bytes durability не приписывается | сохранить |
| Generic publication требует file/ancestry/final directory barriers | Exact sequence и C/E/H/L assertions | Local POSIX conditional guarantee; synthetic failures не power loss | изменить |
| DEV18 имеет конечный независимый reader packet | 55 cells, exact seam, exact source paths и bounded commands | CP-DESIGN и фактический runtime receipt ещё требуются | дополнительно измерить |
| Native NFS/device/real-crash durability установлена | Свидетельство отсутствует | Нельзя заменять successful fsync/exit code native receipt | данных недостаточно |
