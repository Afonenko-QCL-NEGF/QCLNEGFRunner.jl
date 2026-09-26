const CONFIGURATION_ROOT = normpath(joinpath(TEST_ROOT, "fixtures", "configurations"))

function _write_test_file(path, contents)
    mkpath(dirname(path))
    open(path, "w") do stream
        write(stream, contents)
    end
    return path
end
