module Suite_T045
include("../support/common.jl")
using HDF5

@testset "CSV records preserve multiline scientific provenance" begin
    BN = QCLNEGFRunner
    fixture = joinpath(TEST_ROOT, "fixtures", "expert_report")
    header, fixture_rows = BN._read_report_csv(joinpath(fixture, "method_catalog.csv"))
    # Include multiline provenance as a CSV round-trip case.
    # catalog. Its embedded LF is legitimate CSV emitted from YAML text.
    descriptions = [
        "Буквальное плотное вычисление полных дискретных уравнений SCBA.",
        "Алгебраически эквивалентные разреженные, БПФ-, BLAS- и многопоточные\nоператоры.",
        "Проверка \"локальной\" модели, состояния\r\nи спектра.\nВторая строка описания.",
    ]
    mktempdir() do directory
        for (index, separator) in enumerate(("\n", "\r\n"))
            catalog = joinpath(directory, "catalog-$index.csv")
            open(catalog, "w") do stream
                # A BOM before a quoted first header must also be accepted.
                write(stream, '\ufeff', '"', first(header), '"', ',')
                write(stream, join(BN._csv_field.(header[2:end]), ','), separator)
                for (row_index, source_row) in enumerate(fixture_rows)
                    row = copy(source_row)
                    row["description"] = descriptions[row_index]
                    row["summary_path"] = joinpath(fixture, row["summary_path"])
                    write(stream, join(BN._csv_field.([row[key] for key in header]), ','))
                    # Exercise both a final record without a separator and
                    # blank physical lines between records.
                    row_index == length(fixture_rows) || write(stream, separator, separator)
                end
            end
            runs = BN.load_method_catalog(catalog)
            @test getfield.(getfield.(runs, :descriptor), :description) == descriptions
            @test length.(getfield.(runs, :points)) == [2, 2, 2]
            generated = BN.generate_expert_report(
                catalog,
                joinpath(directory, "report-$index");
                reference_id = :direct,
            )
            @test length(generated.comparison.rows) == 12
            @test all(isfile, values(generated.paths))
        end

        field_values = [
            "",
            "обычный текст",
            "запятая, и кавычки \"вместе\"",
            "\n",
            "\r\n",
            "возврат\rкаретки",
            "хвост\n",
        ]
        roundtrip = joinpath(directory, "field-roundtrip.csv")
        # An unquoted empty record is deliberately ignored; explicitly quote
        # an empty field when an empty row must be retained.
        write(
            roundtrip,
            "value\n\"\"\n" * join(BN._report_csv_field.(field_values[2:end]), '\n'),
        )
        _, rows = BN._read_report_csv(roundtrip)
        @test getindex.(rows, "value") == field_values
        write(roundtrip, "value\n\"\"\n" * join(BN._csv_field.(field_values[2:end]), '\n'))
        _, production_rows = BN._read_report_csv(roundtrip)
        @test getindex.(production_rows, "value") == field_values

        for malformed in (
            "a,b\n\"unterminated\nfield,b",
            "a,b\n\"closed\"tail,b\n",
            "a,b\nunquoted\"quote,b\n",
            "a,b\n\"valid\nmultiline\",b,extra\n",
            "a,a\n1,2\n",
            "a,\n1,2\n",
            "",
        )
            invalid = joinpath(directory, "invalid.csv")
            write(invalid, malformed)
            @test_throws ArgumentError BN._read_report_csv(invalid)
        end
    end
end

end # independent suite
