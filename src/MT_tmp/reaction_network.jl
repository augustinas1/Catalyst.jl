"""
Macro that inputs an expression corresponding to a reaction network and output a Reaction Network Structure that can be used as input to generation of SDE and ODE and Jump problems.
Most arrows accepted (both right, left and bi drectional arrows).
Note that while --> is a correct arrow, neither <-- nor <--> works.
Using non-filled arrows (⇐, ⟽, ⇒, ⟾, ⇔, ⟺) will disable mass kinetics and lets you cutomize reaction rates yourself.
Use 0 or ∅ for degradation/creation to/from nothing.
Example systems:
    ### Basic Usage ###
    rn = @reaction_network rType begin #Creates a reaction network of type rType.
        2.0, X + Y --> XY                  #This will have reaction rate corresponding to 2.0*[X][Y]
        2.0, XY ← X + Y                    #Identical to 2.0, X + Y --> XY
    end

    ### Manipulating Reaction Rates ###
    rn = @reaction_network rType begin
        2.0, X + Y ⟾ XY                   #Ignores mass kinetics. This will have reaction rate corresponding to 2.0.
        2.0X, X + Y --> XY                 #Reaction rate needs not be constant. This will have reaction rate corresponding to 2.0*[X]*[X]*[Y].
        XY+log(X)^2, X + Y --> XY          #Reaction rate accepts quite complicated expressions (user defined functions must first be registered using the @reaction_func macro).
        hill(XY,2,2,2), X + Y --> XY       #Reaction inis activated by XY according to a hill function. hill(x,v,K,N).
        mm(XY,2,2), X + Y --> XY           #Reaction inis activated by XY according to a michaelis menten function. mm(x,v,K).
    end

    ### Multipple Reactions on a Single Line ###
    rn = @reaction_network rType begin
        (2.0,1.0), X + Y ↔ XY              #Identical to reactions (2.0, X + Y --> XY) and (1.0, XY --> X + Y).
        2.0, (X,Y) --> 0                   #This corresponds to both X and Y degrading at rate 2.0.
        (2.0, 1.0), (X,Y) --> 0            #This corresponds to X and Y degrading at rates 2.0 and 1.0, respectively.
        2.0, (X1,Y1) --> (X2,Y2)           #X1 and Y1 becomes X2 and Y2, respectively, at rate 2.0.
    end

    ### Adding Parameters ###
    kB = 2.0; kD = 1.0
    p = [kB, kD]
    p = []
    rn = @reaction_network type begin
        (kB, kD), X + Y ↔ XY            #Lets you define parameters outside on network. Parameters can be changed without recalling the network.
    end kB, kD

    ### Defining New Functions ###
    @reaction_func my_hill_repression(x, v, k, n) = v*k^n/(k^n+x^n)     #Creates and adds a new function that the @reaction_network macro can see.
    r = @reaction_network MyReactionType begin
        my_hill_repression(x, v_x, k_x, n_x), 0 --> x                       #After it has been added in @reaction_func the function can be used when defining new reaction networks.
    end v_x k_x n_x

    ### Simulating Reaction Networks ###
    probODE = ODEProblem(rn, args...; kwargs...)        #Using multiple dispatch the reaction network can be used as input to create ODE, SDE and Jump problems.
    probSDE = SDEProblem(rn, args...; kwargs...)
    probJump = JumpProblem(prob,aggregator::Direct,rn)
"""

"""
    @reaction_network

Generates a subtype of an `AbstractReactionNetwork` that encodes a chemical
reaction network, and complete ODE, SDE and jump representations of the system.
See the [Chemical Reaction Model
docs](http://docs.juliadiffeq.org/dev/models/biological.html) for details on
parameters to the macro.
"""
# Declare various arrow types symbols used for the empty set (also 0).
empty_set = Set{Symbol}([:∅])
fwd_arrows = Set{Symbol}([:>, :→, :↣, :↦, :⇾, :⟶, :⟼, :⥟, :⥟, :⇀, :⇁, :⇒, :⟾])
bwd_arrows = Set{Symbol}([:<, :←, :↢, :↤, :⇽, :⟵, :⟻, :⥚, :⥞, :↼, :↽, :⇐, :⟽])
double_arrows = Set{Symbol}([:↔, :⟷, :⇄, :⇆, :⇔, :⟺])
pure_rate_arrows = Set{Symbol}([:⇐, :⟽, :⇒, :⟾, :⇔, :⟺])

# Main macro, takes a designated type name and a reaction network, returns the reaction network structure.
macro MT_reaction_network(name, ex::Expr, parameters...)
    MT_coordinate(name, MacroTools.striplines(ex), parameters)
