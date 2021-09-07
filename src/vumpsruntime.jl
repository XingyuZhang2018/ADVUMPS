using Random

export AbstractLattice, SquareLattice
abstract type AbstractLattice end
struct SquareLattice <: AbstractLattice end

export VUMPSRuntime, SquareVUMPSRuntime

# NOTE: should be renamed to more explicit names
"""
    VUMPSRuntime{LT}

a struct to hold the tensors during the `vumps` algorithm, containing
- `d × d × d × d` `M` tensor
- `D × d × D` `AL` tensor
- `D × D`     `C` tensor
- `D × d × D` `AR` tensor
- `D × d × D` `FL` tensor
- `D × d × D` `FR` tensor
and `LT` is a AbstractLattice to define the lattice type.
"""
struct VUMPSRuntime{LT,T,N,AT<:AbstractArray{T,N},ET,CT}
    M::AT
    AL::ET
    C::CT
    AR::ET
    FL::ET
    FR::ET
    function VUMPSRuntime{LT}(M::AT, AL::AbstractArray{T}, C::AbstractArray{T}, AR::AbstractArray{T},
        FL::AbstractArray{T}, FR::AbstractArray{T}) where {LT<:AbstractLattice,T,N,AT<:AbstractArray{T,N}}
        new{LT,T,N,AT,typeof(AL),typeof(C)}(M,AL,C,AR,FL,FR)
    end
end

const SquareVUMPSRuntime{T,AT} = VUMPSRuntime{SquareLattice,T,4,AT}
SquareVUMPSRuntime(M::AT,AL,C,AR,FL,FR) where {T,AT<:AbstractArray{T, 4}} = VUMPSRuntime{SquareLattice}(M,AL,C,AR,FL,FR)

getD(rt::VUMPSRuntime) = size(rt.AL, 1)
getd(rt::VUMPSRuntime) = size(rt.M, 1)

@doc raw"
    SquareVUMPSRuntime(M::AbstractArray{T,4}, env::Val, χ::Int)

create a `SquareVUMPSRuntime` with M-tensor `M`. The AL,C,AR,FL,FR
tensors are initialized according to `env`. If `env = Val(:random)`,
the A is initialized as a random D×d×D tensor,and AL,C,AR are the corresponding 
canonical form. FL,FR is the left and right environment:
```
┌── AL─       ┌──        ─ AR──┐         ──┐    
│   │         │            │   │           │      
FL─ M ─  = λL FL─        ─ M ──FR   = λR ──FR   
│   │         │            │   │           │      
┕── AL─       ┕──        ─ AR──┘         ──┘  
```

# example

```jldoctest; setup = :(using ADVUMPS)
julia> rt = SquareVUMPSRuntime(randn(2,2,2,2), Val(:random), 4);

julia> size(rt.AL) == (4,2,4)
true

julia> size(rt.C) == (4,4)
true
```
"
function SquareVUMPSRuntime(M::AbstractArray{T,4}, env, D::Int; verbose = false) where T
    return SquareVUMPSRuntime(M, _initializect_square(M, env, D; verbose = verbose)...)
end

function _initializect_square(M::AbstractArray{T,4}, env::Val{:random}, D::Int; verbose = false) where T
    d = size(M,1)
    A = _arraytype(M)(rand(T,D,d,D))
    AL, = leftorth(A)
    C, AR = rightorth(AL)
    _, FL = leftenv(AL, AL, M)
    _, FR = rightenv(AR, AR, M)
    verbose && print("random initial vumps environment-> ")
    AL,C,AR,FL,FR
end

function _initializect_square(M::AbstractArray{T,4}, chkp_file::String, D::Int; verbose = false) where T
    env = load(chkp_file)["env"]
    atype = _arraytype(M)
    verbose && print("vumps environment load from $(chkp_file) -> ")
    atype(env.AL),atype(env.C),atype(env.AR),atype(env.FL),atype(env.FR)
end

function vumps(rt::VUMPSRuntime; tol::Real, maxiter::Int, verbose = false)
    # initialize
    olderror = Inf

    stopfun = StopFunction(olderror, -1, tol, maxiter)
    rt, err = fixedpoint(res->vumpstep(res...), (rt, olderror), stopfun)
    verbose && println("vumps done@step: $(stopfun.counter), error=$(err)")
    return rt
end

