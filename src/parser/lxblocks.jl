"""
    find_md_lxdefs(tokens, blocks)

Find `\\newcommand` elements and try to parse what follows to form a proper Latex command.
Return a list of such elements.

The format is:
    \\newcommand{NAMING}[NARG]{DEFINING}
where [NARG] is optional (see `LX_NARG_PAT`).
"""
function find_lxdefs(tokens::Vector{Token}, blocks::Vector{OCBlock})

    lxdefs = Vector{LxDef}()

    braces = filter(β -> β.name == :LXB, blocks)
    nbraces = length(braces)

    active_tokens = ones(Bool, length(tokens))
    active_blocks = ones(Bool, length(blocks))

    # go over tokens, stop over the ones that indicate a newcommand
    for (i, τ) ∈ enumerate(tokens)
        # skip inactive tokens
        active_tokens[i] || continue
        # look for tokens that indicate a newcommand
        (τ.name == :LX_NEWCOMMAND) || continue

        # find first brace blocks after the newcommand (naming)
        fromτ = from(τ)
        k = findfirst(β -> (fromτ < from(β)), braces)
        # there must be two brace blocks after the newcommand (name, def)
        if isnothing(k) || !(1 <= k < nbraces)
            error("Ill formed newcommand (needs two {...})")
        end

        # try to find a number of arg between these two first {...} to see
        # if it may contain something which we'll try to interpret as [.d.]
        rge = (to(braces[k])+1):(from(braces[k+1])-1)
        lxnarg = 0
        # it found something between the naming brace and the def brace
        # check if it looks like [.d.] where d is a number and . are
        # optional spaces (specification of the number of arguments)
        if !isempty(rge)
            lxnarg = match(LX_NARG_PAT, subs(str(braces[k]), rge))
            isnothing(lxnarg) && error("Ill formed newcommand (where I
            expected the specification of the number of arguments).")
            matched = lxnarg.captures[2]
            lxnarg = isnothing(matched) ? 0 : parse(Int, matched)
        end

        # assign naming / def
        naming_braces = braces[k]
        defining_braces = braces[k+1]
        # try to find a valid command name in the first set of braces
        matched = match(LX_NAME_PAT, content(naming_braces))
        isnothing(matched) && error("Invalid definition of a new command expected a command " *
                                    "name of the form `\\command`.")

        # keep track of the command name, definition and where it stops
        lxname = matched.captures[1]
        lxdef = content(defining_braces)
        todef = to(defining_braces)
        # store the new latex command
        push!(lxdefs, LxDef(lxname, lxnarg, lxdef, fromτ, todef))

        # mark newcommand token as processed as well as the next token
        # which is necessarily the command name (brace token is inactive here)
        active_tokens[i] = false
        # mark any block (inc. braces!) starting in the scope as inactive
        for (i, isactive) ∈ enumerate(active_blocks)
            isactive || continue
            (fromτ ≤ from(blocks[i]) ≤ todef) && (active_blocks[i] = false)
        end
    end # of enumeration of tokens

    # filter out the stuff that's now marked as inactive by virtue of being
    # part of a newcommand definition (these things will be inspected later)
    tokens = tokens[active_tokens]
    blocks = blocks[active_blocks]
    # separate the braces from the rest of the blocks, they will be used
    # to define the lxcoms
    braces_mask = map(β -> β.name == :LXB, blocks)
    braces = blocks[braces_mask]
    blocks = blocks[@. ~braces_mask]

    return lxdefs, tokens, braces, blocks
end


"""
    retrieve_lxdefref(lxname, lxdefs, inmath)

Retrieve the reference pointing to a `LxDef` corresponding to a given `lxname`.
If no reference is found but `inmath=true`, we propagate and let KaTeX deal with it. If something
is found, the reference is returned and will be accessed further down.
"""
function retrieve_lxdefref(lxname::SubString, lxdefs::Vector{LxDef},
                           inmath=false, offset=0)

    ks = findall(δ -> (δ.name == lxname), lxdefs)
    fromlx = from(lxname) + offset
    filter!(k -> (fromlx > from(lxdefs[k])), ks)

    if isempty(ks)
        inmath || error("Command '$lxname' was not defined before it was used.")
        # not found but inmath --> let KaTex deal with it
        return
    end

    return Ref(lxdefs, ks[end])
end


"""
    find_md_lxcoms(lxtokens, lxdefs, braces, inmath, offset)

Find `\\command{arg1}{arg2}...` outside of `xblocks` and `lxdefs`.
"""
function find_md_lxcoms(tokens::Vector{Token}, lxdefs::Vector{LxDef},
                        braces::Vector{OCBlock}, offset=0; inmath=false)

    lxcoms   = Vector{LxCom}()
    active_τ = ones(Bool, length(tokens))
    nbraces  = length(braces)

    # go over tokens, stop over the ones that indicate a command
    for (i, τ) ∈ enumerate(tokens)
        active_τ[i] || continue
        (τ.name == :LX_COMMAND) || continue

        # 1. look for the definition given the command name
        lxname   = τ.ss
        lxdefref = retrieve_lxdefref(lxname, lxdefs, inmath, offset)
        # will only be nothing in a 'inmath' --> no failure, just ignore token
        isnothing(lxdefref) && continue

        # 2. retrieve number of arguments
        lxnarg = getindex(lxdefref).narg
        # 2.a there are none
        if lxnarg == 0
            push!(lxcoms, LxCom(lxname, lxdefref))
            active_τ[i] = false

        # >> there is at least one argument --> find all of them
        else
            # spot where an opening brace is expected
            nxtidx = to(τ) + 1
            b1_idx = findfirst(β -> (from(β) == nxtidx), braces)
            # --> it needs to exist + there should be enough braces left
            if isnothing(b1_idx) || (b1_idx + lxnarg - 1 > nbraces)
                error("Command '$lxname' expects $lxnarg arguments and there should be no " *
                      "spaces between the command name and the first brace: \\com{arg1}...")
            end

            # --> examine candidate braces, there should be no spaces between
            #  braces to avoid ambiguities
            cand_braces = braces[b1_idx:b1_idx+lxnarg-1]
            for bidx ∈ 1:lxnarg-1
                if (to(cand_braces[bidx]) + 1 != from(cand_braces[bidx+1]))
                    error("Argument braces should not be separated by spaces: \\com{arg1}{arg2}...
                           Verify a '$lxname' command.")
                end
            end

            # all good, can push it
            from_c = from(τ)
            to_c   = to(cand_braces[end])
            str_c  = subs(str(τ), from_c, to_c)
            push!(lxcoms, LxCom(str_c, lxdefref, cand_braces))

            # deactivate tokens in the span of the command (will be
            # reparsed later)
            first_active = findfirst(τ -> (from(τ) > to_c), tokens[i+1:end])
            if isnothing(first_active)
                active_τ[i+1:end] .= false
            elseif first_active > 1
                active_τ[i+1:(i+first_active-1)] .= false
            end
        end
    end

    return lxcoms, tokens[active_τ]
end