end
# If no type name is given, creates a network of the default type.
macro MT_reaction_network(ex::Expr, parameters...)
    MT_coordinate(:MT_reaction_network, MacroTools.striplines(ex), parameters)
end

# Coordination function, coordinates the various functions creating the reaction network structure.
function MT_coordinate(name, ex::Expr, parameters)
    # Prepares the reaction network system.
    (reactions, reactants) = extract_reactions(ex, parameters)
    reaction_system = rephrase_reactions(reactions,reactants,parameters)

    # Puts everything in the maketype function.
    exprs = Vector{Expr}(undef,0)
    typeex,constructorex = MT_maketype(DiffEqBase.AbstractReactionNetwork, name, reaction_system)
    push!(exprs,typeex)
    push!(exprs,constructorex)

    # Add type functions
    append!(exprs, gentypefun_exprs(name))
    exprs[end] = :($(exprs[end]))

    # Return as one expression block
    expr_arr_to_block(exprs)
end

# Function  coordinating the extracting reactions and reactants.
function extract_reactions(ex::Expr, parameters)
    reactions = MT_get_reactions(ex)
    reactants = MT_get_reactants(reactions)
    (in(:t,union(reactants,parameters))) && error("t is reserved for the time variable and may neither be used as a reactant nor a parameter")
    return (reactions,reactants)
end

#Structure containing information about one Reaction. Contain all its substrates and products as well as its rate. Contains an specialized constructor.
struct MT_ReactionStruct
    substrates::Vector{ReactantStruct}
    products::Vector{ReactantStruct}
    rate::ExprValues
    only_use_rate::Bool

    function MT_ReactionStruct(sub_line::ExprValues, prod_line::ExprValues, rate::ExprValues, only_use_rate::Bool)
        sub = recursive_find_reactants!(sub_line,1,Vector{ReactantStruct}(undef,0))
        prod = recursive_find_reactants!(prod_line,1,Vector{ReactantStruct}(undef,0))
        new(sub, prod, rate, only_use_rate)
    end
end

#Structure containing information about one reactant in one reaction.
struct ReactantStruct
    reactant::Symbol
    stoichiometry::Int
end

#Generates a vector containing a number of reaction structures, each containing the infromation about one reaction.
function MT_get_reactions(ex::Expr, reactions = Vector{MT_ReactionStruct}(undef,0))
    for line in ex.args
        (line.head != :tuple) && (continue)
        (rate,r_line) = line.args
        (r_line.head  == :-->) && (r_line = Expr(:call,:→,r_line.args[1],r_line.args[2]))

        arrow = r_line.args[1]
        if in(arrow,double_arrows)
            (typeof(rate) == Expr && rate.head == :tuple) || error("Error: Must provide a tuple of reaction rates when declaring a bi-directional reaction.")
            push_reactions!(reactions, r_line.args[2], r_line.args[3], rate.args[1], in(arrow,pure_rate_arrows))
            push_reactions!(reactions, r_line.args[3], r_line.args[2], rate.args[2], in(arrow,pure_rate_arrows))
        elseif in(arrow,fwd_arrows)
            push_reactions!(reactions, r_line.args[2], r_line.args[3], rate, in(arrow,pure_rate_arrows))
        elseif in(arrow,bwd_arrows)
            push_reactions!(reactions, r_line.args[3], r_line.args[2], rate, in(arrow,pure_rate_arrows))
        else
            throw("malformed reaction")
        end
    end
    return reactions
end

#Takes a reaction line and creates reactions from it and pushes those to the reaction array. Used to creat multiple reactions from e.g. 1.0, (X,Y) --> 0.
function push_reactions!(reactions::Vector{MT_ReactionStruct}, sub_line::ExprValues, prod_line::ExprValues, rate::ExprValues, only_use_rate::Bool)
    lengs = [tup_leng(sub_line), tup_leng(prod_line), tup_leng(rate)]
    (count(lengs.==1) + count(lengs.==maximum(lengs)) < 3) && (throw("malformed reaction"))
    for i = 1:maximum(lengs)
        push!(reactions, MT_ReactionStruct(get_tup_arg(sub_line,i), get_tup_arg(prod_line,i), get_tup_arg(rate,i), only_use_rate))
    end
end

#Recursive function that loops through the reaction line and finds the reactants and their stoichiometry. Recursion makes it able to handle werid cases like 2(X+Y+3(Z+XY)).
function recursive_find_reactants!(ex::ExprValues, mult::Int, reactants::Vector{ReactantStruct})
    if typeof(ex)!=Expr
        (ex == 0 || in(ex,empty_set)) && (return reactants)
        if in(ex, getfield.(reactants,:reactant))
            idx = findall(x -> x==ex ,getfield.(reactants,:reactant))[1]
            reactants[idx] = ReactantStruct(ex,mult+reactants[idx].stoichiometry)
        else
            push!(reactants, ReactantStruct(ex,mult))
        end
    elseif ex.args[1] == :*
        add_reactants!(ex.args[3],mult*ex.args[2],reactants)
    elseif ex.args[1] == :+
        for i = 2:length(ex.args)
            add_reactants!(ex.args[i],mult,reactants)
        end
    else
        throw("malformed reaction")
    end
    return reactants
