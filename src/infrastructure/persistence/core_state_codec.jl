# Public Core payload closure, serialization only. Core owns numerical validation.
const _P04_CONTRACT="qcl-negf.results.v2"
const _P04_LAYOUT="94561e874a62ad0749be8a13645ef0142994e074b33d271cbd57807f2cf63600"
const _P04_SCHEMAS=Dict("manifest"=>"qcl-negf.result-manifest.v1","pointer"=>"qcl-negf.result-pointer.v1",
    "catalog"=>"qcl-negf.scientific-catalog.v1","record"=>"qcl-negf.scientific-record.v1",
    "checkpoint"=>"qcl-negf.checkpoint-declaration.v1")
_p04_require(ok,message)=ok || throw(ArgumentError(message))
_p04_count(x)=string(UInt64(x))
function _p04_u64(value;positive=false)
    _p04_require(value isa String && occursin(r"^(?:0|[1-9][0-9]*)\z",value),"noncanonical result count")
    number=tryparse(UInt64,value)
    _p04_require(number!==nothing && (!positive || number>0),"result count out of range")
    number
end
_p04_id(value)=_p04_require(value isa String && occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z",value),"invalid result ID")
function _p04_shape(value)
    _p04_require(value isa AbstractVector,"invalid array shape")
    Tuple(begin
        n=_p04_u64(dimension);_p04_require(n<=typemax(Int),"array axis exceeds reader index width");Int(n)
    end for dimension in value)
end
function _p04_file_fields(reference)
    _p04_keys(reference,("path","bytes","sha256","media_type","schema"))
    _p04_u64(reference["bytes"])
    _p04_require(reference["sha256"] isa String && occursin(r"^[0-9a-f]{64}\z",reference["sha256"]) &&
        all(reference[k] isa String && !isempty(reference[k]) for k in ("path","media_type","schema")),"invalid FileRef strings")
    reference
end
Base.@nospecializeinfer function _p04_json(io,@nospecialize(value))
    if value isa AbstractDict
        _p04_require(all(k->k isa String,keys(value)),"JSON keys must be strings")
        print(io,'{')
        for (i,key) in enumerate(sort!(collect(keys(value))))
            i==1 || print(io,',');_light_json(io,key);print(io,':');_p04_json(io,value[key])
        end
        print(io,'}')
    elseif value isa Union{Tuple,AbstractVector}
        print(io,'[')
        for (i,item) in enumerate(value);i==1 || print(io,',');_p04_json(io,item);end
        print(io,']')
    else
        _p04_require(value===nothing || value isa Union{String,Bool,Integer} ||
            value isa AbstractFloat && isfinite(value),"unsupported/nonfinite JSON value")
        value isa String && _p04_require(isvalid(value),"invalid UTF-8")
        _light_json(io,value)
    end
end
_p04_json(value)=sprint(_p04_json,value)

# Strict finite JSON reader: no YAML features, duplicate keys or arbitrary construction.
function _p04_parse(text::String)
    _p04_require(isvalid(text),"invalid UTF-8 JSON")
    chars=collect(text);pos=Ref(1)
    peek()=pos[]>length(chars) ? '\0' : chars[pos[]]
    skip()=while peek() in (' ','\n','\r','\t');pos[]+=1;end
    function string_value()
        _p04_require(peek()=='"',"expected JSON string");pos[]+=1;io=IOBuffer()
        while peek()!='"'
            c=peek();_p04_require(c>=' ',"unterminated/control JSON string");pos[]+=1
            if c=='\\'
                c=peek();pos[]+=1
                if c=='u'
                    function hex4()
                        _p04_require(pos[]+3<=length(chars),"short unicode escape")
                        s=String(chars[pos[]:pos[]+3]);pos[]+=4
                        _p04_require(occursin(r"^[0-9a-fA-F]{4}\z",s),"bad unicode escape")
                        parse(UInt32,s;base=16)
                    end
                    code=hex4()
                    if 0xd800<=code<=0xdbff
                        _p04_require(peek()=='\\' && pos[]<length(chars) && chars[pos[]+1]=='u',"missing surrogate")
                        pos[]+=2;low=hex4();_p04_require(0xdc00<=low<=0xdfff,"bad surrogate")
                        code=0x10000+((code-0xd800)<<10)+(low-0xdc00)
                    else
                        _p04_require(!(0xdc00<=code<=0xdfff),"unpaired surrogate")
                    end
                    print(io,Char(code));continue
                end
                escaped=Dict('"'=>'"','\\'=>'\\','/'=>'/','b'=>'\b','f'=>'\f','n'=>'\n','r'=>'\r','t'=>'\t')
                _p04_require(haskey(escaped,c),"bad JSON escape");c=escaped[c]
            end
            print(io,c)
        end
        pos[]+=1;String(take!(io))
    end
    function value(depth=0)
        _p04_require(depth<=256,"JSON nesting exceeds bound");skip();c=peek()
        if c=='"';return string_value()
        elseif c=='{' || c=='['
            object=c=='{';pos[]+=1;skip();out=object ? Dict{String,Any}() : Any[];finish=object ? '}' : ']'
            if peek()==finish;pos[]+=1;return out;end
            while true
                if object
                    key=string_value();skip();_p04_require(peek()==':',"expected colon");pos[]+=1
                    _p04_require(!haskey(out,key),"duplicate JSON key");out[key]=value(depth+1)
                else;push!(out,value(depth+1));end
                skip();peek()==finish && (pos[]+=1;return out)
                _p04_require(peek()==',',"expected comma");pos[]+=1;skip()
            end
        end
        start=pos[]
        while peek()!='\0' && !(peek() in (' ',',',']','}','\n','\r','\t'));pos[]+=1;end
        token=String(chars[start:pos[]-1])
        token=="true" && return true;token=="false" && return false;token=="null" && return nothing
        _p04_require(occursin(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z",token),"invalid JSON token")
        number=occursin(r"[.eE]",token) ? tryparse(Float64,token) : tryparse(Int64,token)
        _p04_require(number!==nothing && isfinite(number),"JSON number out of range");number
    end
    result=value();skip();_p04_require(pos[]>length(chars),"trailing JSON bytes");result
end

# Explicit owning display context reproduces the published graph, independent of Main imports.
_p04_type_text(T)=sprint(show,T;context=:module=>QCLNEGF)
_p04_typeid(T)=T===Any ? "Any" : T===QCLNEGF.CoreDatum ? "CoreDatum" :
    T isa Union ? "Union_"*bytes2hex(sha256(_p04_type_text(T)))[1:16] :
    T<:QCLNEGF.CoreArray ? "CoreArray{"*_p04_type_text(eltype(fieldtype(T,2)))*"}" :
    isempty(T.parameters) ? string(nameof(T)) : "Type_"*bytes2hex(sha256(_p04_type_text(T)))[1:16]
_p04_numeric(T)=T in (Bool,Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64,Float32,Float64,ComplexF32,ComplexF64)
function _p04_layout()
    types=Dict{String,Any}();nodes=Dict{String,Any}();contexts=Set{Tuple{String,Bool}}()
    Base.@nospecializeinfer function visit(@nospecialize(T);allow_any=false)
        _p04_require(T!==Any || allow_any,"unqualified Any in public layout")
        id=_p04_typeid(T);(id,allow_any) in contexts && return id
        push!(contexts,(id,allow_any));types[id]=T
        nodes[id]=if T===Any;Dict("kind"=>"dynamic","scope"=>"SCBAResult.restart_contract")
        elseif T===QCLNEGF.CoreDatum
            variants=Any[QCLNEGF.CoreScalar,QCLNEGF.CoreList,QCLNEGF.CoreRecord]
            append!(variants,(QCLNEGF.CoreArray{U} for U in Base.uniontypes(Base.unwrap_unionall(QCLNEGF.CoreArray).parameters[1].ub)))
            Dict("kind"=>"union","variants"=>visit.(variants))
        elseif T isa Union;Dict("kind"=>"union","variants"=>[visit(U;allow_any) for U in Base.uniontypes(T)])
        elseif T===Nothing;Dict("kind"=>"nothing")
        elseif T===Bool;Dict("kind"=>"bool")
        elseif T===String;Dict("kind"=>"string")
        elseif T===Symbol;Dict("kind"=>"symbol")
        elseif T<:Integer;Dict("kind"=>"integer","type"=>string(T),"bits"=>8sizeof(T),"signed"=>T<:Signed)
        elseif T in (Float32,Float64);Dict("kind"=>"ieee","type"=>T===Float64 ? "f64" : "f32","digits"=>2sizeof(T))
        elseif T<:Complex;Dict("kind"=>"complex","component"=>visit(T.parameters[1]))
        elseif T<:Unitful.AbstractQuantity;Dict("kind"=>"quantity","unit"=>string(unit(zero(T))),"value"=>visit(T.parameters[1]))
        elseif T<:AbstractArray
            Dict("kind"=>"array","eltype"=>_p04_type_text(eltype(T)),"rank"=>ndims(T),"element"=>visit(eltype(T)),"storage"=>_p04_numeric(eltype(T)) ? "dataset" : "items")
        elseif T<:Tuple
            p=collect(T.parameters)
            if length(p)==1 && Base.isvarargtype(p[1])
                v=p[1];e=visit(v.T);isdefined(v,:N) ? Dict("kind"=>"tuple","elements"=>fill(e,v.N)) : Dict("kind"=>"tuple","element"=>e)
            else;Dict("kind"=>"tuple","elements"=>visit.(p));end
        elseif T<:AbstractDict
            Dict("kind"=>"dict","key"=>visit(T.parameters[1]),"value"=>visit(T.parameters[2];allow_any))
        elseif isstructtype(T) && (parentmodule(T)===parentmodule(QCLNEGF.ExactSolverState) ||
                T<:Pair || parentmodule(T)===parentmodule(QCLNEGF.PhysicalParameters))
            Dict("kind"=>"struct","julia_type"=>_p04_type_text(T),"fields"=>[
                Dict("name"=>string(n),"type"=>visit(U;allow_any=(T===QCLNEGF.SCBAResult && n===:restart_contract)))
                for (n,U) in zip(fieldnames(T),fieldtypes(T))])
        else;throw(ArgumentError("unsupported public Core type $T"));end
        id
    end
    roots=[visit(getproperty(QCLNEGF,n)) for n in (:ExactExecutionIdentity,:ExactRestartIdentity,:ExactSolverState,
        :ScientificHistorySnapshot,:SolverEvent,:CompletedStateEvidence,:CoreDatum)]
    _p04_require(bytes2hex(sha256(_p04_json(Dict("nodes"=>nodes,"roots"=>roots))))==_P04_LAYOUT,"unsupported Core layout")
    (;nodes,types)
end
const _p04_public_layout=Ref{Any}(nothing)
const _p04_read_observer=Ref{Function}((kind,path,bytes)->nothing)
function _p04_types()
    _p04_public_layout[]===nothing && (_p04_public_layout[]=_p04_layout())
    _p04_public_layout[]
end

# File paths are relative to one captured root. Reject every symlink component.
function _p04_path(root,relative)
    _p04_require(relative isa String && !isempty(relative) && !occursin(r"[\\\x00]",relative) && !isabspath(relative),"unsafe relative path")
    parts=split(relative,'/');_p04_require(all(p->!(p in ("",".","..")),parts),"unsafe path component")
    path=root
    for p in parts;path=joinpath(path,p);_p04_require(!islink(path),"symlink path rejected");end
    path
end
_p04_relative(root,path)=replace(relpath(path,root),'\\'=>'/')
function _p04_ref(root,path,schema;media="application/json")
    _p04_read_observer[](:hash,path,filesize(path))
    Dict{String,Any}("path"=>_p04_relative(root,path),"bytes"=>_p04_count(filesize(path)),
        "sha256"=>bytes2hex(open(sha256,path)),"media_type"=>media,"schema"=>schema)
end
function _p04_check_ref(root,ref)
    _p04_file_fields(ref)
    path=_p04_path(root,ref["path"])
    _p04_require(isfile(path) && filesize(path)==parse(UInt64,ref["bytes"]) && bytes2hex(open(sha256,path))==ref["sha256"],"FileRef bytes/hash differ")
    path
end
function _p04_remember!(verified,root,ref)
    verified[ref["path"]]=(;reference=deepcopy(ref),signature=_p04_stat(stat(_p04_path(root,ref["path"]))))
end
function _p04_keys(value,names)
    _p04_require(value isa AbstractDict && Set(keys(value))==Set(names),"unknown or missing fields")
end
function _p04_identity(value)
    _p04_keys(value,("run_id","execution_id","point_id","attempt","branch_id","model_sha256","plan_sha256"))
    for name in ("run_id","execution_id","point_id","branch_id")
        _p04_id(value[name])
    end
    _p04_u64(value["attempt"];positive=true)
    for name in ("model_sha256","plan_sha256");_p04_require(value[name] isa String && occursin(r"^[0-9a-f]{64}\z",value[name]),"invalid scientific digest");end
    value
end

# HDF5's default Bool is BITFIELD. Native5 explicitly uses the interoperable enum.
function _p04_bool_type()
    lock(HDF5.API.liblock)
    type=try
        HDF5.Datatype(ccall((:H5Tenum_create,HDF5.API.libhdf5),HDF5.API.hid_t,(HDF5.API.hid_t,),HDF5.API.H5T_STD_U8LE))
    finally;unlock(HDF5.API.liblock);end
    HDF5.API.h5t_enum_insert(type,"FALSE",Ref(UInt8(0)))
    HDF5.API.h5t_enum_insert(type,"TRUE",Ref(UInt8(1)));type
end
function _p04_write_array(parent,name,values)
    T=eltype(values);_p04_require(_p04_numeric(T),"unsupported array dtype")
    shape=size(values);block=_serialization_block(shape,sizeof(T));type=T===Bool ? _p04_bool_type() : HDF5.datatype(T)
    space=HDF5.dataspace(reverse(shape))
    dataset=try
        isempty(values) ? HDF5.create_dataset(parent,name,type,space) :
            HDF5.create_dataset(parent,name,type,space;chunk=reverse(_serialization_block(shape,4sizeof(T))),shuffle=true,deflate=1)
    finally;close(type);close(space);end
    try
        for starts in Iterators.product((1:block[a]:shape[a] for a in eachindex(shape))...)
            ranges=ntuple(a->starts[a]:min(starts[a]+block[a]-1,shape[a]),length(shape))
            slab=Array(PermutedDimsArray(view(values,ranges...),reverse(ntuple(identity,length(shape)))))
            if T===Bool
                mem=HDF5.dataspace(slab);disk=HDF5.hyperslab(dataset,reverse(ranges)...);dtype=HDF5.datatype(dataset)
                try;HDF5.API.h5d_write(dataset,dtype,mem,disk,HDF5.API.H5P_DEFAULT,slab)
                finally;close(mem);close(disk);close(dtype);end
            else;dataset[reverse(ranges)...]=slab;end
        end
    finally;close(dataset);end
end
function _p04_metadata(file,identity,invocation,schema,role,representation)
    meta=create_group(file,"metadata")
    for (key,value) in ("schema"=>schema,"schema_version"=>"5.0","contract_set"=>_P04_CONTRACT,
            "artifact_role"=>role,"representation"=>representation,"core_layout_sha256"=>_P04_LAYOUT)
        attributes(meta)[key]=value
    end
    meta["identity_json"]=_p04_json(identity);meta["invocation_json"]=_p04_json(invocation);close(meta)
end

Base.@nospecializeinfer function _p04_encode(@nospecialize(value),arrays;allow_any=false)
    allow_any && _p04_require(value===nothing || value isa Union{Bool,String,Int64,Float64,Symbol} ||
        value isa AbstractDict && keytype(value)===String,"unsupported scoped restart-contract value")
    T=typeof(value);layout=_p04_types();id=_p04_typeid(T)
    known=haskey(layout.types,id) || T<:Tuple && any(U->U<:Tuple && T<:U,values(layout.types))
    _p04_require(known || allow_any,"unknown Core type $T")
    value===nothing && return nothing;value isa Bool && return value;value isa String && return value
    value isa Symbol && return Dict("kind"=>"symbol","value"=>string(value))
    value isa Integer && return Dict("kind"=>"integer","type"=>string(T),"decimal"=>string(value))
    value isa AbstractFloat && return Dict("kind"=>"ieee","type"=>T===Float64 ? "f64" : "f32",
        "bits"=>string(reinterpret(T===Float64 ? UInt64 : UInt32,value);base=16,pad=2sizeof(T)))
    value isa Complex && return Dict("kind"=>"complex","real"=>_p04_encode(real(value),arrays),"imag"=>_p04_encode(imag(value),arrays))
    value isa Unitful.AbstractQuantity && return Dict("kind"=>"quantity","unit"=>string(unit(value)),"value"=>_p04_encode(ustrip(value),arrays))
    value isa Tuple && return [_p04_encode(x,arrays;allow_any) for x in value]
    if value isa AbstractArray
        out=Dict{String,Any}("kind"=>"array","eltype"=>_p04_type_text(eltype(value)),"shape"=>string.(collect(size(value))),"order"=>"F")
        if _p04_numeric(eltype(value))
            index=length(arrays)+1;dataset="/arrays/a"*lpad(string(index),8,'0');push!(arrays,(dataset,value))
            out["file"]=nothing;out["dataset"]=dataset
        else;out["values"]=[_p04_encode(x,arrays;allow_any) for x in vec(value)];end
        return out
    elseif value isa AbstractDict
        _p04_require(keytype(value) in (String,Symbol),"unsupported dictionary key type")
        return Dict("kind"=>"dict","entries"=>[Dict("key"=>_p04_encode(k,arrays),"value"=>_p04_encode(value[k],arrays;allow_any)) for k in sort!(collect(keys(value));by=string)])
    end
    _p04_require(haskey(layout.types,id),"unsupported dynamic Core object")
    fields=Dict{String,Any}()
    for n in fieldnames(T)
        fields[string(n)]=_p04_encode(getfield(value,n),arrays;allow_any=(T===QCLNEGF.SCBAResult && n===:restart_contract))
    end
    Dict{String,Any}("type"=>id,"fields"=>fields)
end
function _p04_bind_arrays!(wire,ref)
    if wire isa AbstractDict
        get(wire,"kind",nothing)=="array" && haskey(wire,"file") && (wire["file"]=deepcopy(ref))
        for child in values(wire);_p04_bind_arrays!(child,ref);end
    elseif wire isa AbstractVector;for child in wire;_p04_bind_arrays!(child,ref);end;end
    wire
end

struct VerifiedExactCheckpoint
    root::String
    reference_json::String
    manifest_json::String
    declaration_json::String
    verified::Dict{String,Any}
    function VerifiedExactCheckpoint(root,ref,manifest,declaration,verified,::Val{:verified})
        new(root,_p04_json(ref),_p04_json(manifest),_p04_json(declaration),verified)
    end
end
checkpoint_reference(handle::VerifiedExactCheckpoint)=_p04_parse(handle.reference_json)

_p04_stat(s)=(s.device,s.inode,s.size,s.mtime,s.ctime)
function _p04_read_scalar_json(meta,name,budget,path)
    dataset=meta[name];dtype=space=nothing
    try
        _p04_require(dataset isa HDF5.Dataset,"native JSON metadata is not a dataset")
        dtype=HDF5.datatype(dataset);space=HDF5.dataspace(dataset)
        _p04_require(HDF5.API.h5s_get_simple_extent_type(space)==HDF5.API.H5S_SCALAR &&
            HDF5.API.h5t_get_class(dtype)==HDF5.API.H5T_STRING && !HDF5.API.h5t_is_variable_str(dtype),
            "unsupported native JSON metadata: fixed scalar string required")
        bytes=HDF5.API.h5t_get_size(dtype)
        _p04_require(bytes<=typemax(Int) && (budget===nothing || bytes<=budget[]),"native JSON metadata byte budget exceeded")
        budget===nothing || (budget[]-=Int(bytes))
        _p04_read_observer[](:scalar_json,path,Int(bytes))
        _p04_parse(read(dataset,String))
    finally
        for object in (space,dtype,dataset);object===nothing || close(object);end
    end
end
function _p04_open_hdf(root,ref,verified;identity=nothing,invocation=nothing,representation=nothing,metadata_budget=nothing)
    _p04_file_fields(ref)
    roles=Dict("qcl-negf-scientific-history-v5"=>"science.history","qcl-negf-checkpoint-v5"=>"recovery","qcl-negf-physics-v5"=>"physics.full")
    _p04_require(ref["media_type"]=="application/x-hdf5" && haskey(roles,ref["schema"]),"unsupported native5 array format")
    path=_p04_path(root,ref["path"]);_p04_require(isfile(path),"missing native payload")
    file=h5open(path,"r")
    try
        _p04_require(Sys.isunix(),"same-open native verification requires qualified Unix sec2 driver")
        fdptr=HDF5.API.h5f_get_vfd_handle(file,HDF5.API.H5P_DEFAULT)
        descriptor=unsafe_load(convert(Ptr{Cint},fdptr));stream=Base.fdio(descriptor,false)
        try
            signature=_p04_stat(stat(stream));_p04_require(signature==_p04_stat(stat(path)),"path rebound during open")
            known=get(verified,ref["path"],nothing)
            _p04_require(known===nothing || known.reference==ref && known.signature==signature,
                "verified immutable payload changed; reopen source explicitly")
            if known===nothing || known.reference!=ref || known.signature!=signature
                _p04_read_observer[](:hash,path,signature[3])
                position=Base.position(stream);seekstart(stream)
                hash=try;bytes2hex(sha256(stream));finally;seek(stream,position);end
                _p04_require(string(signature[3])==ref["bytes"] && hash==ref["sha256"],"native payload bytes/hash differ")
                verified[ref["path"]]=(;reference=deepcopy(ref),signature)
            end
            _p04_require(signature==_p04_stat(stat(stream)) && signature==_p04_stat(stat(path)),"native payload changed during hash")
        finally;close(stream);end
        _p04_read_observer[](:native_metadata,path,0)
        _require_internal_hdf5_storage(file;maximum_depth=2,maximum_group_entries=typemax(Int),maximum_links=typemax(Int))
        meta=file["metadata"]
        try
            _p04_require(read_attribute(meta,"schema")==ref["schema"] &&
                read_attribute(meta,"schema_version")=="5.0" && read_attribute(meta,"contract_set")==_P04_CONTRACT &&
                read_attribute(meta,"core_layout_sha256")==_P04_LAYOUT &&
                read_attribute(meta,"artifact_role")==roles[ref["schema"]],"unsupported native5 metadata/layout/role")
            actual=read_attribute(meta,"representation")
            _p04_require(actual in ("array_payload","record_leaf") && (representation===nothing || actual==representation) &&
                (actual=="array_payload" || ref["schema"]=="qcl-negf-scientific-history-v5") &&
                Set(keys(file))==Set(("metadata",actual=="array_payload" ? "arrays" : "records")),"unsupported native5 representation/tree")
            identity===nothing || _p04_require(_p04_read_scalar_json(meta,"identity_json",metadata_budget,path)==identity,"native payload identity differs")
            invocation===nothing || _p04_require(_p04_read_scalar_json(meta,"invocation_json",metadata_budget,path)==invocation,"native payload invocation differs")
        finally;close(meta);end
        _p04_require(verified[ref["path"]].signature==_p04_stat(stat(_p04_path(root,ref["path"]))),"native path changed during verification")
        file
    catch
        close(file);rethrow()
    end
end

function _p04_read_array(wire,T,context)
    _p04_keys(wire,("kind","eltype","shape","order","file","dataset"))
    ref=wire["file"];_p04_require(haskey(context.references,ref["path"]) && context.references[ref["path"]]==ref,"undeclared array dependency")
    _p04_require(wire["dataset"] isa String && startswith(wire["dataset"],"/arrays/") &&
        !occursin(r"[\\\x00]",wire["dataset"]) && all(x->!(x in ("",".","..")),split(wire["dataset"][2:end],'/')),"invalid array dataset")
    file=get!(context.files,ref["path"]) do
        _p04_open_hdf(context.root,ref,context.verified;metadata_budget=hasproperty(context,:metadata_budget) ? context.metadata_budget : nothing)
    end
    dataset=file[wire["dataset"]]
    try
        _p04_require(dataset isa HDF5.Dataset,"array locator is not a dataset")
        shape=_p04_shape(wire["shape"])
        E=eltype(T);_p04_require(wire["kind"]=="array" && wire["eltype"]==_p04_type_text(E) && wire["order"]=="F" && length(shape)==ndims(T) &&
            all(>=(0),shape) && size(dataset)==reverse(shape),"array shape/eltype/order mismatch")
        dtype=HDF5.datatype(dataset)
        try
            class=HDF5.API.h5t_get_class(dtype)
            if E===Bool
                expected=_p04_bool_type()
                try;_p04_require(class==HDF5.API.H5T_ENUM && HDF5.API.h5t_equal(dtype,expected),"invalid Boolean enum")
                finally;close(expected);end
            else
                expected=HDF5.datatype(E)
                try;_p04_require(HDF5.API.h5t_equal(dtype,expected),"native array dtype differs");finally;close(expected);end
            end
        finally;close(dtype);end
        context.validate_only && return nothing
        out=Array{E}(undef,shape);isempty(out) && return out
        block=_serialization_block(shape,sizeof(E))
        for starts in Iterators.product((1:block[a]:shape[a] for a in eachindex(shape))...)
            ranges=ntuple(a->starts[a]:min(starts[a]+block[a]-1,shape[a]),length(shape))
            _p04_read_observer[](:array,_p04_path(context.root,ref["path"]),prod(length.(ranges))*sizeof(E))
            slab=dataset[reverse(ranges)...]
            E===Bool && _p04_require(all(x->x in (0,1),slab),"invalid Boolean enum values")
            view(out,ranges...).=PermutedDimsArray(slab,reverse(ntuple(identity,length(shape))))
        end
        _p04_require(context.verified[ref["path"]].signature==_p04_stat(stat(_p04_path(context.root,ref["path"]))),"native payload changed during array read")
        out
    finally;close(dataset);end
end

Base.@nospecializeinfer function _p04_decode(@nospecialize(wire),@nospecialize(T),context;allow_any=false)
    if T===Any
        _p04_require(allow_any,"unqualified dynamic value")
        if wire===nothing || wire isa Union{Bool,String};return wire;end
        _p04_require(wire isa AbstractDict,"invalid scoped dynamic value")
        kind=get(wire,"kind",nothing)
        if kind=="dict"
            _p04_keys(wire,("kind","entries"));out=Dict{String,Any}()
            for entry in wire["entries"]
                _p04_keys(entry,("key","value"));key=_p04_decode(entry["key"],String,context)
                _p04_require(!haskey(out,key),"duplicate dynamic key");out[key]=_p04_decode(entry["value"],Any,context;allow_any=true)
            end
            return out
        end
        selected=kind=="symbol" ? Symbol : kind=="ieee" && get(wire,"type",nothing)=="f64" ? Float64 :
            kind=="integer" && get(wire,"type",nothing)=="Int64" ? Int64 : nothing
        _p04_require(selected!==nothing,"unsupported scoped dynamic tag");return _p04_decode(wire,selected,context)
    end
    layout=_p04_types()
    if T isa Union || T===QCLNEGF.CoreDatum
        variants=T isa Union ? Base.uniontypes(T) : [layout.types[n] for n in layout.nodes["CoreDatum"]["variants"]]
        for U in variants
            match=wire===nothing ? U===Nothing : wire isa Bool ? U===Bool : wire isa String ? U===String :
                wire isa AbstractDict ? haskey(wire,"type") && get(wire,"kind",nothing)===nothing ? _p04_typeid(U)==wire["type"] :
                get(wire,"kind",nothing)=="integer" ? U<:Integer && get(wire,"type",nothing)==string(U) :
                get(wire,"kind",nothing)=="ieee" ? U in (Float32,Float64) && get(wire,"type",nothing)==(U===Float64 ? "f64" : "f32") :
                get(wire,"kind",nothing)=="symbol" ? U===Symbol :
                get(wire,"kind",nothing)=="complex" ? U<:Complex :
                get(wire,"kind",nothing)=="dict" ? U<:AbstractDict :
                get(wire,"kind",nothing)=="quantity" ? U<:Unitful.AbstractQuantity && get(wire,"unit",nothing)==string(unit(zero(U))) :
                get(wire,"kind",nothing)=="array" ? U<:AbstractArray && get(wire,"eltype",nothing)==_p04_type_text(eltype(U)) : false : false
            match && return _p04_decode(wire,U,context;allow_any)
        end
        throw(ArgumentError("no public union variant matches wire"))
    elseif T===Nothing;_p04_require(wire===nothing,"expected null");return nothing
    elseif T===Bool;_p04_require(wire isa Bool,"expected Bool");return wire
    elseif T===String;_p04_require(wire isa String && isvalid(wire),"expected UTF-8 String");return wire
    elseif T===Symbol;_p04_keys(wire,("kind","value"));_p04_require(wire["kind"]=="symbol" && wire["value"] isa String,"expected Symbol");return Symbol(wire["value"])
    elseif T<:Integer
        _p04_keys(wire,("kind","type","decimal"));_p04_require(wire["kind"]=="integer" && wire["type"]==string(T) &&
            wire["decimal"] isa String && occursin(r"^(?:0|-?[1-9][0-9]*)\z",wire["decimal"]),"invalid integer tag")
        number=tryparse(T,wire["decimal"]);_p04_require(number!==nothing,"integer out of width");return number
    elseif T in (Float32,Float64)
        _p04_keys(wire,("kind","type","bits"));_p04_require(wire["kind"]=="ieee" && wire["type"]==(T===Float64 ? "f64" : "f32") &&
            wire["bits"] isa String && ncodeunits(wire["bits"])==2sizeof(T) && occursin(r"^[0-9a-f]+\z",wire["bits"]),"invalid IEEE tag")
        return reinterpret(T,parse(T===Float64 ? UInt64 : UInt32,wire["bits"];base=16))
    elseif T<:Complex
        _p04_keys(wire,("kind","real","imag"));_p04_require(wire["kind"]=="complex","expected complex")
        return T(_p04_decode(wire["real"],T.parameters[1],context),_p04_decode(wire["imag"],T.parameters[1],context))
    elseif T<:Unitful.AbstractQuantity
        _p04_keys(wire,("kind","unit","value"));_p04_require(wire["kind"]=="quantity" && wire["unit"]==string(unit(zero(T))),"quantity unit differs")
        return _p04_decode(wire["value"],T.parameters[1],context)*unit(zero(T))
    elseif T<:Tuple
        _p04_require(wire isa AbstractVector,"expected tuple list");node=layout.nodes[_p04_typeid(T)]
        ids=haskey(node,"elements") ? node["elements"] : fill(node["element"],length(wire))
        _p04_require(length(ids)==length(wire),"tuple length differs")
        result=Tuple(_p04_decode(x,layout.types[id],context;allow_any) for (x,id) in zip(wire,ids))
        return context.validate_only ? result : convert(T,result)
    elseif T<:AbstractArray
        _p04_numeric(eltype(T)) && return _p04_read_array(wire,T,context)
        _p04_keys(wire,("kind","eltype","shape","order","values"));_p04_require(wire["kind"]=="array" && wire["eltype"]==_p04_type_text(eltype(T)) && wire["order"]=="F","array declaration differs")
        shape=_p04_shape(wire["shape"]);_p04_require(length(shape)==ndims(T) && prod(BigInt.(shape))==length(wire["values"]),"array element count differs")
        if context.validate_only
            for x in wire["values"];_p04_decode(x,eltype(T),context);end;return nothing
        end
        return reshape(eltype(T)[_p04_decode(x,eltype(T),context) for x in wire["values"]],shape)
    elseif T<:AbstractDict
        _p04_keys(wire,("kind","entries"));_p04_require(wire["kind"]=="dict","expected typed dictionary");out=context.validate_only ? Dict{Any,Any}() : T()
        for entry in wire["entries"]
            _p04_keys(entry,("key","value"));key=_p04_decode(entry["key"],keytype(T),context)
            _p04_require(!haskey(out,key),"duplicate typed key");out[key]=_p04_decode(entry["value"],valtype(T),context;allow_any)
        end
        return out
    end
    _p04_keys(wire,("type","fields"));_p04_require(wire["type"]==_p04_typeid(T),"public struct type differs")
    _p04_keys(wire["fields"],string.(fieldnames(T)))
    vals=Tuple(_p04_decode(wire["fields"][string(n)],U,context;
        allow_any=(T===QCLNEGF.SCBAResult && n===:restart_contract)) for (n,U) in zip(fieldnames(T),fieldtypes(T)))
    context.validate_only && return nothing
    if T===QCLNEGF.ExactExecutionIdentity || T===QCLNEGF.ExactSolverState
        return T(;NamedTuple{fieldnames(T)}(vals)...)
    elseif T===QCLNEGF.SolverMetric
        return T(vals[1],vals[2],vals[3];measurement_status=vals[4],reason=vals[5])
    elseif T<:QCLNEGF.CoreArray
        return QCLNEGF.CoreArray(reshape(vals[2],vals[1]))
    end
    T(vals...)
end
