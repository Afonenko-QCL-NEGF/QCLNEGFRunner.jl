# QCLNEGFRunner.jl

Запуск расчётов и хранение результатов [QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl)
версии **0.2.0** на Julia **1.13.x**. Runner проверяет входные файлы YAML, фиксирует
научные планы, выполняет расчёты, контролирует ограничения процесса по ресурсам,
записывает проверенные результаты и контрольные точки HDF5 и анализирует
сохранённые данные. За построение графиков отвечает необязательное расширение
CairoMakie.

Точные версии зависимостей конкретного расчёта записаны в его окружении
в файле `Manifest.toml`.

## Запуск

Подготовьте окружение пакета из опубликованной рабочей копии:

```console
julia --project=. -e 'using Pkg; Pkg.instantiate()'
bin/qcl-negf plan examples/config/operator-algebra.yaml > plan.json
bin/qcl-negf run-plan plan.json result
bin/qcl-negf analyze result analysis
```

В определении исследования укажите источники конфигурации и оси температуры
и напряжения. Команда `run-plan PLAN OUTPUT --execution-id ID` выбирает
идентификатор из `plan.executions`. Независимые расчёты можно запускать отдельно.
При продолжении по рабочим точкам внутри одного расчёта точки выполняются
последовательно. На одну задачу Slurm приходится один процесс Julia.
Задайте `JULIA_NUM_THREADS` равным числу процессоров, выделенных задаче.

Код выхода 0 означает завершение процесса. Прежде чем использовать результат
как научное свидетельство, проверьте состояния расчёта и точек, показатели
качества и критерии физической приёмки. HDF5 требуется для работы Runner.
Для построения графиков загрузите CairoMakie в активном окружении Julia.

### Сквозная проверка стационарного расчёта

Из рабочей копии Runner с окружением, подготовленным средствами Pkg:

```sh
export JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
bin/qcl-negf plan examples/config/stationary-smoke.yaml --max-runs 1 > plan.json
bin/qcl-negf run-plan plan.json stationary-result
bin/qcl-negf analyze stationary-result stationary-report
```

Пример выполняет ограниченную диагностику для опубликованной структуры при 70 K
и 48 мВ на период. Малая сетка и предел в две итерации SCBA на внешний шаг
заданы явно. Диагностический режим допускает продолжение при неполном
энергетическом покрытии. Полученные значения служат для проверки сквозной записи
и чтения. Поля `resolved_configuration` и `effective_inputs` в
`plan.json` показывают фактически применённые параметры. Сохраните исходный
YAML, файл `Manifest.toml` и ревизию рабочей копии Runner вместе с результатом.
Раздел Core в `Manifest.toml` фиксирует выбранную Pkg ревизию, а
`metadata/toolchain_json` в HDF5 связывает результат с контрольной суммой манифеста.

В `stationary-report/report.md` приведены состояние точки, итерационная
сходимость, физические проверки и научная приёмка. Невязки сохраняются в файлах
истории. Файлы формата Runner можно независимо прочитать командой
`qcl-negf-results render POINT/artifacts OUTPUT`, где `POINT` — каталог из
`points[].data.artifact_root` в `series_result.json` относительно корня
результата.

При работе из Julia импортируйте `QCLNEGF` для научных типов и численных функций
и `QCLNEGFRunner` для средств запуска и записи. Core использует только зависимости
для численных расчётов. Runner зависит от Core.

## Разработка и установка

```console
deno task check
deno task test
deno task docs
```

Точные версии зависимостей окружения выпуска фиксирует манифест, который создаёт
Pkg. Тесты проверяют отклонение ошибочных конфигураций, сохранение данных,
точное возобновление, границы ответственности компонентов и публичный интерфейс
командной строки. Репозиторий [qcl-negf-platform](https://github.com/Afonenko-QCL-NEGF/qcl-negf-platform)
отвечает за установку на NixOS и доверенные локальные исполнители GitHub Actions.
Репозитории исходного кода размещены на GitHub.

Чтобы разрабатывать оба пакета из соседних рабочих копий, создайте отдельное
окружение интеграции. Файлы проектов пакетов при этом остаются прежними:

```console
julia tools/prepare_workspace.jl ../QCLNEGF.jl . ../qcl-negf-env
QCL_NEGF_PROJECT=/absolute/path/to/qcl-negf-env deno task test
QCL_NEGF_PROJECT=/absolute/path/to/qcl-negf-env deno task docs
```

При вызове `bin/qcl-negf` из этого окружения используйте то же значение
`QCL_NEGF_PROJECT`. Манифест создаётся в окружении интеграции. При отдельной
установке Runner использует точный коммит Core из раздела `[sources]`.

Работа Runner описана в разделах [конфигурация](docs/src/user/configuration.md),
[результаты и возобновление](docs/src/user/results.md),
[ограничения ресурсов](docs/src/user/resources.md) и
[архитектура](docs/src/developer/architecture.md). Уравнения физической модели
и независимые численные операторы описаны в
[документации QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl/tree/main/docs/src).

Схема конфигурации запуска принадлежит Runner. Общий контракт результатов
определён в репозитории [qcl-negf-contracts](https://github.com/Afonenko-QCL-NEGF/qcl-negf-contracts).
Пакет [qcl-negf-results](https://github.com/Afonenko-QCL-NEGF/qcl-negf-results) читает
опубликованные данные из Python. Научные исследования хранятся в репозитории
[qcl-negf-research](https://github.com/Afonenko-QCL-NEGF/qcl-negf-research).

Лицензия MIT.