end

# Extract the reactants from the set of reactions.
function MT_get_reactants(reactions::Vector{MT_ReactionStruct})
    reactants = Vector{Symbol}()
    for reaction in reactions, reactant in union(reaction.substrates,reaction.products)
        !in(reactant.reactant,reactants) && push!(reactants,reactant.reactant)
    end
    return reactants
end

# Takes the reactions, and rephrases it as a "ReactionSystem" call, as designated by the ModelingToolkit IR.
function rephrase_reactions(reactions, reactants, parameters)
    network_code = Expr(:block,:(@parameters t),:(@variables), :(ReactionSystem([],t,[],[])))
    foreach(parameter-> push!(network_code.args[1].args, parameter), parameters)
    foreach(reactant -> push!(network_code.args[2].args, Expr(:call,reactant,:t)), reactants)
    foreach(parameter-> push!(network_code.args[3].args[5].args, parameter), parameters)
    foreach(reactant -> push!(network_code.args[3].args[4].args, reactant), reactants)
    for reaction in reactions
        subs_init = isempty(reaction.substrates) ? nothing : :([]); subs_stoich_init = deepcopy(subs_init)
        prod_init = isempty(reaction.products) ? nothing : :([]); prod_stoich_init = deepcopy(prod_init)
        reaction_func = :(Reaction($(recursive_expand_functions!(reaction.rate)), $subs_init, $prod_init, $subs_stoich_init, $prod_stoich_init, only_use_rate=$(reaction.only_use_rate)))
        for sub in reaction.substrates
            push!(reaction_func.args[3].args, sub.reactant)
            push!(reaction_func.args[5].args, sub.stoichiometry)
        end
        for prod in reaction.products
            push!(reaction_func.args[4].args, prod.reactant)
            push!(reaction_func.args[6].args, prod.stoichiometry)
        end
        push!(network_code.args[3].args[2].args,reaction_func)
    end
    return network_code
end



### Functionality for expanding function call to actualy full functions ###

#Recursively traverses an expression and replaces special function call like "hill(...)" with the actual corresponding expression.
function recursive_expand_functions!(expr::ExprValues)
    (typeof(expr)!=Expr) && (return expr)
    foreach(i -> expr.args[i] = recursive_expand_functions!(expr.args[i]), 1:length(expr.args))
    if expr.head == :call
        haskey(funcdict, expr.args[1]) && return funcdict[expr.args[1]](expr.args[2:end])
        in(expr.args[1],hill_name) && return hill(expr)
        in(expr.args[1],hillR_name) && return hillR(expr)
        in(expr.args[1],mm_name) && return mm(expr)
        in(expr.args[1],mmR_name) && return mmR(expr)
    end
    return expr
end

#Hill function made avaiable (activation and repression).
hill_name = Set{Symbol}([:hill, :Hill, :h, :H, :HILL])
hill(expr::Expr) = :($(expr.args[3])*($(expr.args[2])^$(expr.args[5]))/($(expr.args[4])^$(expr.args[5])+$(expr.args[2])^$(expr.args[5])))
hillR_name = Set{Symbol}([:hill_repressor, :hillr, :hillR, :HillR, :hR, :hR, :Hr, :HR, :HILLR])
hillR(expr::Expr) = :($(expr.args[3])*($(expr.args[4])^$(expr.args[5]))/($(expr.args[4])^$(expr.args[5])+$(expr.args[2])^$(expr.args[5])))

#Michaelis menten function made avaiable (activation and repression).
mm_name = Set{Symbol}([:MM, :mm, :Mm, :mM, :M, :m])
mm(expr::Expr) = :($(expr.args[3])*$(expr.args[2])/($(expr.args[4])+$(expr.args[2])))
mmR_name = Set{Symbol}([:mm_repressor, :MMR, :mmr, :mmR, :MmR, :mMr, :MR, :mr, :Mr, :mR])
mmR(expr::Expr) = :($(expr.args[3])*$(expr.args[4])/($(expr.args[4])+$(expr.args[2])))

#Allows the user to define new function and enable the @reaction_network macro to see them.
funcdict = Dict{Symbol, Function}()     # Stores user defined functions.
macro reaction_func(expr)
    name = expr.args[1].args[1]
    args = expr.args[1].args[2:end]
    maths = expr.args[2].args[2]

    funcdict[name]  = x -> replace_names(maths, args, x)
end
