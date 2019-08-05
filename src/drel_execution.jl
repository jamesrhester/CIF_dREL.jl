#== This module defines functions for executing dREL code ==#

export dynamic_block, define_dict_funcs, derive, get_func_text

# Python setup calls

using PyCall

lark = PyNULL()
jl_transformer = PyNULL()

# Done this way to allow precompilation to work
__init__() = begin
    pushfirst!(PyVector(pyimport("sys")["path"]),@__DIR__)
    copy!(lark,pyimport("lark"))
    copy!(jl_transformer,pyimport("jl_transformer"))
end

# Configuration
const drel_grammar = joinpath(@__DIR__,"lark_grammar.ebnf")

# Create a parser for the dREL grammar

lark_grammar() = begin
    grammar_text = read(joinpath(@__DIR__,drel_grammar),String)
    parser = lark[:Lark](grammar_text,start="input",parser="lalr",lexer="contextual")
end

# Parse and output proto-Julia code using Python Lark. We cannot pass complex
# objects to Python, so we extract the needed information here.

lark_transformer(dname,dict,all_funcs,cat_list,func_cat) = begin
    # extract information to pass to python
    println("Now preparing dREL transformer for $dname (functions in $func_cat)")
    target_cat = dict[dname]["_name.category_id"][1]
    target_obj = dict[dname]["_name.object_id"][1]
    is_func = false
    if lowercase(target_cat) == func_cat
        is_func = true
    end
    tt = jl_transformer[:TreeToPy](dname,target_cat,target_obj,cat_list,is_func=is_func,func_list=all_funcs)
end

#== Functions defined in the dictionary are detected and adjusted while parsing. 
==#

get_cat_names(dict::abstract_cif_dictionary) = begin
    catlist = [a for a in keys(dict) if get(dict[a],"_definition.scope",["Item"])[1] == "Category"]
end

get_dict_funcs(dict::abstract_cif_dictionary) = begin
    func_cat = [a for a in keys(dict) if get(dict[a],"_definition.class",["Datum"])[1] == "Functions"]
    if length(func_cat) > 0
        func_catname = lowercase(dict[func_cat[1]]["_name.object_id"][1])
        all_funcs = [a for a in keys(dict) if lowercase(dict[a]["_name.category_id"][1]) == func_catname]
        all_funcs = lowercase.([dict[a]["_name.object_id"][1] for a in all_funcs])
    else
        all_funcs = []
    end
    return func_catname,all_funcs
end

get_drel_methods(cd::abstract_cif_dictionary) = begin
    has_meth = [n for n in cd if "_method.expression" in keys(n) && get(n,"_definition.scope",["Item"])[1] != "Category"]
    meths = [(n["_definition.id"][1],get_loop(n,"_method.expression")) for n in has_meth]
    println("Found $(length(meths)) methods")
    return meths
end

#== This method creates Julia code from dREL code by
(1) parsing the drel text into a parse tree
(2) traversing the parse tree with a transformer that has been prepared
    with the crucial information to output syntactically-correct Julia code
(3) parsing the returned Julia code into an expression
(4) adjusting indices to 1-based
(5) changing any aliases of the main category back to the category name
(6) making sure that all loop-local variables are defined at the entry level
(7) turning set categories into packets
(8) Assigning types to any dictionary items for which this is known
==#

make_julia_code(drel_text::String,dataname::String,dict::abstract_cif_dictionary,parser) = begin
    func_cat,all_funcs = get_dict_funcs(dict)
    cat_names = get_cat_names(dict)
    target_cat = find_category(dict,dataname)
    tree = parser[:parse](drel_text)
    transformer = lark_transformer(dataname,dict,all_funcs,cat_names,func_cat)
    tc_aliases,proto = transformer[:transform](tree)
    println("Proto-Julia code: ")
    println(proto)
    set_categories = get_set_categories(dict)
    parsed = ast_fix_indexing(Meta.parse(proto),get_categories(dict),dict)
    println(parsed)
    # catch implicit matrix assignments
    container_type = dict[dataname]["_type.container"][1]
    is_matrix = (container_type == "Matrix" || container_type == "Array")
    parsed = find_target(parsed,tc_aliases,transformer[:target_object];is_matrix=is_matrix)
    parsed = fix_scope(parsed)
    parsed = cat_to_packet(parsed,set_categories)  #turn Set categories into packets
    println("####\n    Assigning types\n####\n")
    parsed = ast_assign_types(parsed,Dict(Symbol("__packet")=>target_cat),cifdic=dict,set_cats=set_categories,all_cats=get_categories(dict))
