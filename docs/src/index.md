# QCLNEGFRunner

QCLNEGFRunner 0.2.0 запускает расчёты [QCLNEGF.jl](https://github.com/Afonenko-QCL-NEGF/QCLNEGF.jl)
на Julia 1.13.x и отвечает за хранение и представление результатов.

Начните с [конфигурации](@ref yaml-run-configurations), затем прочитайте разделы
о [результатах и возобновлении](@ref native-result-formats) и
[ограничениях ресурсов](@ref resource-planning). В разделе
[«Архитектура»](@ref developer-architecture) описаны обязанности компонентов,
а в [справочнике API](api/public.md) перечислены поддерживаемые интерфейсы.
Уравнения физической модели и работа решателя в памяти описаны в документации Core.
