# Native capture зависимостей

`tools/prepare_depot.jl` сохраняет прежнюю подготовку без builds/autoprecompile, включает lazy
artifacts и проверяет их native tree hashes. Новый явный argv `--facts ABSOLUTE_NEW_FILE` включает
bounded raw observation output для Root v2 producer; это не scientific workflow и не approval.

Этот режим требует canonical Project/Manifest, isolated LOAD_PATH, один fresh depot, отсутствие
custom local preferences/selectors/overrides. Root выбирает exact pinned Nix Julia и immutable
selected project; произвольный JULIA/VERSION не доказывает qualification. Все external package
source trees сверяются с frozen Manifest; native artifact aliases/selector source/augmentation,
effective preferences, selected artifact trees и platform записываются без download credentials. Raw
facts создаются O_EXCL/0600 с file/parent fsync. Manifest до/после не меняется.

Current locked HDF5/MPI native-default selection сохраняется. Unknown external closure требует
SOURCE review и actual native qualification Root; raw facts file не usable depot metadata. Custom
local modes остаются explicit qualification-needed, не silently очищаются. Registry reachable
presence и captured immutable archive — отдельные факты, не заранее pinned registry-tree proof.
Actual execution этого native capture/offline installCheck — отдельные gates.
