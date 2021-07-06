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
    # global backratio = 1.0
    # Zygote.@ignore print(round(-log(10,backratio)),' ')
    M,AL,C,AR,FL,FR = rt.M,rt.AL,rt.C,rt.AR,rt.FL,rt.FR
    AC = Zygote.@ignore ein"asc,cb -> asb"(AL,C)
    ACp = ein"((αaγ,γpη),asbp),ηbβ -> αsβ"(FL,AC,M,FR)
    Cp = ein"(αaγ,γη),ηaβ -> αβ"(FL,C,FR)
    # _, ACp = ACenv(AC, FL, M, FR)
    # _, Cp = Cenv(C, FL, FR)
    ALp, ARp, _, _ = ACCtoALAR(ACp, Cp)
    _, FL = leftenv(AL, ALp, M, FL)
    _, FR = rightenv(AR, ARp, M, FR)
    _, AC = ACenv(ACp, FL, M, FR)
    _, C = Cenv(Cp, FL, FR)
    AL, AR, _, _ = ACCtoALAR(AC, C)

    ##### avoid gradient explosion for too many iterations #####
    # M = backratio .* M + Zygote.@ignore (1-backratio) .* M
    # AL = backratio .* AL + Zygote.@ignore (1-backratio) .* AL
    # C = backratio .* C +  Zygote.@ignore (1-backratio) .* C
    # AR = backratio .* AR + Zygote.@ignore (1-backratio) .* AR
    # FL = backratio .* FL + Zygote.@ignore (1-backratio) .* FL
    # FR = backratio .* FR + Zygote.@ignore (1-backratio) .* FR

    err = error(AL,C,AR,FL,M,FR)
    # @show err
    return SquareVUMPSRuntime(M, AL, C, AR, FL, FR), err
end

"""
    Mu, ALu, Cu, ARu, ALd, Cd, ARd, FL, FR = obs_env(model::MT, Mu::AbstractArray; atype = Array, D::Int, χ::Int, verbose = false)

If the bulk tensor isn't up and down symmetric, the up and down environment are different. So to calculate observable, we must get ACup and ACdown, which is easy to get by overturning the `M`. Then be cautious to get the new `FL` and `FR` environment.
"""
function obs_env(model::MT, Mu::AbstractArray; atype = Array, D::Int, χ::Int, tol = 1e-10, maxiter = 10, verbose = false, savefile = false) where {MT <: HamiltonianModel}
    mkpath("./data/$(model)_$(atype)")
    chkp_file_up = "./data/$(model)_$(atype)/up_D$(D)_chi$(χ).jld2"
    verbose && print("↑ ")
    if isfile(chkp_file_up)                               
        rtup = SquareVUMPSRuntime(Mu, chkp_file_up, χ; verbose = verbose)   
    else
        rtup = SquareVUMPSRuntime(Mu, Val(:random), χ; verbose = verbose)
    end
    envup = vumps(rtup; tol=tol, maxiter=maxiter, verbose = verbose)
    ALu,ARu,Cu,FL,FR = envup.AL,envup.AR,envup.C,envup.FL,envup.FR

    Zygote.@ignore savefile && begin
        ALs, Cs, ARs, FLs, FRs = Array{Float64,3}(envup.AL), Array{Float64,2}(envup.C), Array{Float64,3}(envup.AR), Array{Float64,3}(envup.FL), Array{Float64,3}(envup.FR)
        envsave = SquareVUMPSRuntime(Mu, ALs, Cs, ARs, FLs, FRs)
        save(chkp_file_up, "env", envsave)
    end

    Md = permutedims(Mu, (1,4,3,2))
    FLd = permutedims(FL, (3,2,1))
    FRd = permutedims(FR, (3,2,1))
    ACp = Zygote.@ignore ein"asc,cb -> asb"(ALu,Cu)
    _, ACd = ACenv(ACp, FLd, Md, FRd)
    # chkp_file_down = "./data/$(model)_$(atype)/down_D$(D)_chi$(χ).jld2"
    # verbose && print("↓ ")
    # if isfile(chkp_file_up) 
    #     rtdown = SquareVUMPSRuntime(Md, chkp_file_up, χ; verbose = verbose)    
    # else      
    #     rtdown = SquareVUMPSRuntime(Md, Val(:random), χ; verbose = verbose)   
    # end
    # envdown = vumps(rtdown; tol=tol, maxiter=maxiter, verbose = verbose)
    # ALd,ARd,Cd = envdown.AL,envdown.AR,envdown.C

    # Zygote.@ignore savefile && begin
    #     ALs, Cs, ARs, FLs, FRs = Array{Float64,3}(envdown.AL), Array{Float64,2}(envdown.C), Array{Float64,3}(envdown.AR), Array{Float64,3}(envdown.FL), Array{Float64,3}(envdown.FR)
    #     envsave = SquareVUMPSRuntime(Md, ALs, Cs, ARs, FLs, FRs)
    #     save(chkp_file_down, "env", envsave)
    # end  
    # @show norm(ALu - ALd),norm(ARu - ARd)
    # _, FL_n = norm_FL(ALu, ALd)
    # _, FR_n = norm_FR(ARu, ARd)
    # println("overlap = $(ein"((ae,adb),bc),((edf,fg),cg) ->"(FL_n,ALu,Cu,ALd,Cd,FR_n)[]/ein"ac,ab,bd,cd ->"(FL_n,Cu,FR_n,Cd)[])") 
    # println("up obs = $(magnetisation(envup,Ising(),0.6)) down obs = $(magnetisation(envdown,Ising(),0.6))")

    # _, FL = leftenv(ALu, ALd, Mu, FL)
    # _, FR = rightenv(ARu, ARd, Mu, FR)
    # Mu, ALu, Cu, ARu, ALd, Cd, ARd, FL, FR
    Mu, ALu, Cu, ARu, ACd, FL, FR
end