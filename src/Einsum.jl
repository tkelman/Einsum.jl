isdefined(Base, :__precompile__) && __precompile__()

module Einsum

export @einsum

macro einsum(eq)
    _einsum(eq)
end

function _einsum(eq::Expr)
    
    # Get left hand side (lhs) and right hand side (rhs) of eq
    lhs = eq.args[1]
    rhs = eq.args[2]

    # Get info on the left-hand side
    dest_idx,dest_dim = Symbol[],Expr[]
    if typeof(lhs) == Symbol
        dest_symb = lhs
    else
        # Left hand side of equation must be a reference, e.g. A[i,j,k]
        @assert length(lhs.args) > 1
        @assert lhs.head == :ref
        dest_symb = lhs.args[1]

        # recurse expression to find indices
        get_indices!(lhs,dest_idx,dest_dim)
    end

    terms_idx,terms_dim = Symbol[],Expr[]
    get_indices!(rhs,terms_idx,terms_dim)
    terms_symb = [ terms_dim[i].args[2] for i in 1:length(terms_dim) ]

    # remove duplicate indices found elsewhere in terms or dest
    ex_check_dims = :()
    for i in reverse(1:length(terms_idx))
        duplicated = false
        di = terms_dim[i]
        for j = 1:(i-1)
            if terms_idx[j] == terms_idx[i]
                dj = terms_dim[j]
                ex_check_dims = quote
                    @assert $(esc(dj)) == $(esc(di))
                    $ex_check_dims
                end
                duplicated = true
            end
        end
        for j = 1:length(dest_idx)
            if dest_idx[j] == terms_idx[i]
                dj = dest_dim[j]
                if eq.head == :(=)
                    ex_check_dims = quote
                        @assert $(esc(dj)) == $(esc(di))
                        $ex_check_dims
                    end
                else
                    # store size of output array for dim j 
                    dest_dim[j] = di 
                end 
                duplicated = true
            end
        end
        if duplicated
            deleteat!(terms_idx,i)
            deleteat!(terms_dim,i)
        end
        i -= 1
    end

    # Create output array if specified by user 
    ex_get_type = :(nothing)
    ex_create_arrays = :(nothing)
    if eq.head == :(:=)
        ex_get_type = :($(esc(:(local T = eltype($(terms_symb[1]))))))
        if length(dest_dim) > 0
            ex_create_arrays = :($(esc(:($(dest_symb) = Array(eltype($(terms_symb[1])),$(dest_dim...))))))
        else
            ex_create_arrays = :($(esc(:($(dest_symb) = zero(eltype($(terms_symb[1])))))))
        end
    else
        ex_get_type = :($(esc(:(local T = eltype($(dest_symb))))))
        ex_create_arrays = :(nothing)
    end 

    # Copy equation, ex is the Expr we'll build up and return.
    ex = deepcopy(eq)

    if length(terms_idx) > 0
        # There are indices on rhs that do not appear in lhs.
        # We sum over these variables.

        # Innermost expression has form s += rhs
        ex.args[1] = :s
        ex.head = :(+=)
        ex = esc(ex)

        # Nest loops to iterate over the summed out variables
        ex = nest_loops(ex,terms_idx,terms_dim,true)

        # Prepend with s = 0, and append with assignment
        # to the left hand side of the equation.
        ex = quote
            $(esc(:(local s = zero(T))))
            $ex 
            $(esc(:($lhs = s)))
        end
    else
        # We do not sum over any indices
        ex.head = :(=)
        ex = :($(esc(ex)))
    end

    # Next loops to iterate over the destination variables
    ex = nest_loops(ex,dest_idx,dest_dim)

    # Assemble full expression and return
    return quote
        $ex_create_arrays
        let
        @inbounds begin
        $ex_check_dims
        $ex_get_type
        $ex
        end
        end
    end
end

function nest_loops(ex::Expr,idx::Vector{Symbol},dim::Vector{Expr},simd=false)
    if simd && !isempty(idx)
        # innermost index and dimension
        i = idx[1]
        d = dim[1]

        # Add @simd to the innermost loop.
        ex = quote
            local $(esc(i))
            @simd for $(esc(i)) = 1:$(esc(d))
                $(ex)
            end
        end
        start_ = 2
    else
        start_ = 1
    end

    # Add remaining for loops
    for j = start_:length(idx)
        # index and dimension we are looping over
        i = idx[j]
        d = dim[j]

        # add for loop around expression
        ex = quote
            local $(esc(i))
            for $(esc(i)) = 1:$(esc(d))
                $(ex)
            end
        end
    end
    return ex
end


function get_indices!(ex::Expr,idx_store::Vector{Symbol},dim_store::Vector{Expr})
    if ex.head == :ref
        for (i,arg) in enumerate(ex.args[2:end])
            push!(idx_store,arg)
            push!(dim_store,:(size($(ex.args[1]),$i)))
        end
    else
        @assert ex.head == :call
        for arg in ex.args[2:end]
            get_indices!(arg,idx_store,dim_store)
        end
    end
end

end # module
