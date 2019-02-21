
struct MDBMcontainer{RTf,RTc,AT}
    funval::RTf
    cval::RTc
    callargs::AT
end

#TODO memoization ofr multiple functions Vector{Function}
struct MemF{RTf,RTc,AT} <:Function
    f::Function
    c::Function
    fvalarg::Vector{MDBMcontainer{RTf,RTc,AT}}#funval,callargs
    memoryacc::Vector{Int64} #number of function value call for already evaluated parameters
    MemF(f::Function,c::Function,cont::Vector{MDBMcontainer{RTf,RTc,AT}}) where {RTf,RTc,AT}=new{RTf,RTc,AT}(f,c,cont,[Int64(0)])
end

(memfun::MemF{RTf,RTc,AT})(::Type{RTf},::Type{RTc},args...,) where {RTf,RTc,AT} =( memfun.f(args...,)::RTf, memfun.c(args...,)::RTc)

function (memfun::MemF{RTf,RTc,AT})(args...,) where {RTf,RTc,AT}
    location=searchsortedfirst(memfun.fvalarg,args,lt=(x,y)->isless(x.callargs,y));
    if length(memfun.fvalarg)<location
        x=memfun(RTf,RTc,args...,);
        push!(memfun.fvalarg,MDBMcontainer{RTf,RTc,AT}(x...,args))
        return x
    elseif  memfun.fvalarg[location].callargs!=args
        x=memfun(RTf,RTc,args...,);
        insert!(memfun.fvalarg, location, MDBMcontainer{RTf,RTc,AT}(x...,args))
        return x
    else
        memfun.memoryacc[1]+=1;
        return (memfun.fvalarg[location].funval,memfun.fvalarg[location].cval);
    end
end

function (memfun::MemF{RTf,RTc,AT})(args::Tuple) where {RTf,RTc,AT}
    memfun(args...,)
end


struct Axis{T} <: AbstractVector{T}
    ticks::Vector{T}
    name
    function Axis(T::Type,a::AbstractVector,name=:unknown)
        new{T}(T.(a), name)
    end
end
Base.getindex(ax::Axis{T}, ind) where T = ax.ticks[ind]::T
Base.setindex!(ax::Axis, X, inds...) = setindex!(ax.ticks, X, inds...)
Base.size(ax::Axis) = size(ax.ticks)

function Axis(a::AbstractVector{T}, name=:unknown) where T<:Real
    Axis(Float64, a, name)
end
function Axis(a::AbstractVector{T}, name=:unknown) where T
    Axis(T, a, name)
end
function Axis(a, name=:unknown) where T
    Axis([a...], name)
end
function Axis(a::Axis)
    a
end


function fncreator(axes)
    fn="function (ax::$(typeof(axes)))(ind...)\n("
    for i in eachindex(axes)
        fn*="ax[$i][ind[$i]]"
        if i < length(axes)
            fn*=", "
        end
    end
    return fn*")\nend"
end

function createAxesGetindexFunction(axes)
     eval(Meta.parse(fncreator(axes)))
end

function fncreatorTuple(axes)
    fn="function (ax::$(typeof(axes)))(ind)\n("
    for i in eachindex(axes)
        fn*="ax[$i][ind[$i]]"
        if i < length(axes)
            fn*=", "
        end
    end
    return fn*")\nend"
end
function createAxesGetindexFunctionTuple(axes)
     eval(Meta.parse(fncreatorTuple(axes)))
end




struct NCube{IT<:Integer,FT<:AbstractFloat,ValNdim}
    corner::MVector{ValNdim,IT} #"bottom-left" #Integer index of the axis
    size::MVector{ValNdim,IT}#Integer index of the axis
    posinterp::MVector{ValNdim,FT}#relative coordinate within the cube "(-1:1)" range
    bracketingncube::Bool
    # gradient ::MVector{MVector{T}}
    # curvnorm::Vector{T}
end



Base.isless(a::NCube{IT,FT,N},b::NCube{IT,FT,N}) where IT where FT where N = Base.isless([a.corner,a.size],[b.corner,b.size])
Base.isequal(a::NCube{IT,FT,N},b::NCube{IT,FT,N}) where IT where FT where N = all([a.corner==b.corner,a.size==b.size])
import Base.==
==(a::NCube{IT,FT,N},b::NCube{IT,FT,N}) where IT where FT where N = all([a.corner==b.corner,a.size==b.size])



struct MDBM_Problem{N,Nf,Nc}
    fc::Function
    axes::NTuple{N,Axis}
    ncubes::Vector{NCube{IT,FT,N}} where IT<:Integer where FT<:AbstractFloat
    T01::AbstractVector{<:AbstractVector}#SArray#
    T11pinv::SMatrix
end

function MDBM_Problem(fc::Function,axes,ncubes::Vector{NCube{IT,FT,N}},Nf,Nc) where IT<:Integer where FT<:AbstractFloat where N
    T01=T01maker(Val(N))
    T11pinv=T11pinvmaker(Val(N))
    createAxesGetindexFunction((axes...,))
    createAxesGetindexFunctionTuple((axes...,))
    MDBM_Problem{N,Nf,Nc}(fc,(axes...,),
    [NCube{IT,FT,N}(SVector{N,IT}([x...]),SVector{N,IT}(ones(IT,length(x))),SVector{N,FT}(zeros(IT,length(x))),true) for x in Iterators.product((x->1:(length(x.ticks)-1)).(axes)...,)][:]
    ,T01,T11pinv)
end

function MDBM_Problem(f::Function, axes::Vector{<:Axis};constraint::Function=(x...,)->true, memoization::Bool=true,
    Nf=length(f(getindex.(axes,1)...)),
    Nc=length(constraint(getindex.(axes,1)...)))#Float16(1.), nothing

    argtypesofmyfunc=map(x->typeof(x).parameters[1], axes);#Argument Type
    AT=Tuple{argtypesofmyfunc...};
    type_f=Base.return_types(f,AT)
    if length(type_f)==0
        error("input of the function is not compatible with the provided axes")
    else
        RTf=type_f[1];#Return Type of f
    end

    type_con=Base.return_types(constraint,AT)
    if length(type_con)==0
        error("input of the constraint function is not compatible with the provided axes")
    else
        RTc=type_con[1];#Return Type of the constraint function
    end

    if memoization
        fun=MemF(f,constraint,Array{MDBMcontainer{RTf,RTc,AT}}(undef, 0));
    else
        fun=(x)->(f(x...),constraint(x...));
    end
    Ndim=length(axes)
    MDBM_Problem(fun,axes,Vector{NCube{Int64,Float64,Ndim}}(undef, 0),Nf,Nc)
end

function MDBM_Problem(f::Function, a::Vector{<:AbstractVector};constraint::Function=(x...,)->true, memoization::Bool=true,
    Nf=length(f(getindex.(a,1)...)),
    Nc=length(constraint(getindex.(a,1)...)))

    axes=[Axis(ax) for ax in a]
    MDBM_Problem(f,axes,constraint=constraint,memoization=memoization,Nf=Nf,Nc=Nc)#,Vector{NCube{Int64,Float64,Val(Ndim)}}(undef, 0))
end