end

#== Extract the dREL text from the dictionary, if any
==#
get_func_text(dict::abstract_cif_dictionary,dataname::String) =  begin
    full_def = dict[dataname]
    func_text = get_loop(full_def,"_method.expression")
    if size(func_text,2) == 0   #nothing
        return ""
    end
    # TODO: allow multiple methods
    eval_func = func_text[func_text[!,Symbol("_method.purpose")] .== "Evaluation",:]
    eval_func = eval_func[1,Symbol("_method.expression")]
end

define_dict_funcs(c::abstract_cif_dictionary) = begin
    #Parse and evaluate all dictionary-defined functions and store
    func_cat,all_funcs = get_dict_funcs(c)
    parser = lark_grammar()
    for f in all_funcs
        println("Now processing $f")         
        full_def = get_by_cat_obj(c,(func_cat,f))
        entry_name = full_def["_definition.id"][1]
        full_name = full_def["_name.object_id"][1]
        func_text = get_loop(full_def,"_method.expression")
        func_text = func_text[Symbol("_method.expression")][1]
        println("Function text: $func_text")
        result = make_julia_code(func_text,entry_name,c,parser)
        println("Transformed text: $result")
        set_func!(c,full_name,result,eval(result))  #store in dictionary
    end
end

struct dynamic_block <: cif_container_with_dict
    block::cif_block_with_dict
end

CrystalInfoFramework.get_dictionary(d::dynamic_block) = get_dictionary(d.block)
CrystalInfoFramework.get_datablock(d::dynamic_block) = get_datablock(d.block)

Base.getindex(d::dynamic_block,s::String) = begin
    try
        q = d.block[s]
    catch KeyError
        derive(d,s)
    end
end

#==Derive all values in a loop for the given
dataname==#

derive(d::cif_container_with_dict,s::String) = begin
    dict = get_dictionary(d)
    if !(has_func(dict,s))
        add_new_func(dict,s)
    end
    func_code = get_func(dict,s)
    target_loop = CategoryObject(d,find_category(dict,s))
    [Base.invokelatest(func_code,d,p) for p in target_loop]
end

#==This is called from within a dREL method when an item is
found missing from a packet==#

derive(d::cif_container_with_dict,cat::String,obj::String,p::CatPacket) = begin
    dict = get_dictionary(d)
    dataname = get_by_cat_obj(dict,(cat,obj))["_definition.id"][1]
    if !(has_func(dict,dataname))
        add_new_func(dict,dataname)
    end
    func_code = get_func(dict,dataname)
    Base.invokelatest(func_code,d,p)
end

#== We redefine getproperty to allow derivation
==#

Base.getproperty(cp::CatPacket,obj::Symbol) = begin
    try
        return getproperty(getfield(cp,:dfr),obj)
    catch KeyError
        #println("$(getfield(cp,:dfr)) has no member $obj:deriving...")
        # get the parent container with dictionary
        db = getfield(cp,:parent).datablock
        return derive(db,get_name(cp),String(obj),cp)
    end
end

add_new_func(d::abstract_cif_dictionary,s::String) = begin
    t = get_func_text(d,s)
    if t != ""
        parser = lark_grammar()
        r = make_julia_code(t,s,d,parser)
    else
        r = Meta.parse("(a,b) -> missing")
    end
    println("Transformed code for $s:\n")
    println(r)
    set_func!(d,s, r, eval(r))
end
