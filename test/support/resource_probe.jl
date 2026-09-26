function _write_resource_fixture(path, value)
    mkpath(dirname(path))
    open(path, "w") do stream
        write(stream, value)
    end
    return path
end