function vumpstep(rt::VUMPSRuntime,err)
    M,AL,C,AR,FL,FR = rt.M,rt.AL,rt.C,rt.AR,rt.FL,rt.FR
    AC = ein"abc,cd -> abd"(AL,C)
    _, ACp = ACenv(AC, FL, M, FR)
    _, Cp = Cenv(C, FL, FR)
    ALp, ARp, _, _ = ACCtoALAR(ACp, Cp)
    _, FL = leftenv(AL, ALp, M, FL)
    _, FR = rightenv(AR, ARp, M, FR)
    _, ACp = ACenv(ACp, FL, M, FR)
    _, Cp = Cenv(Cp, FL, FR)
    ALp, ARp, _, _ = ACCtoALAR(ACp, Cp)
    err = Zygote.@ignore error(ALp,Cp,ARp,FL,M,FR)
    return SquareVUMPSRuntime(M, ALp, Cp, ARp, FL, FR), err
end

"""
    vumps_env(model<:HamiltonianModel, β, D)

return the vumps environment of the `model` as a function of the inverse
temperature `β` and the environment bonddimension `D` as calculated with
vumps. Save `env` in file `./data/model_β_D.jld2`. Requires that `model_tensor` are defined for `model`.
"""
function vumps_env(model::MT, M::AbstractArray; atype = Array, χ=20, tol=1e-10, maxiter=20, verbose = false, savefile = false, folder::String="./data/", direction::String= "up") where {MT <: HamiltonianModel}
    D = size(M,1)
    savefile && mkpath(folder*"$(model)_$(atype)")
    chkp_file = folder*"$(model)_$(atype)/$(direction)_D$(D)_χ$(χ).jld2"
    if isfile(chkp_file)                               
        rt = SquareVUMPSRuntime(M, chkp_file, χ; verbose = verbose)   
    else
        rt = SquareVUMPSRuntime(M, Val(:random), χ; verbose = verbose)
    end
    env = vumps(rt; tol=tol, maxiter=maxiter, verbose = verbose)
    Zygote.@ignore savefile && begin
        ALs, Cs, ARs, FLs, FRs = Array{ComplexF64,3}(env.AL), Array{ComplexF64,2}(env.C), Array{ComplexF64,3}(env.AR), Array{ComplexF64,3}(env.FL), Array{ComplexF64,3}(env.FR)
        envsave = SquareVUMPSRuntime(M, ALs, Cs, ARs, FLs, FRs)
        save(chkp_file, "env", envsave)
    end # if forward steps is too small, backward go to this way will make mistake!!!
    return env
end

"""
    Mu, ALu, Cu, ARu, ALd, Cd, ARd, FL, FR = obs_env(model::MT, Mu::AbstractArray; atype = Array, D::Int, χ::Int, verbose = false)

If the bulk tensor isn't up and down symmetric, the up and down environment are different. So to calculate observable, we must get ACup and ACdown, which is easy to get by overturning the `M`. Then be cautious to get the new `FL` and `FR` environment.
"""
function obs_env(model::MT, M::AbstractArray; atype = Array, χ::Int, tol = 1e-10, maxiter = 10, verbose = false, savefile = false, folder::String="./data/", updown = true) where {MT <: HamiltonianModel}
    envup = vumps_env(model, M; atype = atype, χ=χ, tol=tol, maxiter=maxiter, verbose = verbose, savefile = savefile, folder = folder, direction = "up")
    ALu,ARu,Cu,FLu,FRu = envup.AL,envup.AR,envup.C,envup.FL,envup.FR
    if updown 
        Md = permutedims(M, (1,4,3,2))
        envdown = vumps_env(model, Md; atype = atype, χ=χ, tol=tol, maxiter=maxiter, verbose = verbose, savefile = savefile, folder = folder, direction = "down")
        ALd,ARd,Cd = envdown.AL,envdown.AR,envdown.C

        _, FLo = obs_leftenv(ALu, ALd, M, FLu)
        _, FRo = obs_rightenv(ARu, ARd, M, FRu)
    else
        ALd,ARd,Cd = ALu,ARu,Cu
        _, FLo = obs_leftenv(ALu, ALu, M, FLu)
        _, FRo = obs_rightenv(ARu, ARu, M, FRu)
    end
    return M, ALu, Cu, ARu, ALd, Cd, ARd, FLo, FRo, FLu, FRu
end
