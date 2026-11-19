using Dates

# Часть подписей интерфейса Documenter 1.17 задана в HTML и JavaScript.
function localize_documenter!(build)
    day = Dates.format(Dates.now(), dateformat"dd.mm.yyyy")
    category_labels = (
        "Page" => "Страница", "Section" => "Раздел", "Function" => "Функция",
        "Method" => "Метод", "Type" => "Тип", "Macro" => "Макрос",
        "Constant" => "Константа", "Module" => "Модуль",
        "Keyword" => "Ключевое слово", "Operator" => "Оператор", "Object" => "Объект",
    )
    doc_labels = Tuple(
        "class=\"docstring-category\">$key</span>" => "class=\"docstring-category\">$label</span>"
        for (key, label) in category_labels
    )
    page_labels = (
        "Search docs (Ctrl + /)" => "Поиск по документации (Ctrl + /)",
        "Search · " => "Поиск · ",
        ">Search</" => ">Поиск</",
        ">Theme</" => ">Тема</",
        ">Automatic (OS)</" => ">Как в системе</",
        ">documenter-light</" => ">Светлая</",
        ">documenter-dark</" => ">Тёмная</",
        ">catppuccin-latte</" => ">Catppuccin Latte</",
        ">catppuccin-frappe</" => ">Catppuccin Frappé</",
        ">catppuccin-macchiato</" => ">Catppuccin Macchiato</",
        ">catppuccin-mocha</" => ">Catppuccin Mocha</",
        ">Settings</" => ">Настройки</",
        ">Version</" => ">Версия</",
        "title=\"Settings\"" => "title=\"Настройки\"",
        "View the repository on GitHub" => "Репозиторий на GitHub",
        "Collapse all docstrings" => "Свернуть все описания",
        "title=\"Permalink\"" => "title=\"Постоянная ссылка\"",
        "Documentation for " => "Документация ",
        "This document was generated with " => "Документ создан с помощью ",
        "Documenter.jl</a> version " => "Documenter.jl</a> версии ",
        " on <span class=\"colophon-date\"" => ", <span class=\"colophon-date\"",
        r"""<span class="colophon-date" title="[^"]+">[^<]+</span>""" =>
            "<span class=\"colophon-date\">$day</span>",
        "Using Julia version " => "Версия Julia — ",
        r"""<script src="(?:\.\./)*(?:siteinfo|versions)\.js"></script>""" => "",
    )
    for (directory, _, names) in walkdir(build), name in names
        endswith(name, ".html") || continue
        path = joinpath(directory, name)
        write(path, replace(read(path, String), page_labels..., doc_labels...))
    end

    js = joinpath(build, "assets", "documenter.js")
    script = read(js, String)
    categories = "({" * join(("$(lowercase(key)): \"$label\"" for (key, label) in category_labels), ", ") * "})"
    filter_display = "<span>\${$categories[val.toLowerCase()] || val}</span>"
    result_display = "class=\"property-search-result-badge\">\${$categories[result.category.toLowerCase()] || result.category}"
    script_labels = (
        "placeholder=\"Search\"" => "placeholder=\"Поиск\"",
        "Type something to get started!" => "Введите запрос.",
        "</kbd> to search" => "</kbd> — поиск",
        "</kbd> to close" => "</kbd> — закрыть",
        "</kbd> to navigate" => "</kbd> — перемещение",
        "</kbd> to select" => "</kbd> — выбрать",
        "No result found!" => "Ничего не найдено.",
        ">Filters:</span>" => ">Фильтры:</span>",
        "\"1 result\"" => "\"Результатов: 1\"",
        "\"200+ results\"" => "\"Результатов: 200+\"",
        "count + \" results\"" => "\"Результатов: \" + count",
        "0 result(s)" => "Результатов: 0",
        "Copy this code block" => "Копировать этот блок кода",
        "\"title\", \"Copy\"" => "\"title\", \"Копировать\"",
        "Collapse all docstrings" => "Свернуть все описания",
        "Expand all docstrings" => "Развернуть все описания",
        "selected_filter = \$(this).text().toLowerCase();" =>
            "selected_filter = \$(this).attr(\"data-category\").toLowerCase();",
        "class=\"search-filter search-filter-selected\"><span>\${val}</span>" =>
            "class=\"search-filter search-filter-selected\" data-category=\"\${val}\">$filter_display",
        "class=\"search-filter\"><span>\${val}</span>" =>
            "class=\"search-filter\" data-category=\"\${val}\">$filter_display",
        "class=\"property-search-result-badge\">\${result.category}" => result_display,
    )
    write(js, replace(script, script_labels...))
end
