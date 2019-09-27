#== Definitions for running dREL code in Julia.
==#

export CategoryObject,CatPacket,get_name,first_packet,current_row

"""The following models a dREL category object, that can be looped over,
with each iteration providing a new packet"""

struct CategoryObject
    datablock::cif_container_with_dict
    catname::String
    object_names::Vector{String}
    data_names::Vector{String}
    data_frame::DataFrame
    internal_object_names
    name_to_object
    object_to_name
    key_names
    is_looped
    have_vals
end

## Our category object needs to present any child categories as if
## they were part of a single loop

CategoryObject(data::cif_container_with_dict,catname) = begin
    cifdic = get_dictionary(data)
    raw_data = get_typed_datablock(data)
    object_names = [a for a in keys(cifdic) if lowercase(get(cifdic[a],"_name.category_id",[""])[1]) == lowercase(catname)]
    data_names = [cifdic[a]["_definition.id"][1] for a in object_names]
    internal_object_names = [cifdic[a]["_name.object_id"][1] for a in data_names]
    name_to_object = Dict(zip(data_names,internal_object_names))
    object_to_name = Dict(zip(internal_object_names,data_names))
    is_looped = get(cifdic[catname],"_definition.class",["Set"])[1] == "Loop"
    have_vals = [k for k in data_names if k in keys(raw_data)]
    key_names = []
    if is_looped
        key_names = [name_to_object[a] for a in cifdic[catname]["_category_key.name"]]
    end
    actual_data = get_loop(raw_data,data_names[1])
    if !is_looped && size(actual_data,2) == 0  #no packets in a set category
        actual_data[!,gensym()] = [missing]
    end
    parent = CategoryObject(data,catname,object_names,data_names,actual_data,internal_object_names,
                                 name_to_object,object_to_name,key_names,is_looped,have_vals)
    for one_child in get_child_categories(cifdic,catname)
        parent = merge(parent,CategoryObject(data,one_child))
    end
    return parent
end

# Merge category objects. This is how we get the child objects to appear as
# a single category.

Base.merge(left::CategoryObject,right::CategoryObject) = begin
    if left.datablock != right.datablock
        error("Cannot merge categories with different data")
    end
    object_names = vcat(left.object_names,right.object_names)
    internal_object_names = vcat(left.internal_object_names,right.internal_object_names)
    data_names = vcat(left.data_names,right.data_names)
    name_to_object = merge(left.name_to_object,right.name_to_object)
    object_to_name = merge(left.object_to_name,right.object_to_name)
    key_names = left.key_names
    is_looped = left.is_looped
    have_vals = vcat(left.have_vals,right.have_vals)
    # Match up the keys
    cifdic = get_dictionary(left.datablock)
    right_keynames = cifdic[right.catname]["_category_key.name"]
    left_keynames = [cifdic[r]["_name.linked_item_id"][1] for r in right_keynames]
    # turn them into object names
    right_keynames = [Symbol(right.name_to_object[r]) for r in right_keynames]
    left_keynames = [Symbol(left.name_to_object[l]) for l in left_keynames]
    # The data frame is a left outer join
    data_frame = join(left.data_frame,right.data_frame,kind=:left,
                      on = collect(zip(left_keynames,right_keynames)))
    CategoryObject(left.datablock,left.catname,object_names,data_names,
                   data_frame,internal_object_names,name_to_object,
                   object_to_name,key_names,is_looped,have_vals)
end

# Find a packet using a dictionary of object - value pairs.
# If a single dataname key does not exist, it
# will be created arbitrarily.

Base.getindex(c::CategoryObject,keydict::Dict) = begin
    pack = c.data_frame
    println("Loop is $pack")
    # Try to create missing key data values - only
    # possible if there is a single key and no
    # children
    if length(keydict) == 1
        keyobj = collect(keys(keydict))[1]
        if !(Symbol(keyobj) in names(pack))
            fullname = c.object_to_name[keyobj]
            result = derive(c.datablock,fullname)
            pack[Symbol(keyobj)] = result
        end
    end
    for pr in keydict
        k,v = pr
        println("Testing for $k == $v")
        pack = pack[ pack[Symbol(k)] .== v,:]
    end
    if size(pack,1) != 1
        error("$keydict does not identify a unique row")
    end
    return CatPacket(eachrow(pack)[1],c.catname,c)
end

# If a single value is provided, we can turn this into a keyed
# access using the single unique key

Base.getindex(c::CategoryObject, x::Union{String,Array{Any},Number}) = begin
    if length(c.key_names) == 1
        return c[Dict(c.key_names[1]=>x)]
    else throw(KeyError(x))
    end
    # TODO: check for _category.key_id as alternative
end

Base.length(c::CategoryObject) = size(c.data_frame,1)
CrystalInfoFramework.get_dictionary(c::CategoryObject) = get_dictionary(c.datablock)
CrystalInfoFramework.get_datablock(c::CategoryObject) = get_datablock(c.datablock)

#=========

CatPackets

=========#

# We can't use a dataframerow by itself as we need to know the
# category name for use in deriving missing parts of the packet
# We store the datablock and dictionary as these can be used
# for internal derivation. The category object itself is less
# useful, we think...

struct CatPacket
    dfr::DataFrameRow
    name::String
    datablock
    dictionary
end

CatPacket(dfr,name,c::CategoryObject) = begin
    CatPacket(dfr,name,c.datablock,get_dictionary(c.datablock))
end

get_name(c::CatPacket) = return getfield(c,:name)
CrystalInfoFramework.get_dictionary(c::CatPacket) = return getfield(c,:dictionary)
CrystalInfoFramework.get_datablock(c::CatPacket) = return getfield(c,:datablock)
Base.propertynames(c::CatPacket,private::Bool=false) = propertynames(getfield(c,:dfr))

# We simply iterate over the data loop, but keep a track of the
# actual category name for access

Base.iterate(c::CategoryObject) = begin
    er = eachrow(c.data_frame)
    next = iterate(er)
    if next == nothing
        return next
    end
    r,s = next
    return CatPacket(r,c.catname,c),(er,s)
end

Base.iterate(c::CategoryObject,ci) = begin
    er,s = ci
    next = iterate(er,s)
    if next == nothing
        return next
    end
    r,s = next
    return CatPacket(r,c.catname,c),(er,s)
end

# Useful for Set categories
first_packet(c::CategoryObject) = iterate(c)[1]

# Support dREL legacy. Current row in dREL actually
# numbers from zero
current_row(c::CatPacket) = begin
    return parentindices(getfield(c,:dfr))[1]-1
end

#== The Tables.jl interface functions, commented out for now

Tables.istable(::Type{<:CategoryObject}) = true

Tables.rows(c::CategoryObject) = c

Tables.rowaccess(::Type{<:CategoryObject}) = true

Tables.schema(c::CategoryObject) = nothing

==#
